#!/usr/bin/env python3
import logging
import os
from datetime import datetime, timezone

from quixstreams import Application


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

    logger.info("Starting Quix Streams service")
    logger.info("Kafka broker: %s", broker)
    logger.info("Input topic: %s", input_topic_name)
    logger.info("Output topic: %s", output_topic_name)
    logger.info("Consumer group: %s", consumer_group)

    app = Application(
        broker_address=broker,
        consumer_group=consumer_group,
    )

    input_topic = app.topic(input_topic_name, value_deserializer="json")
    output_topic = app.topic(output_topic_name, value_serializer="json")

    sdf = app.dataframe(topic=input_topic)
    sdf = sdf.apply(_transform)
    sdf = sdf.to_topic(output_topic)

    # Run the application (it automatically tracks the dataframe pipeline)
    app.run()


if __name__ == "__main__":
    main()
