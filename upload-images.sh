#!/bin/bash
set -euo pipefail

# Upload images to the image-producer pod

NAMESPACE="${NAMESPACE:-default}"
LABEL_SELECTOR="${LABEL_SELECTOR:-app=image-producer}"
DEST_DIR="${DEST_DIR:-/data/incoming}"
CONTAINER="${CONTAINER:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SRC_DIR:-$SCRIPT_DIR/images/incoming}"

if [ ! -d "$SRC_DIR" ]; then
    echo "❌ Source directory not found: $SRC_DIR" >&2
    exit 1
fi

POD="$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"

if [ -z "$POD" ]; then
    echo "❌ Image producer pod not found (namespace=$NAMESPACE, selector=$LABEL_SELECTOR)" >&2
    exit 1
fi

if [ -z "$CONTAINER" ]; then
    CONTAINER="$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.spec.containers[0].name}')"
fi

echo "📤 Uploading images from: $SRC_DIR"
echo "➡️  To pod: $POD (ns=$NAMESPACE, container=$CONTAINER)"

if ! kubectl cp -n "$NAMESPACE" -c "$CONTAINER" "$SRC_DIR"/. "$POD":"$DEST_DIR"/; then
    echo "❌ Upload failed" >&2
    exit 1
fi

echo "✅ Images uploaded successfully"
echo ""
echo "Check producer logs with:"
echo "  kubectl logs -n $NAMESPACE -l $LABEL_SELECTOR --tail=50 -f"
