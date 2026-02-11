#!/bin/bash
# Quick setup script for running the image pipeline locally

echo "🔧 Setting up port forwards..."

# Kill any existing port-forwards
pkill -f "port-forward.*kafka" 2>/dev/null || true
pkill -f "port-forward.*minio" 2>/dev/null || true
pkill -f "port-forward.*postgres" 2>/dev/null || true

# Port forward Kafka
echo "📬 Port forwarding Kafka..."
kubectl port-forward svc/kafka 9092:9092 > /dev/null 2>&1 &
sleep 2

# Port forward MinIO
echo "💾 Port forwarding MinIO..."
kubectl port-forward svc/minio 9000:9000 9001:9001 > /dev/null 2>&1 &
sleep 2

# Port forward PostgreSQL
echo "🗄️  Port forwarding PostgreSQL..."
kubectl port-forward svc/postgres-postgresql 5432:5432 > /dev/null 2>&1 &
sleep 2

# Get PostgreSQL password
export POSTGRES_PASSWORD=$(kubectl get secret postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)

# Create Kafka topic
echo "📋 Creating Kafka topic..."
kubectl exec kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
    --create --if-not-exists \
    --topic image-uploads \
    --bootstrap-server localhost:9092 \
    --partitions 3 \
    --replication-factor 1 2>/dev/null || echo "Topic may already exist"

echo ""
echo "✅ Setup complete!"
echo ""
echo "Environment variables set:"
echo "  POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
echo ""
echo "Services available at:"
echo "  Kafka:      localhost:9092"
echo "  MinIO API:  localhost:9000"
echo "  MinIO UI:   localhost:9001"
echo "  PostgreSQL: localhost:5432"
echo ""
echo "To stop port forwards: pkill -f 'port-forward'"
