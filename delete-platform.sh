#!/bin/bash
# Local Data Platform Cleanup Script

CLUSTER_NAME="data-platform"

echo "🛑 Stopping Port-Forwards..."
# Kills any active kubectl port-forward processes
pkill -f "kubectl port-forward" || echo "No active port-forwards found."

echo "🗑️ Deleting the Kind Cluster..."
# This removes the nodes, pods, and internal volumes
kind delete cluster --name $CLUSTER_NAME

echo "🧹 Cleaning up local Helm cache..."
helm repo remove bitnami apache-airflow spark-operator 2>/dev/null || true
rm -rf ~/.cache/helm

echo "🐳 Pruning Docker (optional)..."
# This removes unused container layers and dangling images to free up GBs of space
# Warning: This cleans up Docker globally, not just Kind.
docker system prune -f

echo "✨ Everything is gone. Your system is clean!"
