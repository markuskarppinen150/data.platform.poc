#!/bin/bash
# Upload images to the image-producer pod

POD=$(kubectl get pods -n default -l app=image-producer -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD" ]; then
    echo "❌ Image producer pod not found"
    exit 1
fi

echo "📤 Uploading images to pod: $POD"

# Copy all files from local incoming folder to pod
kubectl cp /home/markus/Documents/data-platform/images/incoming/. default/$POD:/data/incoming/

echo "✅ Images uploaded successfully"
echo ""
echo "Check producer logs with:"
echo "  kubectl logs -n default -l app=image-producer --tail=50 -f"
