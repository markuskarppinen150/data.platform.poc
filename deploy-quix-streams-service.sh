#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-data-platform}"
IMAGE_NAME="${IMAGE_NAME:-quix-streams-service:local}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$SCRIPT_DIR/manifests/streaming/quix-streams-service"

echo "🐳 Building image: $IMAGE_NAME"
docker build -t "$IMAGE_NAME" "$SERVICE_DIR"

echo "📦 Loading image into kind cluster: $CLUSTER_NAME"
kind load docker-image --name "$CLUSTER_NAME" "$IMAGE_NAME"

echo "🚀 Deploying Quix Streams service"
kubectl apply -f "$SERVICE_DIR/quix-streams-service.yaml"

echo "✅ Deployed"
echo "Check logs with:"
echo "  kubectl logs -n airflow -l app=quix-streams-service -f"
