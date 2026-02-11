#!/bin/bash
# Deploy the image processing pipeline to Kubernetes

set -e

echo "🚀 Deploying Image Processing Pipeline to Kubernetes..."

# Create ConfigMap with scripts
echo "📝 Creating ConfigMap with Python scripts..."
kubectl create configmap image-pipeline-scripts \
  --from-file=image_producer.py=scripts/image_producer.py \
  --from-file=image_consumer.py=scripts/image_consumer.py \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy the pipeline
echo "📦 Deploying pipeline components..."
kubectl apply -f manifests/pipelines/image-pipeline.yaml

# Wait for deployments
echo "⏳ Waiting for deployments to be ready..."
kubectl wait --for=condition=available deployment/image-consumer --timeout=120s
kubectl wait --for=condition=available deployment/image-producer --timeout=120s

echo ""
echo "✅ Image Pipeline Deployed!"
echo ""
echo "📊 Check status:"
echo "   kubectl get pods -l 'app in (image-producer,image-consumer)'"
echo ""
echo "📋 View logs:"
echo "   kubectl logs -l app=image-producer -f"
echo "   kubectl logs -l app=image-consumer -f"
echo ""
echo "📸 Upload images:"
echo "   # Copy image to producer pod"
echo "   PRODUCER_POD=\$(kubectl get pod -l app=image-producer -o jsonpath='{.items[0].metadata.name}')"
echo "   kubectl cp /path/to/image.jpg \$PRODUCER_POD:/data/incoming/"
echo ""
echo "🔍 Check S3 storage:"
echo "   kubectl port-forward svc/minio 9001:9001"
echo "   Open: http://localhost:9001"
echo ""
echo "🗄️  Check database:"
echo "   kubectl exec -it postgres-postgresql-0 -- psql -U postgres -c 'SELECT * FROM image_metadata;'"
