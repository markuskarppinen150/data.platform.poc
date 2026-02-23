#!/usr/bin/env python3
"""
Image Consumer - Reads images from Kafka, uploads to S3-compatible storage (SeaweedFS), and stores metadata in PostgreSQL
"""
import os
import json
import base64
from datetime import datetime
from io import BytesIO
from kafka import KafkaConsumer
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
import psycopg2
from psycopg2.extras import execute_values
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class ImageConsumer:
    """Consumes images from Kafka and stores them in S3-compatible storage and PostgreSQL"""
    
    def __init__(self, kafka_servers, kafka_topic, kafka_group_id,
                 s3_endpoint, s3_access_key_id, s3_secret_access_key,
                 s3_bucket, postgres_config, s3_region="us-east-1"):
        
        # Initialize Kafka Consumer
        self.consumer = KafkaConsumer(
            kafka_topic,
            bootstrap_servers=kafka_servers.split(','),
            group_id=kafka_group_id,
            auto_offset_reset='earliest',
            enable_auto_commit=True,
            fetch_max_bytes=31457280,
            max_partition_fetch_bytes=26214400,
            value_deserializer=lambda m: json.loads(m.decode('utf-8'))
        )
        
        # Initialize S3 client (SeaweedFS S3 gateway)
        endpoint_url = s3_endpoint
        if endpoint_url and not endpoint_url.startswith("http"):
            endpoint_url = f"http://{endpoint_url}"

        os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
        self.s3_client = boto3.client(
            "s3",
            endpoint_url=endpoint_url,
            aws_access_key_id=s3_access_key_id,
            aws_secret_access_key=s3_secret_access_key,
            region_name=s3_region,
            config=Config(s3={"addressing_style": "path"}),
        )
        
        self.bucket_name = s3_bucket
        self._ensure_bucket_exists()
        
        # Initialize PostgreSQL Connection
        self.pg_config = postgres_config
        self._init_database()
        
        logger.info("Image Consumer initialized successfully")
    
    def _ensure_bucket_exists(self):
        """Create bucket if it doesn't exist"""
        try:
            self.s3_client.head_bucket(Bucket=self.bucket_name)
            logger.info(f"Bucket exists: {self.bucket_name}")
        except ClientError as e:
            error_code = (e.response or {}).get("Error", {}).get("Code")
            if error_code in {"404", "NoSuchBucket", "NotFound"}:
                self.s3_client.create_bucket(Bucket=self.bucket_name)
                logger.info(f"Created bucket: {self.bucket_name}")
                return
            logger.error(f"Error checking/creating bucket: {e}")
            raise
    
    def _init_database(self):
        """Initialize PostgreSQL table for image metadata"""
        try:
            conn = psycopg2.connect(**self.pg_config)
            cursor = conn.cursor()
            
            # Create table if not exists
            cursor.execute("""
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
                )
            """)
            
            # Create index on file_hash for fast lookups
            cursor.execute("""
                CREATE INDEX IF NOT EXISTS idx_file_hash 
                ON image_metadata(file_hash)
            """)
            
            conn.commit()
            cursor.close()
            conn.close()
            
            logger.info("PostgreSQL table initialized")
            
        except Exception as e:
            logger.error(f"Error initializing database: {e}")
            raise
    
    def _upload_to_s3(self, image_data: bytes, filename: str, mime_type: str) -> str:
        """Upload image to S3-compatible storage and return the object key"""
        # Generate S3 path with date partitioning
        today = datetime.now().strftime('%Y/%m/%d')
        s3_path = f"images/{today}/{filename}"
        
        try:
            self.s3_client.put_object(
                Bucket=self.bucket_name,
                Key=s3_path,
                Body=BytesIO(image_data),
                ContentType=mime_type,
            )
            
            logger.info(f"✓ Uploaded to S3: s3://{self.bucket_name}/{s3_path}")
            return s3_path
            
        except ClientError as e:
            logger.error(f"Error uploading to S3: {e}")
            raise
    
    def _store_metadata(self, message: dict, s3_path: str, 
                       partition: int, offset: int):
        """Store image metadata in PostgreSQL"""
        try:
            conn = psycopg2.connect(**self.pg_config)
            cursor = conn.cursor()
            
            cursor.execute("""
                INSERT INTO image_metadata 
                (filename, file_hash, file_size, mime_type, s3_path, 
                 source_path, kafka_offset, kafka_partition, uploaded_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (file_hash) DO NOTHING
            """, (
                message['filename'],
                message['file_hash'],
                message['file_size'],
                message['mime_type'],
                s3_path,
                message.get('filepath'),
                offset,
                partition,
                datetime.fromisoformat(message['timestamp'])
            ))
            
            conn.commit()
            cursor.close()
            conn.close()
            
            logger.info(f"✓ Stored metadata in PostgreSQL for {message['filename']}")
            
        except Exception as e:
            logger.error(f"Error storing metadata in PostgreSQL: {e}")
            raise
    
    def process_message(self, message_value: dict, partition: int, offset: int):
        """Process a single Kafka message"""
        try:
            filename = message_value['filename']
            file_hash = message_value['file_hash']
            
            logger.info(f"Processing: {filename} (hash: {file_hash[:8]}...)")
            
            # Decode base64 image data
            image_data = base64.b64decode(message_value['image_data'])
            
            # Upload to S3
            s3_path = self._upload_to_s3(
                image_data,
                filename,
                message_value['mime_type']
            )
            
            # Store metadata in PostgreSQL
            self._store_metadata(message_value, s3_path, partition, offset)
            
            logger.info(f"✅ Successfully processed {filename}")
            
        except Exception as e:
            logger.error(f"Error processing message: {e}")
            # Don't raise - continue processing other messages
    
    def start(self):
        """Start consuming messages from Kafka"""
        logger.info("🚀 Starting Image Consumer...")
        logger.info("Waiting for messages... (Press Ctrl+C to stop)")
        
        try:
            for message in self.consumer:
                self.process_message(
                    message.value,
                    message.partition,
                    message.offset
                )
        except KeyboardInterrupt:
            logger.info("Stopping consumer...")
        finally:
            self.consumer.close()
            logger.info("Image Consumer stopped")


def main():
    # Configuration from environment variables
    KAFKA_BOOTSTRAP_SERVERS = os.getenv('KAFKA_BOOTSTRAP_SERVERS', 'localhost:9092')
    KAFKA_TOPIC = os.getenv('KAFKA_TOPIC', 'image-uploads')
    KAFKA_GROUP_ID = os.getenv('KAFKA_GROUP_ID', 'image-consumer-group')
    
    S3_ENDPOINT = os.getenv('S3_ENDPOINT', 'http://localhost:9000')
    S3_ACCESS_KEY_ID = os.getenv('S3_ACCESS_KEY_ID', 'admin')
    S3_SECRET_ACCESS_KEY = os.getenv('S3_SECRET_ACCESS_KEY', 'seaweedfs_password')
    S3_BUCKET = os.getenv('S3_BUCKET', 'images')
    S3_REGION = os.getenv('S3_REGION', 'us-east-1')
    
    POSTGRES_CONFIG = {
        'host': os.getenv('POSTGRES_HOST', 'localhost'),
        'port': int(os.getenv('POSTGRES_PORT', '5432')),
        'database': os.getenv('POSTGRES_DB', 'postgres'),
        'user': os.getenv('POSTGRES_USER', 'postgres'),
        'password': os.getenv('POSTGRES_PASSWORD', 'postgres')
    }
    
    logger.info("Configuration:")
    logger.info(f"  Kafka: {KAFKA_BOOTSTRAP_SERVERS}")
    logger.info(f"  Topic: {KAFKA_TOPIC}")
    logger.info(f"  S3 Endpoint: {S3_ENDPOINT}")
    logger.info(f"  Bucket: {S3_BUCKET}")
    logger.info(f"  PostgreSQL: {POSTGRES_CONFIG['host']}:{POSTGRES_CONFIG['port']}")
    
    # Create and start consumer
    consumer = ImageConsumer(
        kafka_servers=KAFKA_BOOTSTRAP_SERVERS,
        kafka_topic=KAFKA_TOPIC,
        kafka_group_id=KAFKA_GROUP_ID,
        s3_endpoint=S3_ENDPOINT,
        s3_access_key_id=S3_ACCESS_KEY_ID,
        s3_secret_access_key=S3_SECRET_ACCESS_KEY,
        s3_bucket=S3_BUCKET,
        s3_region=S3_REGION,
        postgres_config=POSTGRES_CONFIG,
    )
    
    consumer.start()


if __name__ == '__main__':
    main()
