"""
Image Processing Pipeline DAG

Orchestrates the image ingestion workflow:
1. Check service health (Kafka, MinIO, PostgreSQL)
2. Monitor incoming images
3. Validate processing
4. Generate reports
"""
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator, BranchPythonOperator
from airflow.operators.bash import BashOperator
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.utils.trigger_rule import TriggerRule
import json

default_args = {
    'owner': 'data-platform',
    'depends_on_past': False,
    'start_date': datetime(2026, 2, 11),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=1),
}

dag = DAG(
    'image_processing_pipeline',
    default_args=default_args,
    description='Orchestrate image ingestion from folder → Kafka → MinIO → PostgreSQL',
    schedule='*/5 * * * *',  # Every 5 minutes
    catchup=False,
    tags=['image-processing', 'kafka', 'minio', 'etl'],
)


def check_kafka_health(**context):
    """Check if Kafka is healthy and topics exist"""
    from kafka import KafkaConsumer
    from kafka.admin import KafkaAdminClient
    
    try:
        admin_client = KafkaAdminClient(
            bootstrap_servers='kafka.default.svc.cluster.local:9092',
            request_timeout_ms=5000
        )
        
        # Check if image-uploads topic exists
        topics = admin_client.list_topics()
        
        if 'image-uploads' not in topics:
            raise Exception("Topic 'image-uploads' does not exist")
        
        # Get topic details
        metadata = admin_client.describe_topics(['image-uploads'])
        
        context['task_instance'].xcom_push(key='kafka_status', value='healthy')
        context['task_instance'].xcom_push(key='topic_partitions', value=len(metadata[0]['partitions']))
        
        print(f"✓ Kafka is healthy. Topic 'image-uploads' has {len(metadata[0]['partitions'])} partitions")
        return True
        
    except Exception as e:
        print(f"✗ Kafka health check failed: {e}")
        context['task_instance'].xcom_push(key='kafka_status', value='unhealthy')
        raise


def check_minio_health(**context):
    """Check if MinIO is accessible and bucket exists"""
    from minio import Minio
    
    try:
        minio_client = Minio(
            'minio.default.svc.cluster.local:9000',
            access_key='admin',
            secret_key='minio_password',
            secure=False
        )
        
        # Check if images bucket exists
        if not minio_client.bucket_exists('images'):
            minio_client.make_bucket('images')
            print("✓ Created 'images' bucket")
        else:
            print("✓ MinIO is healthy. Bucket 'images' exists")
        
        # Count objects
        objects = list(minio_client.list_objects('images', recursive=True))
        object_count = len(objects)
        
        context['task_instance'].xcom_push(key='minio_status', value='healthy')
        context['task_instance'].xcom_push(key='total_objects', value=object_count)
        
        print(f"✓ Total objects in MinIO: {object_count}")
        return True
        
    except Exception as e:
        print(f"✗ MinIO health check failed: {e}")
        context['task_instance'].xcom_push(key='minio_status', value='unhealthy')
        raise


def check_postgres_health(**context):
    """Check PostgreSQL connection and table exists"""
    pg_hook = PostgresHook(postgres_conn_id='postgres_default')
    
    try:
        # Test connection
        conn = pg_hook.get_conn()
        cursor = conn.cursor()
        
        # Check if table exists
        cursor.execute("""
            SELECT EXISTS (
                SELECT FROM information_schema.tables 
                WHERE table_schema = 'public' 
                AND table_name = 'image_metadata'
            );
        """)
        
        table_exists = cursor.fetchone()[0]
        
        if not table_exists:
            raise Exception("Table 'image_metadata' does not exist")
        
        # Get row count
        cursor.execute("SELECT COUNT(*) FROM image_metadata;")
        row_count = cursor.fetchone()[0]
        
        cursor.close()
        conn.close()
        
        context['task_instance'].xcom_push(key='postgres_status', value='healthy')
        context['task_instance'].xcom_push(key='total_images', value=row_count)
        
        print(f"✓ PostgreSQL is healthy. Total images: {row_count}")
        return True
        
    except Exception as e:
        print(f"✗ PostgreSQL health check failed: {e}")
        context['task_instance'].xcom_push(key='postgres_status', value='unhealthy')
        raise


def check_kafka_lag(**context):
    """Check if consumer is keeping up with producer"""
    from kafka import KafkaConsumer, TopicPartition
    
    try:
        consumer = KafkaConsumer(
            bootstrap_servers='kafka.default.svc.cluster.local:9092',
            group_id='image-consumer-group',
            enable_auto_commit=False
        )
        
        # Get topic partitions
        partitions = consumer.partitions_for_topic('image-uploads')
        
        if not partitions:
            print("ℹ️ No partitions found for topic")
            return 'no_lag'
        
        total_lag = 0
        
        for partition_id in partitions:
            tp = TopicPartition('image-uploads', partition_id)
            
            # Get last offset
            consumer.seek_to_end(tp)
            last_offset = consumer.position(tp)
            
            # Get committed offset
            committed = consumer.committed(tp)
            committed_offset = committed if committed else 0
            
            lag = last_offset - committed_offset
            total_lag += lag
            
            print(f"Partition {partition_id}: Last={last_offset}, Committed={committed_offset}, Lag={lag}")
        
        consumer.close()
        
        context['task_instance'].xcom_push(key='kafka_lag', value=total_lag)
        
        # Branch based on lag
        if total_lag > 100:
            print(f"⚠️ High lag detected: {total_lag} messages")
            return 'alert_high_lag'
        else:
            print(f"✓ Lag is acceptable: {total_lag} messages")
            return 'no_lag'
            
    except Exception as e:
        print(f"✗ Lag check failed: {e}")
        return 'no_lag'


def get_latest_images(**context):
    """Query latest processed images"""
    pg_hook = PostgresHook(postgres_conn_id='postgres_default')
    
    query = """
        SELECT 
            filename,
            file_size,
            mime_type,
            s3_path,
            uploaded_at
        FROM image_metadata
        ORDER BY uploaded_at DESC
        LIMIT 10;
    """
    
    results = pg_hook.get_records(query)
    
    images = []
    for row in results:
        images.append({
            'filename': row[0],
            'size': row[1],
            'type': row[2],
            's3_path': row[3],
            'uploaded': str(row[4])
        })
    
    context['task_instance'].xcom_push(key='latest_images', value=images)
    
    print(f"✓ Retrieved {len(images)} latest images")
    for img in images:
        print(f"  - {img['filename']} ({img['size']} bytes) at {img['uploaded']}")


def generate_report(**context):
    """Generate daily processing report"""
    ti = context['task_instance']
    
    report = {
        'timestamp': str(datetime.now()),
        'kafka_status': ti.xcom_pull(key='kafka_status', task_ids='check_kafka'),
        'minio_status': ti.xcom_pull(key='minio_status', task_ids='check_minio'),
        'postgres_status': ti.xcom_pull(key='postgres_status', task_ids='check_postgres'),
        'total_images': ti.xcom_pull(key='total_images', task_ids='check_postgres'),
        'total_objects': ti.xcom_pull(key='total_objects', task_ids='check_minio'),
        'kafka_lag': ti.xcom_pull(key='kafka_lag', task_ids='check_kafka_lag'),
        'latest_images': ti.xcom_pull(key='latest_images', task_ids='get_latest_images')
    }
    
    print("=" * 60)
    print("IMAGE PROCESSING PIPELINE REPORT")
    print("=" * 60)
    print(json.dumps(report, indent=2))
    print("=" * 60)
    
    # Store report (could send to S3, email, etc.)
    context['task_instance'].xcom_push(key='report', value=report)


# Task definitions

check_kafka = PythonOperator(
    task_id='check_kafka',
    python_callable=check_kafka_health,
    dag=dag,
)

check_minio = PythonOperator(
    task_id='check_minio',
    python_callable=check_minio_health,
    dag=dag,
)

check_postgres = PythonOperator(
    task_id='check_postgres',
    python_callable=check_postgres_health,
    dag=dag,
)

check_kafka_lag_task = BranchPythonOperator(
    task_id='check_kafka_lag',
    python_callable=check_kafka_lag,
    dag=dag,
)

alert_high_lag = BashOperator(
    task_id='alert_high_lag',
    bash_command='echo "⚠️ WARNING: High Kafka consumer lag detected! Consider scaling consumers."',
    dag=dag,
)

no_lag = BashOperator(
    task_id='no_lag',
    bash_command='echo "✓ Kafka lag is within acceptable range"',
    dag=dag,
)

get_latest_images_task = PythonOperator(
    task_id='get_latest_images',
    python_callable=get_latest_images,
    trigger_rule=TriggerRule.ONE_SUCCESS,
    dag=dag,
)

get_stats = SQLExecuteQueryOperator(
    task_id='get_daily_stats',
    conn_id='postgres_default',
    sql="""
        SELECT 
            COUNT(*) as total_today,
            SUM(file_size) as total_size,
            COUNT(DISTINCT mime_type) as unique_types
        FROM image_metadata
        WHERE uploaded_at >= CURRENT_DATE;
    """,
    dag=dag,
)

generate_report_task = PythonOperator(
    task_id='generate_report',
    python_callable=generate_report,
    trigger_rule=TriggerRule.ALL_DONE,
    dag=dag,
)

# Define task dependencies
[check_kafka, check_minio, check_postgres] >> check_kafka_lag_task
check_kafka_lag_task >> [alert_high_lag, no_lag]
[alert_high_lag, no_lag] >> get_latest_images_task >> get_stats >> generate_report_task
