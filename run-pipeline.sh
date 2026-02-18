#!/bin/bash
# Run the image processing pipeline locally (for testing)

set -e

echo "🔧 Setting up image processing pipeline..."

# Create necessary directories
mkdir -p images/incoming

# Get PostgreSQL password
echo "📝 Getting PostgreSQL password..."
POSTGRES_PASSWORD=$(kubectl get secret postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)

# Port forward services
echo "🌐 Setting up port forwards..."

# Kill any existing port-forwards
pkill -f "kubectl port-forward" || true

# Start port forwards in background
kubectl port-forward svc/kafka 9092:9092 &
KAFKA_PF_PID=$!

kubectl port-forward svc/seaweedfs-s3 9000:8333 &
SEAWEEDFS_S3_PF_PID=$!

kubectl port-forward svc/seaweedfs-filer 9001:8888 &
SEAWEEDFS_FILER_PF_PID=$!

kubectl port-forward svc/postgres-postgresql 5432:5432 &
POSTGRES_PF_PID=$!

# Wait for port forwards to establish
sleep 5

echo "✅ Port forwards established"
echo "   Kafka: localhost:9092"
echo "   SeaweedFS S3: localhost:9000"
echo "   SeaweedFS Filer UI: localhost:9001"
echo "   PostgreSQL: localhost:5432"
echo ""

# Create Kafka topic
echo "📬 Creating Kafka topic..."
kubectl exec -it kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
    --create --if-not-exists \
    --topic image-uploads \
    --bootstrap-server localhost:9092 \
    --partitions 3 \
    --replication-factor 1

echo ""
echo "🚀 Starting pipeline components..."

# Create log directory
mkdir -p logs

# Start Consumer
echo "📥 Starting Image Consumer..."
export POSTGRES_PASSWORD
source .venv/bin/activate
.venv/bin/python manifests/streaming/image_consumer.py > logs/consumer.log 2>&1 &
CONSUMER_PID=$!
echo "   Consumer PID: $CONSUMER_PID (logs: logs/consumer.log)"

# Wait a bit for consumer to initialize
sleep 3

# Start Producer
echo "📤 Starting Image Producer..."
.venv/bin/python manifests/streaming/image_producer.py > logs/producer.log 2>&1 &
PRODUCER_PID=$!
echo "   Producer PID: $PRODUCER_PID (logs: logs/producer.log)"

echo ""
echo "✅ Pipeline is running!"
echo ""
echo "📊 Monitor logs:"
echo "   Consumer: tail -f logs/consumer.log"
echo "   Producer: tail -f logs/producer.log"
echo ""
echo "📸 Add test images:"
echo "   cp ~/Pictures/your-image.jpg images/incoming/"
echo ""
echo "🔍 Check S3 storage:"
echo "   SeaweedFS Filer UI: http://localhost:9001"
echo ""
echo "🗄️  Check database:"
echo "   kubectl port-forward svc/postgres-postgresql 5432:5432"
echo "   psql -h localhost -U postgres -d postgres"
echo "   SELECT * FROM image_metadata;"
echo ""
echo "Press Ctrl+C to stop everything..."

# Trap to cleanup on exit
cleanup() {
    echo ""
    echo "🧹 Cleaning up..."
    kill $CONSUMER_PID $PRODUCER_PID 2>/dev/null || true
    kill $KAFKA_PF_PID $SEAWEEDFS_S3_PF_PID $SEAWEEDFS_FILER_PF_PID $POSTGRES_PF_PID 2>/dev/null || true
    pkill -f "kubectl port-forward" || true
    pkill -f "image_consumer.py" || true
    pkill -f "image_producer.py" || true
    echo "✅ Cleanup complete"
}

trap cleanup EXIT INT TERM

# Monitor processes
while true; do
    # Check if consumer is still running
    if ! kill -0 $CONSUMER_PID 2>/dev/null; then
        echo "⚠️  Consumer stopped! Check logs/consumer.log"
        tail -20 logs/consumer.log
        break
    fi
    
    # Check if producer is still running
    if ! kill -0 $PRODUCER_PID 2>/dev/null; then
        echo "⚠️  Producer stopped! Check logs/producer.log"
        tail -20 logs/producer.log
        break
    fi
    
    sleep 2
done
