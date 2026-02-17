#!/bin/bash
# Data Platform Test Suite

CLUSTER_NAME="data-platform"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🧪 Testing Data Platform Components..."
echo "======================================"

# Function to check if a pod is ready
check_pods() {
    local namespace=$1
    local label=$2
    local name=$3
    
    echo -n "Checking $name... "
    if kubectl get pods -n $namespace -l $label 2>/dev/null | grep -q "Running"; then
        echo -e "${GREEN}✓ Running${NC}"
        return 0
    else
        echo -e "${RED}✗ Not Running${NC}"
        return 1
    fi
}

# 1. Check Cluster
echo ""
echo "1️⃣  Cluster Status"
echo "-------------------"
if kind get clusters | grep -q "$CLUSTER_NAME"; then
    echo -e "${GREEN}✓ Kind cluster '$CLUSTER_NAME' exists${NC}"
else
    echo -e "${RED}✗ Cluster not found${NC}"
    exit 1
fi

# 2. Check All Pods
echo ""
echo "2️⃣  Pod Health Check"
echo "-------------------"
check_pods "default" "app.kubernetes.io/name=postgresql" "PostgreSQL"
check_pods "default" "app=rustfs" "RustFS"
check_pods "default" "app=kafka" "Kafka"
check_pods "airflow" "component=scheduler" "Airflow Scheduler"
check_pods "airflow" "tier=airflow" "Airflow API Server"
check_pods "spark-operator" "app.kubernetes.io/name=spark-operator" "Spark Operator"
check_pods "default" "app=iceberg-rest" "Lakekeeper (Iceberg REST)"
# Check Doris (works with both manual and Helm installations)
if kubectl get pods -l app.kubernetes.io/component=fe 2>/dev/null | grep -q "Running"; then
    echo -n "Checking Apache Doris FE... "
    echo -e "${GREEN}✓ Running${NC}"
else
    check_pods "default" "app=doris-fe" "Apache Doris FE"
fi
if kubectl get pods -l app.kubernetes.io/component=be 2>/dev/null | grep -q "Running"; then
    echo -n "Checking Apache Doris BE... "
    echo -e "${GREEN}✓ Running${NC}"
else
    check_pods "default" "app=doris-be" "Apache Doris BE"
fi

# 3. Test PostgreSQL
echo ""
echo "3️⃣  PostgreSQL Connection Test"
echo "-----------------------------"
POSTGRES_POD=$(kubectl get pod -l app.kubernetes.io/name=postgresql -o jsonpath="{.items[0].metadata.name}")
POSTGRES_PASSWORD=$(kubectl get secret postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)

if kubectl exec $POSTGRES_POD -- env PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -c "SELECT version();" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ PostgreSQL connection successful${NC}"
    POSTGRES_VERSION=$(kubectl exec $POSTGRES_POD -- env PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -t -c "SELECT version();" | head -n1 | xargs)
    echo "  Version: $POSTGRES_VERSION"
    
    # Check PostGIS
    POSTGIS_VERSION=$(kubectl exec $POSTGRES_POD -- env PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -t -c "SELECT PostGIS_Version();" 2>/dev/null | xargs)
    if [ ! -z "$POSTGIS_VERSION" ]; then
        echo -e "  ${GREEN}✓ PostGIS enabled: $POSTGIS_VERSION${NC}"
        
        # Check PostGIS extensions
        EXTENSIONS=$(kubectl exec $POSTGRES_POD -- env PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -t -c "SELECT COUNT(*) FROM pg_extension WHERE extname LIKE 'postgis%';" 2>/dev/null | xargs)
        echo "  PostGIS extensions loaded: $EXTENSIONS"
    else
        echo -e "  ${YELLOW}⚠ PostGIS not enabled${NC}"
    fi
else
    echo -e "${RED}✗ PostgreSQL connection failed${NC}"
fi

# 4. Test RustFS
echo ""
echo "4️⃣  RustFS Object Storage Test"
echo "----------------------------"
RUSTFS_POD=$(kubectl get pod -l app=rustfs -o jsonpath="{.items[0].metadata.name}")
if kubectl exec $RUSTFS_POD -- curl -f http://localhost:9000/health > /dev/null 2>&1; then
    echo -e "${GREEN}✓ RustFS connection successful${NC}"
    echo "  API: rustfs.default.svc.cluster.local:9000"
    echo "  Console: Use 'kubectl port-forward svc/rustfs 9001:9001'"
else
    echo -e "${RED}✗ RustFS connection failed${NC}"
fi

# 5. Test Kafka
echo ""
echo "5️⃣  Kafka Message Broker Test"
echo "----------------------------"
KAFKA_POD=$(kubectl get pod -l app=kafka -o jsonpath="{.items[0].metadata.name}")
if kubectl exec $KAFKA_POD -- /opt/kafka/bin/kafka-topics.sh --list --bootstrap-server localhost:9092 > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Kafka connection successful${NC}"
    
    # Create test topic
    kubectl exec $KAFKA_POD -- /opt/kafka/bin/kafka-topics.sh --create --topic test-topic \
        --bootstrap-server localhost:9092 --if-not-exists --partitions 1 --replication-factor 1 > /dev/null 2>&1
    
    # List topics
    TOPIC_COUNT=$(kubectl exec $KAFKA_POD -- /opt/kafka/bin/kafka-topics.sh --list --bootstrap-server localhost:9092 2>/dev/null | wc -l)
    echo "  Total topics: $TOPIC_COUNT"
    
    # Test produce/consume
    echo "test-message-$(date +%s)" | kubectl exec -i $KAFKA_POD -- /opt/kafka/bin/kafka-console-producer.sh \
        --broker-list localhost:9092 --topic test-topic > /dev/null 2>&1
    
    MESSAGE=$(kubectl exec $KAFKA_POD -- /opt/kafka/bin/kafka-console-consumer.sh \
        --bootstrap-server localhost:9092 --topic test-topic --from-beginning --max-messages 1 --timeout-ms 5000 2>/dev/null)
    
    if [ ! -z "$MESSAGE" ]; then
        echo -e "${GREEN}✓ Message produce/consume successful${NC}"
    fi
else
    echo -e "${RED}✗ Kafka connection failed${NC}"
fi

# 6. Test Airflow
echo ""
echo "6️⃣  Airflow Orchestrator Test"
echo "----------------------------"
SCHEDULER_POD=$(kubectl get pod -n airflow -l component=scheduler -o jsonpath="{.items[0].metadata.name}")
if kubectl exec -n airflow $SCHEDULER_POD -- airflow version > /dev/null 2>&1; then
    AIRFLOW_VERSION=$(kubectl exec -n airflow $SCHEDULER_POD -- airflow version 2>/dev/null)
    echo -e "${GREEN}✓ Airflow is operational${NC}"
    echo "  Version: $AIRFLOW_VERSION"
    
    # List DAGs
    DAG_COUNT=$(kubectl exec -n airflow $SCHEDULER_POD -- airflow dags list 2>/dev/null | grep -v "dag_id" | grep -v "^$" | wc -l)
    echo "  Total DAGs: $DAG_COUNT"
else
    echo -e "${RED}✗ Airflow connection failed${NC}"
fi

# 7. Test Spark Operator
echo ""
echo "7️⃣  Spark Operator Test"
echo "----------------------"
if kubectl get crd sparkapplications.sparkoperator.k8s.io > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Spark Operator CRDs installed${NC}"
    SPARK_APP_COUNT=$(kubectl get sparkapplications --all-namespaces 2>/dev/null | grep -v "NAME" | wc -l)
    echo "  Running Spark applications: $SPARK_APP_COUNT"
else
    echo -e "${RED}✗ Spark Operator CRDs not found${NC}"
fi

# 8. Test Lakekeeper
echo ""
echo "8️⃣  Lakekeeper REST Catalog Test"
echo "-----------------------------------"
LAKEKEEPER_POD=$(kubectl get pod -l app=iceberg-rest -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
if [ ! -z "$LAKEKEEPER_POD" ]; then
    # Lakekeeper image is minimal (no shell/curl), so probe it from a dedicated curl pod.
    PROBE_POD="lakekeeper-probe-$(date +%s)"
    if kubectl run --rm -i --restart=Never "$PROBE_POD" --image=curlimages/curl:8.6.0 \
        --command -- curl -fsS "http://iceberg-rest.default.svc.cluster.local:8181/health" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Lakekeeper is operational${NC}"
        echo "  Health: http://iceberg-rest.default.svc.cluster.local:8181/health"
        echo "  REST base: http://iceberg-rest.default.svc.cluster.local:8181"
    else
        echo -e "${RED}✗ Lakekeeper health check failed${NC}"
        echo "  Hint: run: kubectl logs deploy/iceberg-rest --tail=100"
    fi
else
    echo -e "${RED}✗ Lakekeeper pod not found${NC}"
fi

# 10. Service URLs
echo ""
echo "🔗 Access Information"
echo "--------------------"
echo "To access services, run these port-forward commands:"
echo ""
echo -e "${YELLOW}Airflow UI:${NC}"
echo "  kubectl port-forward svc/airflow-api-server 8080:8080 -n airflow"
echo "  → http://localhost:8080 (admin/admin)"
echo ""
echo -e "${YELLOW}RustFS Console:${NC}"
echo "  kubectl port-forward svc/rustfs 9001:9001"
echo "  → http://localhost:9001 (admin/minio_password)"
echo ""
echo -e "${YELLOW}PostgreSQL:${NC}"
echo "  kubectl port-forward svc/postgres-postgresql 5432:5432"
echo "  → localhost:5432 (postgres/<get-secret>)"
echo ""
echo -e "${YELLOW}Apache Doris:${NC}"
echo "  kubectl port-forward svc/doris-fe 9030:9030 8030:8030"
echo "  → MySQL: localhost:9030 (user: root, no password)"
echo "  → Web UI: http://localhost:8030"
echo ""
echo -e "${YELLOW}Lakekeeper (Iceberg REST):${NC}"
echo "  kubectl port-forward svc/iceberg-rest 8181:8181"
echo "  → http://localhost:8181/health"
echo ""

# 9. Summary
echo ""
echo "✅ Test Suite Complete!"
echo "======================"
echo ""
echo "Next steps:"
echo "1. Deploy your DAGs: kubectl cp dags/spark_orchestrator_dag.py airflow/$SCHEDULER_POD:/opt/airflow/dags/"
echo "2. Submit Spark jobs: kubectl apply -f manifests/sedona_job.yaml"
echo "3. Monitor with: kubectl get pods --all-namespaces -w"
