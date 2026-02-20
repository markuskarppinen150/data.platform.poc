#!/bin/bash
# Quick setup script for running the image pipeline locally

echo "🔧 Setting up port forwards..."

# Kill any existing port-forwards
pkill -f "port-forward.*kafka" 2>/dev/null || true
pkill -f "port-forward.*seaweedfs" 2>/dev/null || true
pkill -f "port-forward.*airflow" 2>/dev/null || true
pkill -f "port-forward.*postgres" 2>/dev/null || true
pkill -f "port-forward.*flink" 2>/dev/null || true

# Port forward Kafka
echo "📬 Port forwarding Kafka..."
kubectl port-forward svc/kafka 9092:9092 > /dev/null 2>&1 &
sleep 2

# Port forward SeaweedFS (S3 gateway + Filer UI + Master)
echo "💾 Port forwarding SeaweedFS..."
kubectl port-forward svc/seaweedfs-s3 9000:8333 > /dev/null 2>&1 &
kubectl port-forward svc/seaweedfs-filer 9001:8888 > /dev/null 2>&1 &
kubectl port-forward svc/seaweedfs-master 9333:9333 > /dev/null 2>&1 &
# SeaweedFS volume server runs on port 8080 inside the pod; map it to 8082 locally to avoid clashing with Airflow (8080)
kubectl port-forward deploy/seaweedfs 8082:8080 > /dev/null 2>&1 &
sleep 2

# Port forward Airflow (API Server / UI)
echo "🌬️  Port forwarding Airflow UI..."
kubectl port-forward -n airflow svc/airflow-api-server 8080:8080 > /dev/null 2>&1 &
sleep 2

# Port forward PostgreSQL
echo "🗄️  Port forwarding PostgreSQL..."
kubectl port-forward svc/postgres-postgresql 5432:5432 > /dev/null 2>&1 &
sleep 2

# Port forward Flink (JobManager UI)
echo "🐿️  Port forwarding Flink JobManager UI..."
kubectl port-forward -n flink svc/flink-jobmanager 8081:8081 > /dev/null 2>&1 &
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
echo "  SeaweedFS S3 API:   localhost:9000"
echo "  SeaweedFS Filer UI: localhost:9001"
echo "  SeaweedFS Master:   localhost:9333"
echo "  SeaweedFS Volume:   localhost:8082"
echo "  Airflow UI:  localhost:8080"
echo "  PostgreSQL: localhost:5432"
echo "  Flink UI:   localhost:8081"
echo ""
echo "To stop port forwards: pkill -f 'port-forward'"
