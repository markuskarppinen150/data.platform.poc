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

echo "☁️ 2. Installing RustFS (S3-compatible Object Storage)..."
kubectl apply -f manifests/deployments/rustfs-deployment.yaml

echo "⏳ Waiting for RustFS to be ready..."
kubectl wait --for=condition=ready pod -l app=rustfs --timeout=300s

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

echo "📄 Creating Airflow DAG ConfigMap..."
kubectl create configmap airflow-dags --from-file=dags/ -n airflow

echo "🔄 Configuring Airflow to load DAGs..."
# Create Helm values file for DAG mounting
cat > /tmp/airflow-dag-config.yaml <<AIRFLOW_CONFIG
extraPipPackages:
  - apache-airflow-providers-postgres==5.13.0
  - confluent-kafka==2.6.0
  - Pillow==11.0.0

scheduler:
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
AIRFLOW_CONFIG

echo "🔄 Upgrading Airflow with DAG configuration..."
helm upgrade airflow apache-airflow/airflow \
  --namespace airflow \
  -f /tmp/airflow-dag-config.yaml \
  --reuse-values \
  --timeout 10m

echo "⏳ Waiting for Airflow scheduler to restart with DAGs..."
kubectl rollout status statefulset airflow-scheduler -n airflow --timeout=300s

echo "✅ Airflow DAGs configured successfully!"

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
