#!/bin/bash
set -e

echo "🚀 Deploying Image Streaming Pipeline..."
echo ""

# Create ConfigMap from Python files
echo "📦 Creating ConfigMap from Python scripts..."
kubectl create configmap image-service-scripts \
  --from-file=image_producer.py=manifests/streaming/image-service/image_producer.py \
  --from-file=image_consumer.py=manifests/streaming/image-service/image_consumer.py \
  --namespace=default \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✓ ConfigMap created"
echo ""

# Apply the rest of the streaming pipeline
echo "📦 Deploying streaming pipeline components..."
kubectl apply -f manifests/streaming/image-service/image-service.yaml

echo ""
echo "✅ Image Streaming Pipeline deployed successfully!"
echo ""
echo "To check status:"
echo "  kubectl get pods -l 'app in (image-producer,image-consumer)'"
echo ""
echo "To view logs:"
echo "  kubectl logs -f deployment/image-producer"
echo "  kubectl logs -f deployment/image-consumer"
