# Local Data Platform - Setup Guide

A complete local data platform with PostgreSQL, SeaweedFS (S3), Kafka, Airflow, Flink, Spark Operator, Lakekeeper (Iceberg REST), and Apache Doris running on Kubernetes (Kind).

This is strictly a sandbox for testing different kinds of setups and workflows with different data.

## 🎯 Overview

This platform includes:
- **PostgreSQL + PostGIS** - Relational database with geospatial capabilities
- **SeaweedFS** - S3-compatible object storage
- **Kafka** - Message broker for streaming
- **Apache Flink** - Stream processing engine
- **Apache Iceberg** - Table format for data lakes
- **Lakekeeper** - REST catalog for Iceberg
- **Apache Doris** - MPP analytical database
- **Airflow** - Workflow orchestration
- **Spark Operator** - Big data processing
- **Image Pipeline** - Automated image ingestion system

---

## 📋 Prerequisites

### Required Software

1. **Docker** - Container runtime
   ```bash
   # Check if installed
   docker --version
   
   # Install on Ubuntu
   sudo apt update
   sudo apt install docker.io
   sudo usermod -aG docker $USER
   # Log out and back in
   ```

2. **Kind** - Kubernetes in Docker
   ```bash
   # Install Kind
   # For AMD64 / x86_64
   [ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
   # For ARM64
   [ $(uname -m) = aarch64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-arm64
   chmod +x ./kind
   sudo mv ./kind /usr/local/bin/kind
   
   # Verify
   kind version
   ```

   Note (Linux): this repo pins Kubernetes 1.35.x for kind, which expects a cgroup v2 host.

3. **kubectl** - Kubernetes CLI
   ```bash
   # Install kubectl
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   chmod +x kubectl
   sudo mv kubectl /usr/local/bin/
   
   # Verify
   kubectl version --client
   ```

4. **Helm** - Kubernetes package manager
   ```bash
   # Install Helm
   curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
   
   # Verify
   helm version
   ```

5. **Python 3.12+** - For pipeline scripts
   ```bash
   python3 --version
   ```

---

## 🚀 Quick Start (5 Steps)

### Step 1: Install the Platform

```bash
# Clone or navigate to the project directory
cd ~/Documents/data-platform

# Run the installation script
./install-platform.sh
```

Note: `./install-platform.sh` validates a few Linux kernel `sysctl` settings (inotify + `vm.max_map_count`) needed for Apache Doris. If they’re not set, it exits and prints the exact commands to apply.

**What this does:**
- Creates a Kind cluster (1 control-plane + 3 workers) pinned to Kubernetes 1.35.1
- Installs PostgreSQL with PostGIS (geospatial database)
- Installs SeaweedFS (object storage)
- Installs Kafka (message broker)
- Installs Airflow via Helm (and loads DAGs from `dags/`)
- Installs Apache Flink (standalone manifests)
- Installs Spark Operator via Helm
- Installs Lakekeeper (Iceberg REST catalog)
- Installs Apache Doris (query engine)

**Duration:** ~5-10 minutes

**Expected output:**
```
✅ Deployment complete! Waiting for pods to initialize...
```

---

### Step 2: Test the Platform

```bash
# Run the test suite
./test-platform.sh
```

**What this checks:**
- ✓ Cluster is running
- ✓ All pods are healthy
- ✓ PostgreSQL connection + PostGIS extension
- ✓ Lakekeeper REST catalog
- ✓ Apache Doris query engine
- ✓ SeaweedFS storage access
- ✓ Kafka broker connectivity
- ✓ Apache Flink is running
- ✓ Airflow is operational
- ✓ Spark Operator CRDs

**Expected output:**
```
✅ Test Suite Complete!
```

---

### Step 3: Setup Python Environment

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

---

### Step 4: Run the Image Pipeline (Choose A or B)

#### Option A: Run Locally (with port-forwarding)

```bash
# Terminal 1: Setup port forwards and services
./setup-portforward.sh

# (Alternative) One-shot helper that does port-forwards + starts producer/consumer
# and writes logs to logs/consumer.log and logs/producer.log:
# ./run-pipeline.sh

# Terminal 2: Start the pipeline
source .venv/bin/activate
# `setup-portforward.sh` already exports POSTGRES_PASSWORD.
# If you didn't run it, you can set it manually:
# export POSTGRES_PASSWORD=$(kubectl get secret postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)

# Start consumer
python manifests/streaming/image-service/image_consumer.py &

# Start producer
python manifests/streaming/image-service/image_producer.py &

# Terminal 3: Add test images
cp ~/Pictures/test-image.jpg images/incoming/
```

#### Option B: Run in Kubernetes (recommended)

```bash
# Deploy streaming pipeline to cluster
./deploy-streaming.sh

# Upload test image
PRODUCER_POD=$(kubectl get pod -n airflow -l app=image-producer -o jsonpath='{.items[0].metadata.name}')
kubectl cp -n airflow ~/Pictures/test-image.jpg $PRODUCER_POD:/data/incoming/

# Monitor logs
kubectl logs -n airflow -l app=image-consumer -f
```

---

## 🧠 Quix Streams Processor Service (Kafka → Kafka)

This repo also includes a simple Quix Streams-based processor that runs as a Kubernetes pod and reads from one Kafka topic and writes to another.

**What it does (default):**
- Consumes JSON messages from `image-uploads`
- Emits a smaller "processed" JSON payload to `image-uploads-processed`

**Optional sinks (enabled by default):**
- **PostgreSQL**: inserts into `public.image_uploads_processed` (idempotent on `file_hash`)
- **Iceberg (Lakekeeper REST catalog)**: appends to `default.image_uploads_processed` in Lakekeeper warehouse `seaweedfs` (tables under `s3://iceberg/warehouse`)

### Deploy to Kind

```bash
./deploy-quix-streams-service.sh
```

### Watch logs

```bash
kubectl logs -n airflow -l app=quix-streams-service -f
```

### Customize topics / group

Edit the ConfigMap in [manifests/streaming/quix-streams-service/quix-streams-service.yaml](manifests/streaming/quix-streams-service/quix-streams-service.yaml).

To disable sinks, set:
- `ENABLE_POSTGRES_SINK=false`
- `ENABLE_ICEBERG_SINK=false`

---

### Step 5: Access Services

#### Airflow UI
```bash
kubectl port-forward svc/airflow-api-server 8080:8080 -n airflow
```
- URL: http://localhost:8080
- Username: `admin`
- Password: `admin`

#### SeaweedFS
```bash
kubectl port-forward svc/seaweedfs-s3 9000:8333
kubectl port-forward svc/seaweedfs-filer 9001:8888
```
- S3 API: http://localhost:9000 (admin/seaweedfs_password)
- Filer UI: http://localhost:9001

#### PostgreSQL Database
```bash
kubectl port-forward svc/postgres-postgresql 5432:5432

# Get password
PGPASSWORD=$(kubectl get secret postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)

# Connect
psql -h localhost -U postgres -d postgres

# Check image metadata
SELECT * FROM image_metadata;

# Test PostGIS
SELECT PostGIS_Version();

# Create spatial query
SELECT 
    filename,
    ST_AsText(ST_MakePoint(-74.0060, 40.7128)) as location
FROM image_metadata
LIMIT 5;
```

#### Flink UI
```bash
kubectl port-forward -n flink svc/flink-jobmanager 8081:8081
```
- URL: http://localhost:8081

**Example PostGIS queries:** See [queries/postgis-examples.sql](queries/postgis-examples.sql)

#### Apache Doris Query Engine
```bash
kubectl port-forward svc/doris-fe 9030:9030 8030:8030
```
- MySQL Protocol: localhost:9030
- Web UI: http://localhost:8030
- Username: `root` (no password by default)

**Example Doris queries:**
```bash
# Connect via MySQL client
mysql -h 127.0.0.1 -P 9030 -u root

# Show databases
SHOW DATABASES;

# Query Iceberg tables (via Iceberg catalog)
SHOW CATALOGS;
```

#### Lakekeeper REST Catalog
```bash
kubectl port-forward svc/iceberg-rest 8181:8181
```
- Health check: http://localhost:8181/health
- REST API endpoint for Iceberg clients

---

## 📸 Image Pipeline Workflow

### How It Works

1. **Watch Folder** → Producer monitors `images/incoming/`
2. **Kafka** → Images sent as base64-encoded messages
3. **Consumer** → Reads from Kafka, processes images
4. **SeaweedFS (S3)** → Stores images in S3 bucket (date-partitioned)
5. **PostgreSQL** → Records metadata (filename, hash, size, S3 path)

### Architecture

- **Python Scripts**: Located in `manifests/streaming/image-service/`
- **ConfigMap Generation**: Scripts loaded dynamically via `deploy-streaming.sh`
- **No Code Duplication**: Single source of truth for Python code
- **Easy Updates**: Edit `.py` files, run `./deploy-streaming.sh` to redeploy

### Test the Pipeline

```bash
# Create incoming directory
mkdir -p images/incoming

# Copy a test image
cp ~/Pictures/vacation.jpg images/incoming/

# Watch the logs
tail -f logs/consumer.log
tail -f logs/producer.log
```

### Verify Results

**Check S3 Storage:**
```bash
# SeaweedFS exposes an S3 gateway (no built-in S3 web console).
# You can browse the Filer UI and/or use an S3 client (e.g., AWS CLI).
kubectl port-forward svc/seaweedfs-s3 9000:8333 &
kubectl port-forward svc/seaweedfs-filer 9001:8888 &

# List objects via AWS CLI:
aws --endpoint-url http://localhost:9000 s3 ls s3://images --recursive
```

**Check Database:**
```bash
kubectl exec postgres-postgresql-0 -- \
  env PGPASSWORD=$(kubectl get secret postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d) \
  psql -U postgres -c "SELECT filename, file_size, s3_path, uploaded_at FROM image_metadata ORDER BY uploaded_at DESC LIMIT 10;"
```

**Using AWS CLI:**
```bash
# List objects
kubectl port-forward svc/seaweedfs-s3 9000:8333 &
aws --endpoint-url http://localhost:9000 s3 ls s3://images --recursive
```

---

## 📊 Monitoring & Debugging

### Check Pod Status
```bash
# All pods
kubectl get pods --all-namespaces

# Specific components
kubectl get pods -l app=seaweedfs
kubectl get pods -l app=kafka
kubectl get pods -n airflow
```

### View Logs
```bash
# Kafka
kubectl logs kafka-0

# SeaweedFS
kubectl logs -l app=seaweedfs

# Airflow Scheduler
kubectl logs -n airflow -l component=scheduler

# Image Pipeline
kubectl logs -n airflow -l app=image-consumer -f
kubectl logs -n airflow -l app=image-producer -f
```

### Test Kafka Connection
```bash
# Create test topic
kubectl exec kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --create --topic test \
  --bootstrap-server localhost:9092 \
  --partitions 1 --replication-factor 1

# List topics
kubectl exec kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --list --bootstrap-server localhost:9092

# Produce message
echo "test message" | kubectl exec -i kafka-0 -- \
  /opt/kafka/bin/kafka-console-producer.sh \
  --broker-list localhost:9092 --topic test

# Consume message
kubectl exec kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic test --from-beginning --max-messages 1
```

### Common Issues

#### Kafka Connection Issues
```bash
# Check Kafka advertised listeners
kubectl logs kafka-0 | grep advertised

# Restart Kafka
kubectl delete pod kafka-0
kubectl wait --for=condition=ready pod/kafka-0
```

#### SeaweedFS Not Accessible
```bash
# Check SeaweedFS status
kubectl get pods -l app=seaweedfs
kubectl describe pod -l app=seaweedfs

# Check service
kubectl get svc seaweedfs-s3
kubectl get svc seaweedfs-filer
```

#### Image Pipeline Errors
```bash
# Check consumer logs
kubectl logs -n airflow -l app=image-consumer --tail=50

# Check producer logs
kubectl logs -n airflow -l app=image-producer --tail=50

# Restart deployments
kubectl rollout restart -n airflow deployment/image-consumer
kubectl rollout restart -n airflow deployment/image-producer
```

---

## 🧪 Advanced Testing

### Submit Custom Spark Job (Optional)
```bash
# Spark Operator is installed and ready for custom jobs
# Create your own SparkApplication manifest and submit it:
kubectl apply -f your-spark-job.yaml

# Check status
kubectl get sparkapplications

# View logs
kubectl logs <spark-driver-pod>
```

### Deploy Airflow DAG
```bash
# Copy DAG to Airflow
SCHEDULER_POD=$(kubectl get pod -n airflow -l component=scheduler -o jsonpath="{.items[0].metadata.name}")

# Wait for Airflow to discover DAGs (30 seconds)
sleep 30

# List DAGs
kubectl exec -n airflow $SCHEDULER_POD -c scheduler -- airflow dags list
```



---

## 🧹 Cleanup

### Stop Pipeline Only
```bash
# Local pipeline
pkill -f image_consumer.py
pkill -f image_producer.py

# Kubernetes pipeline
kubectl delete -f manifests/streaming/image-service/image-service.yaml
kubectl delete configmap -n airflow image-service-scripts
```

### Delete Entire Platform
```bash
./delete-platform.sh
```

This will:
- Delete the Kind cluster
- Remove all data
- Clean up resources

---

## 📁 Project Structure

```
data-platform/
├── dags/                           # Airflow DAG definitions
│   └── image_processing_etl_dag.py # Image ETL processing
├── manifests/                      # Kubernetes manifests
│   ├── deployments/                # Infrastructure deployments
│   │   ├── kafka-deployment.yaml   # Kafka StatefulSet
│   │   ├── seaweedfs-deployment.yaml  # SeaweedFS (S3) Deployment
│   │   ├── postgres-postgis.yaml   # PostgreSQL with PostGIS
│   │   ├── iceberg-rest-catalog.yaml  # Lakekeeper REST Catalog
│   │   └── doris.yaml                 # Apache Doris (unified image)
│   └── streaming/                  # Real-time event processing
│       └── image-service/         # Image pipeline (service-managed)
│           ├── image-service.yaml     # Image processing pipeline
│           ├── image_consumer.py      # Kafka consumer (images → S3 + DB)
│           └── image_producer.py      # File watcher (folder → Kafka)
├── queries/                        # SQL queries
│   ├── iceberg-examples.sql       # Iceberg/Doris examples
│   └── postgis-examples.sql       # PostGIS geospatial queries
├── images/                         # Image storage (local testing)
│   └── incoming/                  # Watch folder for new images
├── logs/                          # Application logs
├── .venv/                         # Python virtual environment
├── .env.example                   # Environment variables template
├── .gitignore                     # Git ignore patterns
├── install-platform.sh            # Main installation script
├── delete-platform.sh             # Cleanup script
├── test-platform.sh               # Test suite
├── setup-portforward.sh           # Setup port-forwards for local dev
├── run-pipeline.sh                # Run pipeline locally
├── deploy-streaming.sh            # Deploy streaming pipeline to K8s
├── upload-images.sh               # Upload test images to pipeline
├── query-doris.sh                 # Query Doris/Iceberg
├── requirements.txt               # Python dependencies
└── README.md                      # This file
```

---

## 🔧 Configuration

### Environment Variables

Copy `.env.example` to `.env` and customize:

```bash
# Kafka
KAFKA_BOOTSTRAP_SERVERS=localhost:9092
KAFKA_TOPIC=image-uploads

# S3 (SeaweedFS)
S3_ENDPOINT=http://localhost:9000
S3_ACCESS_KEY_ID=admin
S3_SECRET_ACCESS_KEY=seaweedfs_password
S3_BUCKET=images
S3_REGION=us-east-1

# PostgreSQL
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<get-from-secret>

# Producer
WATCH_PATH=./images/incoming
```

### Get PostgreSQL Password
```bash
kubectl get secret postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d
```

---

## 🎓 What You Can Learn

This platform demonstrates:
- ✅ Kubernetes cluster management with Kind
- ✅ Helm chart deployments
- ✅ Microservices architecture
- ✅ Message-driven architecture with Kafka
- ✅ Object storage with SeaweedFS (S3-compatible)
- ✅ Data lakehouse with Apache Iceberg
- ✅ REST catalog pattern with Lakekeeper
- ✅ Distributed SQL with Apache Doris
- ✅ Geospatial data processing with PostGIS
- ✅ Workflow orchestration with Airflow
- ✅ Big data processing with Spark
- ✅ File watching and event-driven processing
- ✅ Database integration
- ✅ Container orchestration

---

## 📚 Additional Resources

- [Kind Documentation](https://kind.sigs.k8s.io/)
- [Apache Kafka](https://kafka.apache.org/)
- [SeaweedFS](https://github.com/seaweedfs/seaweedfs)
- [Apache Airflow](https://airflow.apache.org/)
- [Apache Spark](https://spark.apache.org/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)

---

## 🤝 Troubleshooting

### Platform won't start
1. Check Docker is running: `docker ps`
2. Check Kind cluster exists: `kind get clusters`
3. Check available resources: `docker stats`

### Port-forward fails
```bash
# Kill all port-forwards
pkill -f port-forward

# Restart
./setup-portforward.sh
```

### Image pipeline not processing
1. Check Kafka topic exists: 
   ```bash
   kubectl exec kafka-0 -- /opt/kafka/bin/kafka-topics.sh --list --bootstrap-server localhost:9092
   ```
2. Check images directory exists: `ls -la images/incoming/`
3. Verify file permissions: `chmod 777 images/incoming/`

---

## 📝 Notes

- **Storage:** SeaweedFS uses ephemeral storage (data lost on restart). For persistence, update the manifest.
- **Resources:** Requires ~8GB RAM and 4 CPU cores for smooth operation.
- **Network:** All services communicate via Kubernetes internal DNS.
- **Scaling:** Increase consumer replicas in `manifests/streaming/image-service/image-service.yaml` for higher throughput.

---

**Happy Data Engineering! 🚀**
