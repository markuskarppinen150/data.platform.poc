#!/usr/bin/env python3
import logging
import os
from datetime import datetime, timezone

from quixstreams import Application

from app.sinks import IcebergProcessedSink, PostgresConfig, PostgresProcessedSink

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("quix-streams-service")


def _transform(value: dict) -> dict:
    """Transform incoming Kafka JSON messages into a smaller processed payload."""
    now = datetime.now(timezone.utc).isoformat()

    if not isinstance(value, dict):
        return {"processed_at": now, "raw": value}

    filename = value.get("filename")
    file_hash = value.get("file_hash")
    file_size = value.get("file_size")
    mime_type = value.get("mime_type")

    return {
        "processed_at": now,
        "filename": filename,
        "file_hash": file_hash,
        "file_size": file_size,
        "mime_type": mime_type,
    }


def main() -> None:
    broker = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka.default.svc.cluster.local:9092")
    input_topic_name = os.getenv("KAFKA_INPUT_TOPIC", "image-uploads")
    output_topic_name = os.getenv("KAFKA_OUTPUT_TOPIC", "image-uploads-processed")
    consumer_group = os.getenv("KAFKA_CONSUMER_GROUP", "quix-image-processor")
    auto_offset_reset = os.getenv("KAFKA_AUTO_OFFSET_RESET", "latest")
    commit_interval = float(os.getenv("QUIX_COMMIT_INTERVAL", "5.0"))
    processing_guarantee = os.getenv("QUIX_PROCESSING_GUARANTEE", "at-least-once")

    logger.info("Starting Quix Streams service")
    logger.info("Kafka broker: %s", broker)
    logger.info("Input topic: %s", input_topic_name)
    logger.info("Output topic: %s", output_topic_name)
    logger.info("Consumer group: %s", consumer_group)
    logger.info("Auto offset reset: %s", auto_offset_reset)
    logger.info("Commit interval: %ss", commit_interval)
    logger.info("Processing guarantee: %s", processing_guarantee)

    app = Application(
        broker_address=broker,
        consumer_group=consumer_group,
        auto_offset_reset=auto_offset_reset,
        commit_interval=commit_interval,
        processing_guarantee=processing_guarantee,  # external sinks are still at-least-once
    )

    input_topic = app.topic(input_topic_name, value_deserializer="json")
    output_topic = app.topic(output_topic_name, value_serializer="json")

    sdf = app.dataframe(topic=input_topic)
    sdf = sdf.apply(_transform)

    # 1) Continue emitting processed events to Kafka
    sdf.to_topic(output_topic)

    # 2) Sink to PostgreSQL
    if os.getenv("ENABLE_POSTGRES_SINK", "true").lower() == "true":
        pg_cfg = PostgresConfig.from_env()
        pg_table = os.getenv("POSTGRES_TABLE", "image_uploads_processed")
        sdf.sink(PostgresProcessedSink(pg=pg_cfg, table_name=pg_table))
        logger.info("PostgreSQL sink enabled (table=%s)", pg_table)
    else:
        logger.info("PostgreSQL sink disabled")

    # 3) Sink to Iceberg via Lakekeeper REST catalog
    if os.getenv("ENABLE_ICEBERG_SINK", "true").lower() == "true":
        ns = os.getenv("ICEBERG_NAMESPACE", "default")
        tbl = os.getenv("ICEBERG_TABLE", "image_uploads_processed")
        sdf.sink(IcebergProcessedSink(namespace=ns, table=tbl))
        logger.info("Iceberg sink enabled (table=%s.%s)", ns, tbl)
    else:
        logger.info("Iceberg sink disabled")

    # Run the application (it automatically tracks the dataframe pipeline)
    app.run()


if __name__ == "__main__":
    main()
