import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Optional

import psycopg2
from psycopg2.extras import execute_values
from quixstreams.sinks.base import BaseSink


logger = logging.getLogger("quix-streams-service")


def _parse_iso8601_utc(value: Any) -> Optional[datetime]:
    if value is None:
        return None
    if isinstance(value, datetime):
        dt = value
    elif isinstance(value, str):
        # Handles e.g. 2026-02-20T12:34:56.123+00:00
        dt = datetime.fromisoformat(value)
    else:
        return None

    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


@dataclass(frozen=True)
class PostgresConfig:
    host: str
    port: int
    dbname: str
    user: str
    password: str

    @classmethod
    def from_env(cls) -> "PostgresConfig":
        return cls(
            host=os.getenv("POSTGRES_HOST", "postgres-postgresql.default.svc.cluster.local"),
            port=int(os.getenv("POSTGRES_PORT", "5432")),
            dbname=os.getenv("POSTGRES_DB", "postgres"),
            user=os.getenv("POSTGRES_USER", "postgres"),
            password=os.environ["POSTGRES_PASSWORD"],
        )


class PostgresProcessedSink(BaseSink):
    """Write processed events to PostgreSQL.

    Idempotency: uses a UNIQUE constraint on file_hash and `ON CONFLICT DO NOTHING`.
    """

    def __init__(self, pg: PostgresConfig, table_name: str = "image_uploads_processed"):
        super().__init__()
        self._pg = pg
        self._table_name = table_name
        self._buffer: list[dict] = []

    def setup(self):
        with psycopg2.connect(
            host=self._pg.host,
            port=self._pg.port,
            dbname=self._pg.dbname,
            user=self._pg.user,
            password=self._pg.password,
        ) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    f"""
                    CREATE TABLE IF NOT EXISTS {self._table_name} (
                        file_hash VARCHAR(64) PRIMARY KEY,
                        filename VARCHAR(255),
                        file_size BIGINT,
                        mime_type VARCHAR(100),
                        processed_at TIMESTAMPTZ,
                        kafka_topic TEXT,
                        kafka_partition INT,
                        kafka_offset BIGINT
                    );
                    """
                )
                cur.execute(
                    f"""
                    CREATE INDEX IF NOT EXISTS idx_{self._table_name}_processed_at
                    ON {self._table_name}(processed_at);
                    """
                )
            conn.commit()

        logger.info("PostgreSQL sink ready (table=%s)", self._table_name)

    def add(
        self,
        value: Any,
        key: Any,
        timestamp: int,
        headers: Any,
        topic: str,
        partition: int,
        offset: int,
    ):
        if not isinstance(value, dict):
            return

        file_hash = value.get("file_hash")
        if not file_hash:
            return

        self._buffer.append(
            {
                "file_hash": str(file_hash),
                "filename": value.get("filename"),
                "file_size": value.get("file_size"),
                "mime_type": value.get("mime_type"),
                "processed_at": _parse_iso8601_utc(value.get("processed_at")),
                "kafka_topic": topic,
                "kafka_partition": int(partition),
                "kafka_offset": int(offset),
            }
        )

    def flush(self):
        if not self._buffer:
            return

        rows = self._buffer
        self._buffer = []

        values = [
            (
                r["file_hash"],
                r["filename"],
                r["file_size"],
                r["mime_type"],
                r["processed_at"],
                r["kafka_topic"],
                r["kafka_partition"],
                r["kafka_offset"],
            )
            for r in rows
        ]

        sql = f"""
            INSERT INTO {self._table_name}
                (file_hash, filename, file_size, mime_type, processed_at, kafka_topic, kafka_partition, kafka_offset)
            VALUES %s
            ON CONFLICT (file_hash) DO NOTHING;
        """

        with psycopg2.connect(
            host=self._pg.host,
            port=self._pg.port,
            dbname=self._pg.dbname,
            user=self._pg.user,
            password=self._pg.password,
        ) as conn:
            with conn.cursor() as cur:
                execute_values(cur, sql, values, page_size=min(len(values), 1000))
            conn.commit()


class IcebergProcessedSink(BaseSink):
    """Append processed events to an Iceberg table via Lakekeeper REST catalog.

    Delivery: at-least-once. For dedupe, rely on (kafka_partition, kafka_offset)
    or file_hash downstream.
    """

    def __init__(
        self,
        catalog_name: str = "lakekeeper",
        namespace: str = "default",
        table: str = "image_uploads_processed",
    ):
        super().__init__()
        self._catalog_name = catalog_name
        self._namespace = namespace
        self._table = table
        self._buffer: list[dict] = []
        self._iceberg_table = None
        self._arrow_schema = None

    def setup(self):
        os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")

        from pyiceberg.catalog import load_catalog
        from pyiceberg.exceptions import (
            NamespaceAlreadyExistsError,
            NoSuchNamespaceError,
            NoSuchTableError,
        )

        catalog_uri = os.getenv(
            "ICEBERG_CATALOG_URI",
            "http://iceberg-rest.default.svc.cluster.local:8181/catalog",
        )
        # Lakekeeper expects the warehouse *name* for the /config call.
        warehouse = os.getenv("ICEBERG_WAREHOUSE", "seaweedfs")
        # Base location used when creating new tables.
        warehouse_location = os.getenv("ICEBERG_WAREHOUSE_LOCATION", "s3://iceberg/warehouse")

        s3_endpoint = os.getenv(
            "S3_ENDPOINT",
            "http://seaweedfs-s3.default.svc.cluster.local:8333",
        )
        s3_access_key = os.environ["S3_ACCESS_KEY_ID"]
        s3_secret_key = os.environ["S3_SECRET_ACCESS_KEY"]
        s3_region = os.getenv("S3_REGION", "us-east-1")

        # Best-effort bucket creation for the configured warehouse location.
        try:
            if warehouse_location.startswith("s3://"):
                bucket = warehouse_location[5:].split("/", 1)[0]
                import boto3
                from botocore.config import Config

                session = boto3.Session()
                client = session.client(
                    "s3",
                    endpoint_url=s3_endpoint,
                    aws_access_key_id=s3_access_key,
                    aws_secret_access_key=s3_secret_key,
                    region_name=s3_region,
                    config=Config(
                        s3={
                            "addressing_style": os.getenv(
                                "AWS_S3_ADDRESSING_STYLE",
                                "path",
                            )
                        }
                    ),
                )
                existing = [b["Name"] for b in client.list_buckets().get("Buckets", [])]
                if bucket not in existing:
                    client.create_bucket(Bucket=bucket)
                    logger.info("Created S3 bucket for Iceberg warehouse: %s", bucket)
        except Exception:
            logger.exception("Bucket check/create failed; continuing")

        self._catalog = load_catalog(
            self._catalog_name,
            **{
                "type": "rest",
                "uri": catalog_uri,
                "warehouse": warehouse,
                "py-io-impl": "pyiceberg.io.fsspec.FsspecFileIO",
                "s3.endpoint": s3_endpoint,
                "s3.access-key-id": s3_access_key,
                "s3.secret-access-key": s3_secret_key,
                "s3.region": s3_region,
            },
        )

        identifier = (self._namespace, self._table)

        import pyarrow as pa

        def _disable_remote_s3_signing(table) -> None:
            io_obj = getattr(table, "io", None)
            if io_obj is None:
                return

            props = getattr(io_obj, "properties", None) or getattr(io_obj, "_properties", None)
            if not isinstance(props, dict):
                return

            signer = props.get("s3.signer")
            if signer:
                logger.warning(
                    "Disabling remote S3 signing from catalog (s3.signer=%s)",
                    signer,
                )

            for key in (
                "s3.signer",
                "s3.signer.uri",
                "s3.signer.endpoint",
                "s3.remote-signing-enabled",
            ):
                props.pop(key, None)

        self._arrow_schema = pa.schema(
            [
                pa.field("processed_at", pa.timestamp("us", tz="UTC")),
                pa.field("filename", pa.string()),
                pa.field("file_hash", pa.string()),
                pa.field("file_size", pa.int64()),
                pa.field("mime_type", pa.string()),
                pa.field("kafka_topic", pa.string()),
                pa.field("kafka_partition", pa.int32()),
                pa.field("kafka_offset", pa.int64()),
            ]
        )

        try:
            self._iceberg_table = self._catalog.load_table(identifier)
        except NoSuchTableError:
            try:
                self._catalog.create_namespace(self._namespace)
            except (NamespaceAlreadyExistsError, NoSuchNamespaceError):
                pass

            base_location = warehouse_location.rstrip("/")
            table_location = f"{base_location}/{self._namespace}/{self._table}"
            self._iceberg_table = self._catalog.create_table(
                identifier=identifier,
                schema=self._arrow_schema,
                location=table_location,
                properties={"format-version": "2"},
            )

        _disable_remote_s3_signing(self._iceberg_table)

        logger.info(
            "Iceberg sink ready (catalog=%s uri=%s table=%s.%s)",
            self._catalog_name,
            catalog_uri,
            self._namespace,
            self._table,
        )

    def add(
        self,
        value: Any,
        key: Any,
        timestamp: int,
        headers: Any,
        topic: str,
        partition: int,
        offset: int,
    ):
        if not isinstance(value, dict):
            return
        if not value.get("file_hash"):
            return

        self._buffer.append(
            {
                "processed_at": _parse_iso8601_utc(value.get("processed_at")),
                "filename": value.get("filename"),
                "file_hash": str(value.get("file_hash")),
                "file_size": value.get("file_size"),
                "mime_type": value.get("mime_type"),
                "kafka_topic": topic,
                "kafka_partition": int(partition),
                "kafka_offset": int(offset),
            }
        )

    def flush(self):
        if not self._buffer:
            return
        if self._iceberg_table is None:
            raise RuntimeError("Iceberg table not initialized")

        rows = self._buffer
        self._buffer = []

        import pyarrow as pa

        if self._arrow_schema is None:
            raise RuntimeError("Iceberg Arrow schema not initialized")

        # Build a typed Arrow table to match the Iceberg schema exactly.
        table = pa.Table.from_pydict(
            {
                "processed_at": pa.array(
                    [r.get("processed_at") for r in rows],
                    type=pa.timestamp("us", tz="UTC"),
                ),
                "filename": pa.array([r.get("filename") for r in rows], type=pa.string()),
                "file_hash": pa.array([r.get("file_hash") for r in rows], type=pa.string()),
                "file_size": pa.array([r.get("file_size") for r in rows], type=pa.int64()),
                "mime_type": pa.array([r.get("mime_type") for r in rows], type=pa.string()),
                "kafka_topic": pa.array([r.get("kafka_topic") for r in rows], type=pa.string()),
                "kafka_partition": pa.array(
                    [r.get("kafka_partition") for r in rows],
                    type=pa.int32(),
                ),
                "kafka_offset": pa.array([r.get("kafka_offset") for r in rows], type=pa.int64()),
            },
            schema=self._arrow_schema,
        )
        # Append is an Iceberg atomic commit.
        self._iceberg_table.append(table)
