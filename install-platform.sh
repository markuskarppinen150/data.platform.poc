#!/bin/bash
# Local Data Platform Bootstrapper (Ubuntu)

CLUSTER_NAME="data-platform"

echo "🚀 Creating 3-node Kind cluster..."
cat <<EOF | kind create cluster --name $CLUSTER_NAME --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
EOF

echo "📦 Adding Helm Repositories..."
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add apache-airflow https://airflow.apache.org
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm repo update

echo "💾 1. Installing PostgreSQL with PostGIS (Metadata Layer)..."
kubectl apply -f manifests/deployments/postgres-postgis.yaml

echo "⏳ Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod -l app=postgresql --timeout=300s

echo "☁️ 2. Installing MinIO (S3-compatible Object Storage)..."
kubectl apply -f manifests/deployments/minio-deployment.yaml

echo "⏳ Waiting for MinIO to be ready..."
kubectl wait --for=condition=ready pod -l app=minio --timeout=300s

echo "🎢 3. Installing Apache Kafka (Message Broker)..."
kubectl apply -f manifests/deployments/kafka-deployment.yaml

echo "⏳ Waiting for Kafka to be ready..."
kubectl wait --for=condition=ready pod -l app=kafka --timeout=300s

echo "🌬️ 4. Installing Apache Airflow (Orchestrator)..."
# Get PostgreSQL connection details
POSTGRES_PASSWORD=$(kubectl get secret postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)

helm install airflow apache-airflow/airflow \
  --namespace airflow --create-namespace \
  --set executor=LocalExecutor \
  --set postgresql.enabled=false \
  --set data.metadataConnection.user=postgres \
  --set data.metadataConnection.pass=$POSTGRES_PASSWORD \
  --set data.metadataConnection.host=postgres-postgresql.default.svc.cluster.local \
  --set data.metadataConnection.port=5432 \
  --set data.metadataConnection.db=postgres \
  --set webserver.defaultUser.enabled=true \
  --set webserver.defaultUser.username=admin \
  --set webserver.defaultUser.password=admin \
  --set webserver.replicas=1 \
  --set scheduler.replicas=1 \
  --set workers.replicas=0 \
  --set redis.enabled=false \
  --set statsd.enabled=false \
  --set pgbouncer.enabled=false \
  --set flower.enabled=false \
  --set triggerer.enabled=false \
  --set dags.gitSync.enabled=false \
  --set webserver.resources.requests.cpu=100m \
  --set webserver.resources.requests.memory=256Mi \
  --set webserver.resources.limits.cpu=500m \
  --set webserver.resources.limits.memory=512Mi \
  --set scheduler.resources.requests.cpu=100m \
  --set scheduler.resources.requests.memory=256Mi \
  --set scheduler.resources.limits.cpu=500m \
  --set scheduler.resources.limits.memory=512Mi \
  --timeout 10m

echo "⏳ Waiting for Airflow pods to be created..."
sleep 30
echo "📋 Checking Airflow pods status:"
kubectl get pods -n airflow

echo "⏳ Waiting for Airflow to be ready..."
kubectl wait --for=condition=ready pod -l component=scheduler --namespace airflow --timeout=600s

echo "✨ 5. Installing Spark Operator (for Sedona processing)..."
for i in {1..3}; do
  if helm install spark-operator spark-operator/spark-operator \
    --namespace spark-operator --create-namespace \
    --timeout 5m; then
    break
  else
    echo "⚠️ Spark Operator installation attempt $i failed, retrying..."
    sleep 5
  fi
done

echo "🏔️ 6. Installing Trino + Hive Metastore (Iceberg)..."
# Initialize Hive Metastore schema
kubectl apply -f manifests/deployments/hive-schema-init.yaml
echo "⏳ Waiting for schema initialization..."
kubectl wait --for=condition=complete --timeout=120s job/hive-schema-init || echo "Schema init pending..."

# Deploy Trino with Iceberg + Hive Metastore
kubectl apply -f manifests/deployments/trino-iceberg.yaml

echo "⏳ Waiting for Trino and Hive Metastore..."
kubectl wait --for=condition=available deployment/trino --timeout=300s || echo "Trino deployment pending..."
kubectl wait --for=condition=available deployment/hive-metastore --timeout=300s || echo "Hive Metastore pending..."

echo "✅ Deployment complete! Waiting for pods to initialize..."
