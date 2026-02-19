#!/usr/bin/env python3
"""
Image Producer - Monitors a folder for new images and sends them to Kafka
"""
import os
import time
import json
import base64
import hashlib
from pathlib import Path
from datetime import datetime
from kafka import KafkaProducer
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class ImageHandler:
    """Handles new image files in the watched directory using polling"""
    
    SUPPORTED_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.webp'}
    
    def __init__(self, kafka_producer, kafka_topic, watch_path):
        self.producer = kafka_producer
        self.topic = kafka_topic
        self.watch_path = Path(watch_path)
        self.processed_files = set()
    
    def check_for_new_files(self):
        """Poll directory for new image files"""
        try:
            # Get all files in the directory
            for file_path in self.watch_path.iterdir():
                # Skip directories
                if file_path.is_dir():
                    continue
                
                # Check if it's an image file
                if file_path.suffix.lower() not in self.SUPPORTED_EXTENSIONS:
                    continue
                
                # Skip already processed files
                file_key = str(file_path.absolute())
                if file_key in self.processed_files:
                    continue
                
                # Process the new file
                try:
                    self.process_image(file_path)
                    self.processed_files.add(file_key)
                except Exception as e:
                    logger.error(f"Error processing {file_path}: {e}")
        except Exception as e:
            logger.error(f"Error checking directory: {e}")
    
    def process_image(self, file_path: Path):
        """Process and send image to Kafka"""
        logger.info(f"Processing new image: {file_path.name}")
        
        # Read image file
        with open(file_path, 'rb') as f:
            image_data = f.read()
        
        # Calculate hash for deduplication
        image_hash = hashlib.sha256(image_data).hexdigest()
        
        # Get file metadata
        file_stats = file_path.stat()
        
        # Create message payload
        message = {
            'filename': file_path.name,
            'filepath': str(file_path.absolute()),
            'file_size': file_stats.st_size,
            'file_hash': image_hash,
            'mime_type': self._get_mime_type(file_path.suffix),
            'timestamp': datetime.now().isoformat(),
            'image_data': base64.b64encode(image_data).decode('utf-8')
        }

        payload = json.dumps(message).encode('utf-8')
        
        # Send to Kafka
        try:
            future = self.producer.send(
                self.topic,
                key=image_hash.encode('utf-8'),
                value=payload
            )
            
            # Wait for confirmation
            record_metadata = future.get(timeout=10)
            
            logger.info(
                f"✓ Sent {file_path.name} to Kafka "
                f"(topic: {record_metadata.topic}, "
                f"partition: {record_metadata.partition}, "
                f"offset: {record_metadata.offset})"
            )
            
        except Exception as e:
            logger.error(
                f"Failed to send {file_path.name} to Kafka: {e} "
                f"(file_size={file_stats.st_size} bytes, kafka_payload={len(payload)} bytes)"
            )
            raise
    
    @staticmethod
    def _get_mime_type(extension: str) -> str:
        """Get MIME type from file extension"""
        mime_types = {
            '.jpg': 'image/jpeg',
            '.jpeg': 'image/jpeg',
            '.png': 'image/png',
            '.gif': 'image/gif',
            '.bmp': 'image/bmp',
            '.tiff': 'image/tiff',
            '.webp': 'image/webp'
        }
        return mime_types.get(extension.lower(), 'application/octet-stream')


def main():
    # Configuration
    KAFKA_BOOTSTRAP_SERVERS = os.getenv('KAFKA_BOOTSTRAP_SERVERS', 'localhost:9092')
    KAFKA_TOPIC = os.getenv('KAFKA_TOPIC', 'image-uploads')
    WATCH_PATH = os.getenv('WATCH_PATH', './images/incoming')
    POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', '1'))  # seconds
    
    # Create watch directory if it doesn't exist
    watch_dir = Path(WATCH_PATH)
    watch_dir.mkdir(parents=True, exist_ok=True)
    
    logger.info(f"Starting Image Producer")
    logger.info(f"Kafka Servers: {KAFKA_BOOTSTRAP_SERVERS}")
    logger.info(f"Kafka Topic: {KAFKA_TOPIC}")
    logger.info(f"Watch Path: {watch_dir.absolute()}")
    logger.info(f"Poll Interval: {POLL_INTERVAL}s")
    
    # Initialize Kafka producer
    producer = KafkaProducer(
        bootstrap_servers=KAFKA_BOOTSTRAP_SERVERS.split(','),
        max_request_size=26214400,  # 25MiB (payload includes base64 + JSON overhead)
        compression_type='gzip',
        acks='all',
        retries=3
    )
    
    # Setup image handler with polling
    handler = ImageHandler(producer, KAFKA_TOPIC, watch_dir)
    
    logger.info(f"👁️  Polling {watch_dir} for new images every {POLL_INTERVAL}s...")
    logger.info("Press Ctrl+C to stop")
    
    try:
        while True:
            handler.check_for_new_files()
            time.sleep(POLL_INTERVAL)
    except KeyboardInterrupt:
        logger.info("Stopping producer...")
        producer.close()
    
    logger.info("Image Producer stopped")


if __name__ == '__main__':
    main()
