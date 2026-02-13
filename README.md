# Local Data Platform - Setup Guide

A complete local data platform with PostgreSQL, MinIO (S3), Kafka, Airflow, and Spark running on Kubernetes (Kind).

## 🎯 Overview

This platform includes:
- **PostgreSQL + PostGIS** - Relational database with geospatial capabilities
- **MinIO** - S3-compatible object storage
- **Kafka** - Message broker for streaming
- **Apache Iceberg** - Table format for data lakes
- **Apache Polaris** - REST catalog for Iceberg
- **Trino** - Distributed SQL query engine
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
   curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
   chmod +x ./kind
   sudo mv ./kind /usr/local/bin/kind
   
   # Verify
   kind version
   ```

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

**What this does:**
- Creates a 3-node Kind cluster
- Installs PostgreSQL with PostGIS (geospatial database)
- Installs MinIO (object storage)
- Installs Kafka (message broker)
- Installs Apache Polaris (Iceberg REST catalog)
- Installs Trino (query engine)
- Installs Airflow (orchestration)
- Installs Spark Operator (data processing)

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
- ✓ Apache Polaris REST catalog
- ✓ Trino query engine
- ✓ MinIO storage access
- ✓ Kafka broker connectivity
- ✓ Airflow is operational
- ✓ Spark Operator CRDs

**Expected output:**
```
✅ Test Suite Complete!
```

---

### Step 3: Setup Python Environment

```bash
# Create virtual environment (done automatically on first run)
# Install dependencies
source .venv/bin/activate
pip install -r requirements.txt
```

---

### Step 4: Run the Image Pipeline (Choose A or B)

#### Option A: Run Locally (with port-forwarding)

```bash
# Terminal 1: Setup port forwards and services
./setup-portforward.sh

# Terminal 2: Start the pipeline
source .venv/bin/activate
export POSTGRES_PASSWORD=$(kubectl get secret postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)

# Start consumer
python scripts/image_consumer.py &

# Start producer
python scripts/image_producer.py &

# Terminal 3: Add test images
cp ~/Pictures/test-image.jpg images/incoming/
```

#### Option B: Run in Kubernetes (recommended)

```bash
# Deploy pipeline to cluster
./deploy-pipeline.sh

# Upload test image
PRODUCER_POD=$(kubectl get pod -l app=image-producer -o jsonpath='{.items[0].metadata.name}')
kubectl cp ~/Pictures/test-image.jpg $PRODUCER_POD:/data/incoming/

# Monitor logs
kubectl logs -l app=image-consumer -f
```

---

### Step 5: Access Services

#### Airflow UI
```bash
kubectl port-forward svc/airflow-api-server 8080:8080 -n airflow
```
- URL: http://localhost:8080
- Username: `admin`
- Password: `admin`

#### MinIO Console
```bash
kubectl port-forward svc/minio 9001:9001
```
- URL: http://localhost:9001
- Username: `admin`
- Password: `minio_password`

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

**Example PostGIS queries:** See [queries/postgis-examples.sql](queries/postgis-examples.sql)

#### Trino Query Engine
```bash
kubectl port-forward svc/trino 8080:8080
```
- URL: http://localhost:8080
- Or use CLI: `./query-trino.sh`

**Example Trino queries:**
```bash
# List catalogs
./query-trino.sh

# Interactive mode
trino --server http://localhost:8080

# Query Iceberg tables
trino --server http://localhost:8080 --catalog iceberg --schema data_lake
```

#### Apache Polaris REST Catalog
```bash
kubectl port-forward svc/iceberg-rest 8181:8181
```
- Health check: http://localhost:8181/health
- REST API endpoint for Iceberg clients

```

---

## 📸 Image Pipeline Workflow

### How It Works

1. **Watch Folder** → Producer monitors `images/incoming/`
2. **Kafka** → Images sent as base64-encoded messages
3. **Consumer** → Reads from Kafka, processes images
4. **MinIO** → Stores images in S3 bucket (date-partitioned)
5. **PostgreSQL** → Records metadata (filename, hash, size, S3 path)

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
kubectl exec $(kubectl get pod -l app=minio -o jsonpath="{.items[0].metadata.name}") -- \
  ls -lh /data/images/2026/02/11/
```

**Check Database:**
```bash
kubectl exec postgres-postgresql-0 -- \
  env PGPASSWORD=$(kubectl get secret postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d) \
  psql -U postgres -c "SELECT filename, file_size, s3_path, uploaded_at FROM image_metadata ORDER BY uploaded_at DESC LIMIT 10;"
```

**Using MinIO Client:**
```bash
# Install mc
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# Configure
kubectl port-forward svc/minio 9000:9000 &
mc alias set local http://localhost:9000 admin minio_password

# List files
mc ls -r local/images/
```

---

## 📊 Monitoring & Debugging

### Check Pod Status
```bash
# All pods
kubectl get pods --all-namespaces

# Specific components
kubectl get pods -l app=minio
kubectl get pods -l app=kafka
kubectl get pods -n airflow
```

### View Logs
```bash
# Kafka
kubectl logs kafka-0

# MinIO
kubectl logs -l app=minio

# Airflow Scheduler
kubectl logs -n airflow -l component=scheduler

# Image Pipeline
kubectl logs -l app=image-consumer -f
kubectl logs -l app=image-producer -f
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

#### MinIO Not Accessible
```bash
# Check MinIO status
kubectl get pods -l app=minio
kubectl describe pod -l app=minio

# Check service
kubectl get svc minio
```

#### Image Pipeline Errors
```bash
# Check consumer logs
kubectl logs -l app=image-consumer --tail=50

# Check producer logs
kubectl logs -l app=image-producer --tail=50

# Restart deployments
kubectl rollout restart deployment/image-consumer
kubectl rollout restart deployment/image-producer
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

# Deploy Image Pipeline DAG
kubectl cp dags/image_processing_pipeline_dag.py airflow/$SCHEDULER_POD:/opt/airflow/dags/

# Wait for Airflow to discover DAGs (30 seconds)
sleep 30

# List DAGs
kubectl exec -n airflow $SCHEDULER_POD -- airflow dags list

# Trigger Image Pipeline DAG
kubectl exec -n airflow $SCHEDULER_POD -- airflow dags trigger image_processing_pipeline
```

**Image Pipeline DAG Features:**
- ✅ Health checks for Kafka, MinIO, PostgreSQL
- ✅ Kafka consumer lag monitoring
- ✅ Auto-scaling alerts when lag is high
- ✅ Daily statistics and reports
- ✅ Latest images summary
- ✅ Runs every 5 minutes

---

## 🧹 Cleanup

### Stop Pipeline Only
```bash
# Local pipeline
pkill -f image_consumer.py
pkill -f image_producer.py

# Kubernetes pipeline
kubectl delete -f manifests/pipelines/image-pipeline.yaml
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
│   ├── image_processing_pipeline_dag.py  # Image pipeline monitoring
│   └── image_processing_etl_dag.py # Image ETL processing
├── manifests/                      # Kubernetes manifests
│   ├── deployments/                # Infrastructure deployments
│   │   ├── kafka-deployment.yaml   # Kafka StatefulSet
│   │   ├── minio-deployment.yaml   # MinIO Deployment
│   │   ├── postgres-postgis.yaml   # PostgreSQL with PostGIS
│   │   ├── iceberg-rest-catalog.yaml  # Apache Polaris REST Catalog
│   │   └── trino-rest.yaml            # Trino with Polaris
│   └── pipelines/                  # Data pipelines
│       └── image-pipeline.yaml    # Image processing pipeline
├── queries/                        # SQL queries
│   ├── iceberg-examples.sql       # Iceberg/Trino examples
│   └── postgis-examples.sql       # PostGIS geospatial queries
├── scripts/                        # Python scripts
│   ├── image_consumer.py          # Kafka consumer (images → S3 + DB)
│   └── image_producer.py          # File watcher (folder → Kafka)
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
├── deploy-pipeline.sh             # Deploy pipeline to K8s
├── upload-images.sh               # Upload test images to pipeline
├── query-trino.sh                 # Query Trino/Iceberg
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

# MinIO
MINIO_ENDPOINT=localhost:9000
MINIO_ACCESS_KEY=admin
MINIO_SECRET_KEY=minio_password
MINIO_BUCKET=images

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
- ✅ Data lakehouse with Apache Iceberg
This platform demonstrates:
- ✅ Kubernetes cluster management with Kind
- ✅ Helm chart deployments
- ✅ Microservices architecture
- ✅ Message-driven architecture with Kafka
- ✅ Object storage with MinIO (S3-compatible)
- ✅ Data lakehouse with Apache Iceberg
- ✅ REST catalog pattern with Apache Polaris
- ✅ Distributed SQL with Trino
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
- [MinIO Documentation](https://min.io/docs/)
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

- **Storage:** MinIO uses ephemeral storage (data lost on restart). For persistence, update the manifest.
- **Resources:** Requires ~8GB RAM and 4 CPU cores for smooth operation.
- **Network:** All services communicate via Kubernetes internal DNS.
- **Scaling:** Increase consumer replicas in `manifests/pipelines/image-pipeline.yaml` for higher throughput.

---

**Happy Data Engineering! 🚀**
