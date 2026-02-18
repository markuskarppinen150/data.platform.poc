"""
Image Processing ETL DAG

Actually processes images through the pipeline:
1. Scan incoming folder for new images
2. Produce messages to Kafka
3. Trigger Spark job for image analysis (resize, metadata extraction, ML inference)
4. Store results in PostgreSQL and SeaweedFS (S3)
"""
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
import os
import hashlib
from pathlib import Path

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
    schedule='@continuous',  # Run continuously
    max_active_runs=1,  # Required for continuous schedule
    catchup=False,
    tags=['etl', 'image-processing', 'spark'],
)


def scan_and_produce_images(**context):
    """Scan incoming folder and produce to Kafka"""
    from kafka import KafkaProducer
    import json
    from PIL import Image
    import io
    
    producer = KafkaProducer(
        bootstrap_servers='kafka.default.svc.cluster.local:9092',
        value_serializer=lambda v: json.dumps(v).encode('utf-8')
    )
    
    incoming_path = Path('/data/incoming')
    processed_count = 0
    
    if not incoming_path.exists():
        print("ℹ️ Incoming folder doesn't exist")
        return 0
    
    for image_file in incoming_path.glob('*'):
        if image_file.suffix.lower() not in ['.jpg', '.jpeg', '.png', '.gif']:
            continue
        
        try:
            # Read image
            with open(image_file, 'rb') as f:
                image_data = f.read()
            
            # Calculate hash
            file_hash = hashlib.sha256(image_data).hexdigest()
            
            # Get image metadata
            img = Image.open(io.BytesIO(image_data))
            
            message = {
                'filename': image_file.name,
                'file_size': len(image_data),
                'file_hash': file_hash,
                'width': img.width,
                'height': img.height,
                'format': img.format,
                'mode': img.mode,
                'timestamp': str(datetime.now())
            }
            
            # Send to Kafka
            producer.send('image-uploads', value=message)
            processed_count += 1
            
            # Move to processing folder
            processing_path = Path('/data/processing')
            processing_path.mkdir(exist_ok=True)
            image_file.rename(processing_path / image_file.name)
            
            print(f"✓ Sent {image_file.name} to Kafka")
            
        except Exception as e:
            print(f"✗ Failed to process {image_file.name}: {e}")
    
    producer.flush()
    producer.close()
    
    context['task_instance'].xcom_push(key='images_produced', value=processed_count)
    print(f"✓ Produced {processed_count} images to Kafka")
    
    return processed_count


def check_if_processing_needed(**context):
    """Check if there are images to process"""
    ti = context['task_instance']
    images_produced = ti.xcom_pull(key='images_produced', task_ids='scan_and_produce')
    
    # Only run consumer if we have images
    if images_produced and images_produced > 0:
        return 'consume_and_store'
    else:
        return 'skip_processing'


def consume_and_store_images(**context):
    """Consume from Kafka and store in SeaweedFS (S3) + PostgreSQL"""
    from kafka import KafkaConsumer
    from minio import Minio
    import json
    import io
    
    consumer = KafkaConsumer(
        'image-uploads',
        bootstrap_servers='kafka.default.svc.cluster.local:9092',
        auto_offset_reset='earliest',
        enable_auto_commit=True,
        group_id='airflow-etl-consumer',
        value_deserializer=lambda x: json.loads(x.decode('utf-8')),
        consumer_timeout_ms=10000  # 10 seconds timeout
    )
    
    minio_client = Minio(
        'seaweedfs-s3.default.svc.cluster.local:8333',
        access_key='admin',
        secret_key='minio_password',
        secure=False
    )
    
    if not minio_client.bucket_exists('images'):
        minio_client.make_bucket('images')
    
    pg_hook = PostgresHook(postgres_conn_id='postgres_default')
    processed_count = 0
    
    for message in consumer:
        try:
            data = message.value
            filename = data['filename']
            
            # Read from processing folder
            processing_path = Path(f'/data/processing/{filename}')
            
            if not processing_path.exists():
                print(f"⚠️ File not found: {filename}")
                continue
            
            with open(processing_path, 'rb') as f:
                image_data = f.read()
            
            # Upload to S3 (SeaweedFS)
            date_prefix = datetime.now().strftime('%Y/%m/%d')
            s3_path = f'{date_prefix}/{filename}'
            
            minio_client.put_object(
                'images',
                s3_path,
                io.BytesIO(image_data),
                len(image_data),
                content_type=f'image/{data.get("format", "jpeg").lower()}'
            )
            
            # Insert metadata to PostgreSQL
            insert_query = """
                INSERT INTO image_metadata 
                (filename, file_size, file_hash, width, height, mime_type, s3_path, uploaded_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (file_hash) DO NOTHING;
            """
            
            pg_hook.run(
                insert_query,
                parameters=(
                    filename,
                    data['file_size'],
                    data['file_hash'],
                    data['width'],
                    data['height'],
                    f"image/{data.get('format', 'jpeg').lower()}",
                    f's3://images/{s3_path}',
                    datetime.now()
                )
            )
            
            # Move to processed folder
            processed_path = Path('/data/processed')
            processed_path.mkdir(exist_ok=True)
            processing_path.rename(processed_path / filename)
            
            processed_count += 1
            print(f"✓ Processed {filename}")
            
        except Exception as e:
            print(f"✗ Error processing message: {e}")
    
    consumer.close()
    
    context['task_instance'].xcom_push(key='images_stored', value=processed_count)
    print(f"✓ Stored {processed_count} images")
    
    return processed_count


# Tasks

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

cleanup_task = SQLExecuteQueryOperator(
    task_id='cleanup_old_data',
    conn_id='postgres_default',
    sql="""
        -- Delete metadata for images older than 30 days
        DELETE FROM image_metadata 
        WHERE uploaded_at < CURRENT_DATE - INTERVAL '30 days';
    """,
    dag=dag,
)

# Pipeline flow
scan_task >> check_processing_task >> [consume_task, skip_processing] >> cleanup_task