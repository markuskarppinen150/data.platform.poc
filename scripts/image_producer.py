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
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from kafka import KafkaProducer
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class ImageHandler(FileSystemEventHandler):
    """Handles new image files in the watched directory"""
    
    SUPPORTED_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.webp'}
    
    def __init__(self, kafka_producer, kafka_topic, watch_path):
        self.producer = kafka_producer
        self.topic = kafka_topic
        self.watch_path = watch_path
        self.processed_files = set()
    
    def on_created(self, event):
        """Called when a file or directory is created"""
        if event.is_directory:
            return
        
        file_path = Path(event.src_path)
        
        # Check if it's an image file
        if file_path.suffix.lower() not in self.SUPPORTED_EXTENSIONS:
            logger.debug(f"Ignoring non-image file: {file_path}")
            return
        
        # Avoid processing the same file multiple times
        if str(file_path) in self.processed_files:
            return
        
        # Wait a bit to ensure file is fully written
        time.sleep(0.5)
        
        try:
            self.process_image(file_path)
            self.processed_files.add(str(file_path))
        except Exception as e:
            logger.error(f"Error processing {file_path}: {e}")
    
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
        
        # Send to Kafka
        try:
            future = self.producer.send(
                self.topic,
                key=image_hash.encode('utf-8'),
                value=json.dumps(message).encode('utf-8')
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
            logger.error(f"Failed to send {file_path.name} to Kafka: {e}")
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
    
    # Create watch directory if it doesn't exist
    watch_dir = Path(WATCH_PATH)
    watch_dir.mkdir(parents=True, exist_ok=True)
    
    logger.info(f"Starting Image Producer")
    logger.info(f"Kafka Servers: {KAFKA_BOOTSTRAP_SERVERS}")
    logger.info(f"Kafka Topic: {KAFKA_TOPIC}")
    logger.info(f"Watch Path: {watch_dir.absolute()}")
    
    # Initialize Kafka producer
    producer = KafkaProducer(
        bootstrap_servers=KAFKA_BOOTSTRAP_SERVERS.split(','),
        max_request_size=10485760,  # 10MB
        compression_type='gzip',
        acks='all',
        retries=3
    )
    
    # Setup file system observer
    event_handler = ImageHandler(producer, KAFKA_TOPIC, watch_dir)
    observer = Observer()
    observer.schedule(event_handler, str(watch_dir), recursive=False)
    observer.start()
    
    logger.info(f"👁️  Watching {watch_dir} for new images...")
    logger.info("Press Ctrl+C to stop")
    
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        logger.info("Stopping observer...")
        observer.stop()
        producer.close()
    
    observer.join()
    logger.info("Image Producer stopped")


if __name__ == '__main__':
    main()
