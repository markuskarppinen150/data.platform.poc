#!/bin/bash
# Local Data Platform Bootstrapper (Ubuntu)

CLUSTER_NAME="data-platform"

# Check kernel parameters required for Doris
echo "🔍 Checking kernel parameters..."
REQUIRED_INOTIFY_INSTANCES=512
REQUIRED_INOTIFY_WATCHES=524288
REQUIRED_MAX_MAP_COUNT=2000000

CURRENT_INSTANCES=$(sysctl -n fs.inotify.max_user_instances)
CURRENT_WATCHES=$(sysctl -n fs.inotify.max_user_watches)
CURRENT_MAP_COUNT=$(sysctl -n vm.max_map_count)

NEEDS_FIX=false

if [ "$CURRENT_INSTANCES" -lt "$REQUIRED_INOTIFY_INSTANCES" ]; then
  echo "⚠️  fs.inotify.max_user_instances is $CURRENT_INSTANCES (need $REQUIRED_INOTIFY_INSTANCES)"
  NEEDS_FIX=true
fi

if [ "$CURRENT_WATCHES" -lt "$REQUIRED_INOTIFY_WATCHES" ]; then

  echo "⚠️  fs.inotify.max_user_watches is $CURRENT_WATCHES (need $REQUIRED_INOTIFY_WATCHES)"
  NEEDS_FIX=true
fi

if [ "$CURRENT_MAP_COUNT" -lt "$REQUIRED_MAX_MAP_COUNT" ]; then
  echo "⚠️  vm.max_map_count is $CURRENT_MAP_COUNT (need $REQUIRED_MAX_MAP_COUNT)"
  NEEDS_FIX=true
fi

if [ "$NEEDS_FIX" = true ]; then
  echo ""
  echo "❌ Kernel parameters need adjustment. Run these commands:"
  echo ""
  echo "  sudo sysctl -w fs.inotify.max_user_instances=$REQUIRED_INOTIFY_INSTANCES"
  echo "  sudo sysctl -w fs.inotify.max_user_watches=$REQUIRED_INOTIFY_WATCHES"
  echo "  sudo sysctl -w vm.max_map_count=$REQUIRED_MAX_MAP_COUNT"
  echo ""
  echo "To make them persistent across reboots:"
  echo ""
  echo "  sudo tee /etc/sysctl.d/99-data-platform.conf >/dev/null <<'EOF'"
  echo "fs.inotify.max_user_instances=$REQUIRED_INOTIFY_INSTANCES"
  echo "fs.inotify.max_user_watches=$REQUIRED_INOTIFY_WATCHES"
  echo "vm.max_map_count=$REQUIRED_MAX_MAP_COUNT"
  echo "EOF"
  echo "  sudo sysctl --system"
  echo ""
  exit 1
fi

echo "✅ Kernel parameters are properly configured"

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

echo "☁️ 2. Installing SeaweedFS (S3-compatible Object Storage)..."
kubectl apply -f manifests/deployments/seaweedfs-deployment.yaml

echo "⏳ Waiting for SeaweedFS to be ready..."
kubectl wait --for=condition=ready pod -l app=seaweedfs --timeout=300s

echo "🎢 3. Installing Apache Kafka (Message Broker)..."
kubectl apply -f manifests/deployments/kafka-deployment.yaml

echo "⏳ Waiting for Kafka to be ready..."
kubectl wait --for=condition=ready pod -l app=kafka --timeout=300s

echo "🌬️ 4. Installing Apache Airflow (Orchestrator)..."
# Get PostgreSQL connection details
POSTGRES_PASSWORD=$(kubectl get secret postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)

# Create namespace + DAG ConfigMap up-front so the Helm release can mount it on first install
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -
echo "📄 Creating/Updating Airflow DAG ConfigMap..."
kubectl create configmap airflow-dags --from-file=dags/ -n airflow --dry-run=client -o yaml | kubectl apply -f -

echo "🔧 Preparing Airflow Helm values..."
cat > /tmp/airflow-values.yaml <<AIRFLOW_CONFIG
executor: LocalExecutor

postgresql:
  enabled: false

data:
  metadataConnection:
    user: postgres
    pass: "${POSTGRES_PASSWORD}"
    host: postgres-postgresql.default.svc.cluster.local
    port: 5432
    db: postgres

webserver:
  defaultUser:
    enabled: true
    role: Admin
    username: admin
    password: admin
    email: admin@example.com
    firstName: admin
    lastName: user
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

scheduler:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi
  extraInitContainers:
    - name: copy-dags
      image: busybox:latest
      command:
        - sh
        - -c
        - |
          mkdir -p /opt/airflow/dags
          cp /dags-source/* /opt/airflow/dags/ 2>/dev/null || true
          ls -la /opt/airflow/dags/
      volumeMounts:
        - name: dags-source
          mountPath: /dags-source
        - name: dags
          mountPath: /opt/airflow/dags
  extraVolumes:
    - name: dags-source
      configMap:
        name: airflow-dags
    - name: dags
      emptyDir: {}
  extraVolumeMounts:
    - name: dags
      mountPath: /opt/airflow/dags

dagProcessor:
  extraInitContainers:
    - name: copy-dags
      image: busybox:latest
      command:
        - sh
        - -c
        - |
          mkdir -p /opt/airflow/dags
          cp /dags-source/* /opt/airflow/dags/ 2>/dev/null || true
          ls -la /opt/airflow/dags/
      volumeMounts:
        - name: dags-source
          mountPath: /dags-source
        - name: dags
          mountPath: /opt/airflow/dags
  extraVolumes:
    - name: dags-source
      configMap:
        name: airflow-dags
    - name: dags
      emptyDir: {}
  extraVolumeMounts:
    - name: dags
      mountPath: /opt/airflow/dags

workers:
  replicas: 0

redis:
  enabled: false
statsd:
  enabled: false
pgbouncer:
  enabled: false
flower:
  enabled: false
triggerer:
  enabled: false

dags:
  gitSync:
    enabled: false

# Required for external PostgreSQL metadata DB (driver is not guaranteed in the base image)
extraPipPackages:
  - psycopg2-binary==2.9.9
  - apache-airflow-providers-postgres==5.13.0
  - kafka-python-ng==2.2.2
  - minio==7.2.9
  - Pillow==11.0.0
AIRFLOW_CONFIG

echo "🚢 Installing/Upgrading Airflow via Helm..."
if ! helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  -f /tmp/airflow-values.yaml \
  --timeout 15m; then
  echo ""
  echo "❌ Airflow Helm install/upgrade failed. Dumping diagnostics for hook jobs..."
  echo ""
  kubectl get pods -n airflow || true
  kubectl get jobs -n airflow || true

  echo ""
  echo "--- airflow-create-user job ---"
  kubectl describe job airflow-create-user -n airflow 2>/dev/null || true
  kubectl logs -n airflow -l job-name=airflow-create-user --all-containers --tail=200 2>/dev/null || true

  echo ""
  echo "--- airflow-migrate-database job ---"
  kubectl describe job airflow-migrate-database -n airflow 2>/dev/null || true
  kubectl logs -n airflow -l job-name=airflow-migrate-database --all-containers --tail=200 2>/dev/null || true

  echo ""
  echo "--- airflow namespace events (last 50) ---"
  kubectl get events -n airflow --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -n 50 || true
  exit 1
fi

echo "⏳ Waiting for Airflow to be ready..."
kubectl wait --for=condition=ready pod -l component=scheduler --namespace airflow --timeout=600s

echo "✅ Airflow installed and DAGs configured successfully!"

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

echo "🧊 6. Installing Iceberg REST Catalog (Lakekeeper)..."
# Create the lakekeeper-config secret with PostgreSQL connection URL
kubectl create secret generic lakekeeper-config \
  --from-literal=database-url="postgresql://postgres:${POSTGRES_PASSWORD}@postgres-postgresql.default.svc.cluster.local:5432/iceberg_catalog"

kubectl apply -f manifests/deployments/iceberg-rest-catalog.yaml

echo "⏳ Waiting for Iceberg REST catalog to be ready..."
kubectl wait --for=condition=ready pod -l app=iceberg-rest --timeout=300s

echo "✅ Iceberg REST catalog is ready!"

echo "🏔️ 7. Installing Apache Doris (SQL Query Engine)..."
kubectl apply -f manifests/deployments/doris.yaml

echo "⏳ Waiting for Apache Doris FE to be ready..."
kubectl wait --for=condition=ready pod -l app=doris-fe --timeout=300s

echo "⏳ Waiting for Apache Doris BE to be ready..."
kubectl wait --for=condition=ready pod -l app=doris-be --timeout=300s

echo "✅ Apache Doris is ready!"

echo "✅ Deployment complete! Waiting for pods to initialize..."
