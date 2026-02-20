"""Image Processing ETL DAG (manual)

Manual, UI-triggered pipeline that is compatible with the streaming image-service:
1) Scan the watch folder for images (same mount as image-service.yaml: /data/incoming)
2) Produce base64-encoded image messages to Kafka (same schema as image_producer.py)
3) Consume those Kafka messages, upload to SeaweedFS S3, and store metadata in PostgreSQL

Notes:
- This DAG is intentionally NOT scheduled; trigger it manually from the Airflow UI.
- It assumes the Airflow scheduler pod can read /data/incoming (see install-platform.sh).
"""

from __future__ import annotations

from datetime import datetime, timedelta
import base64
import hashlib
import json
import mimetypes
import os
from pathlib import Path
from typing import Any

from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.providers.postgres.operators.postgres import PostgresOperator

default_args = {
    'owner': 'data-platform',
    'depends_on_past': False,
    'start_date': datetime(2026, 2, 11),
    'email_on_failure': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=2),
}

dag = DAG(
    'image_processing_etl',
    default_args=default_args,
    description='ETL pipeline for image processing with Spark',
    schedule=None,  # Manual trigger only
    max_active_runs=1,
    catchup=False,
    tags=['etl', 'image-processing', 'spark'],
)


WATCH_PATH = Path(os.getenv('WATCH_PATH', '/data/incoming'))
KAFKA_BOOTSTRAP_SERVERS = os.getenv('KAFKA_BOOTSTRAP_SERVERS', 'kafka.default.svc.cluster.local:9092')
KAFKA_TOPIC = os.getenv('KAFKA_TOPIC', 'image-uploads')
KAFKA_GROUP_ID = os.getenv('KAFKA_GROUP_ID', 'airflow-manual-image-consumer')

MINIO_ENDPOINT = os.getenv('MINIO_ENDPOINT', 'seaweedfs-s3.default.svc.cluster.local:8333')
MINIO_ACCESS_KEY = os.getenv('MINIO_ACCESS_KEY', 'admin')
MINIO_SECRET_KEY = os.getenv('MINIO_SECRET_KEY', 'minio_password')
MINIO_BUCKET = os.getenv('MINIO_BUCKET', 'images')

S3_ENDPOINT_URL = os.getenv('S3_ENDPOINT_URL')
S3_REGION = os.getenv('S3_REGION', 'us-east-1')

POSTGRES_CONN_ID = os.getenv('POSTGRES_CONN_ID', 'postgres_default')


def scan_and_produce_images(**context: Any) -> int:
    """Scan WATCH_PATH and produce base64 image messages to Kafka.

    Message schema matches manifests/streaming/image-service/image_producer.py so that the
    streaming consumer (or this DAG's consume step) can process it.
    """

    from kafka import KafkaProducer

    produced_count = 0

    if not WATCH_PATH.exists():
        print(f"ℹ️ Watch folder doesn't exist: {WATCH_PATH}")
        context['task_instance'].xcom_push(key='images_produced', value=0)
        return 0

    supported_extensions = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.webp'}

    producer = KafkaProducer(
        bootstrap_servers=KAFKA_BOOTSTRAP_SERVERS.split(','),
        max_request_size=26214400,  # 25MiB
        compression_type='gzip',
        acks='all',
        retries=3,
    )

    pg_hook = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)

    for file_path in sorted(WATCH_PATH.iterdir()):
        if file_path.is_dir():
            continue
        if file_path.suffix.lower() not in supported_extensions:
            continue

        try:
            image_data = file_path.read_bytes()
            file_hash = hashlib.sha256(image_data).hexdigest()

            # Skip if already present in DB to avoid flooding Kafka on repeated manual runs.
            exists = pg_hook.get_first(
                "SELECT 1 FROM image_metadata WHERE file_hash = %s LIMIT 1;",
                parameters=(file_hash,),
            )
            if exists:
                print(f"↷ Skipping already-ingested image: {file_path.name}")
                continue

            mime_type, _ = mimetypes.guess_type(str(file_path))
            mime_type = mime_type or 'application/octet-stream'

            message = {
                'filename': file_path.name,
                'filepath': str(file_path.absolute()),
                'file_size': len(image_data),
                'file_hash': file_hash,
                'mime_type': mime_type,
                'timestamp': datetime.now().isoformat(),
                'image_data': base64.b64encode(image_data).decode('utf-8'),
            }

            payload = json.dumps(message).encode('utf-8')
            producer.send(
                KAFKA_TOPIC,
                key=file_hash.encode('utf-8'),
                value=payload,
            )
            produced_count += 1
            print(f"✓ Sent {file_path.name} to Kafka")
        except Exception as e:
            print(f"✗ Failed to produce {file_path.name}: {e}")

    producer.flush()
    producer.close()

    context['task_instance'].xcom_push(key='images_produced', value=produced_count)
    print(f"✓ Produced {produced_count} images to Kafka")
    return produced_count


def check_if_processing_needed(**context):
    """Check if there are images to process"""
    ti = context['task_instance']
    images_produced = ti.xcom_pull(key='images_produced', task_ids='scan_and_produce')
    
    # Only run consumer if we have images
    if images_produced and images_produced > 0:
        return 'consume_and_store'
    else:
        return 'skip_processing'


def consume_and_store_images(**context: Any) -> int:
    """Consume from Kafka and store in SeaweedFS (S3) + PostgreSQL.

    Expects message schema created by scan_and_produce_images (base64 image_data).
    """

    from kafka import KafkaConsumer
    import boto3
    from botocore.config import Config
    from botocore.exceptions import ClientError

    processed_count = 0

    consumer = KafkaConsumer(
        KAFKA_TOPIC,
        bootstrap_servers=KAFKA_BOOTSTRAP_SERVERS.split(','),
        group_id=KAFKA_GROUP_ID,
        auto_offset_reset='earliest',
        enable_auto_commit=True,
        fetch_max_bytes=31457280,
        max_partition_fetch_bytes=26214400,
        value_deserializer=lambda m: json.loads(m.decode('utf-8')),
        consumer_timeout_ms=8000,
    )

    endpoint_url = S3_ENDPOINT_URL
    if not endpoint_url:
        endpoint_url = MINIO_ENDPOINT
        if not endpoint_url.startswith('http://') and not endpoint_url.startswith('https://'):
            endpoint_url = f"http://{endpoint_url}"

    s3 = boto3.client(
        's3',
        endpoint_url=endpoint_url,
        aws_access_key_id=MINIO_ACCESS_KEY,
        aws_secret_access_key=MINIO_SECRET_KEY,
        region_name=S3_REGION,
        config=Config(
            signature_version='s3v4',
            s3={
                # SeaweedFS S3 gateway works well with path-style addressing.
                'addressing_style': 'path',
            },
        ),
    )

    # Ensure bucket exists
    try:
        s3.head_bucket(Bucket=MINIO_BUCKET)
    except ClientError:
        # SeaweedFS typically accepts CreateBucket without LocationConstraint.
        s3.create_bucket(Bucket=MINIO_BUCKET)

    pg_hook = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)

    for msg in consumer:
        try:
            data = msg.value

            filename = data['filename']
            file_hash = data['file_hash']
            mime_type = data.get('mime_type') or 'application/octet-stream'

            image_data = base64.b64decode(data['image_data'])
            today = datetime.now().strftime('%Y/%m/%d')
            object_name = f"images/{today}/{filename}"

            s3.put_object(
                Bucket=MINIO_BUCKET,
                Key=object_name,
                Body=image_data,
                ContentType=mime_type,
            )

            pg_hook.run(
                """
                INSERT INTO image_metadata
                    (filename, file_hash, file_size, mime_type, s3_path,
                     uploaded_at, source_path, kafka_offset, kafka_partition, processed_at)
                VALUES
                    (%s, %s, %s, %s, %s,
                     %s, %s, %s, %s, %s)
                ON CONFLICT (file_hash) DO NOTHING;
                """,
                parameters=(
                    filename,
                    file_hash,
                    data.get('file_size', len(image_data)),
                    mime_type,
                    object_name,
                    datetime.fromisoformat(data['timestamp']) if data.get('timestamp') else datetime.now(),
                    data.get('filepath'),
                    msg.offset,
                    msg.partition,
                    datetime.now(),
                ),
            )

            processed_count += 1
            print(f"✓ Stored {filename} -> s3://{MINIO_BUCKET}/{object_name}")
        except Exception as e:
            print(f"✗ Error processing message: {e}")

    consumer.close()

    context['task_instance'].xcom_push(key='images_stored', value=processed_count)
    print(f"✓ Stored {processed_count} images")
    return processed_count


# Tasks

ensure_tables_task = PostgresOperator(
    task_id='ensure_image_metadata_table',
    postgres_conn_id=POSTGRES_CONN_ID,
    sql="""
        CREATE TABLE IF NOT EXISTS image_metadata (
            id SERIAL PRIMARY KEY,
            filename VARCHAR(255) NOT NULL,
            file_hash VARCHAR(64) UNIQUE NOT NULL,
            file_size BIGINT NOT NULL,
            mime_type VARCHAR(50),
            s3_path VARCHAR(500) NOT NULL,
            uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            source_path TEXT,
            kafka_offset BIGINT,
            kafka_partition INT,
            processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_image_metadata_file_hash
        ON image_metadata(file_hash);
    """,
    dag=dag,
)

scan_task = PythonOperator(
    task_id='scan_and_produce',
    python_callable=scan_and_produce_images,
    dag=dag,
)

check_processing_task = PythonOperator(
    task_id='check_if_processing_needed',
    python_callable=check_if_processing_needed,
    dag=dag,
)

skip_processing = PythonOperator(
    task_id='skip_processing',
    python_callable=lambda: print("ℹ️ No images to process, skipping"),
    dag=dag,
)

consume_task = PythonOperator(
    task_id='consume_and_store',
    python_callable=consume_and_store_images,
    trigger_rule='one_success',
    dag=dag,
)

cleanup_task = PostgresOperator(
    task_id='cleanup_old_data',
    postgres_conn_id=POSTGRES_CONN_ID,
    sql="""
        -- Delete metadata for images older than 30 days
        DELETE FROM image_metadata 
        WHERE uploaded_at < CURRENT_DATE - INTERVAL '30 days';
    """,
    dag=dag,
)

# Pipeline flow
pipeline = ensure_tables_task >> scan_task >> check_processing_task >> [consume_task, skip_processing] >> cleanup_task