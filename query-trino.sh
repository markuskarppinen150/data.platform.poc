#!/bin/bash
# Query Trino/Iceberg from command line

echo "🔍 Trino Query Tool"
echo "==================="

# Setup port-forward if not already running
if ! pgrep -f "port-forward.*trino" > /dev/null; then
    echo "Setting up Trino port-forward..."
    kubectl port-forward svc/trino 8080:8080 > /dev/null 2>&1 &
    sleep 3
fi

# Install trino-cli if not present
if ! command -v trino &> /dev/null; then
    echo "Installing Trino CLI..."
    wget -q https://repo1.maven.org/maven2/io/trino/trino-cli/438/trino-cli-438-executable.jar -O trino
    chmod +x trino
    sudo mv trino /usr/local/bin/
fi

echo ""
echo "✅ Trino CLI ready!"
echo ""
echo "Example queries:"
echo "  trino --server http://localhost:8080 --catalog iceberg --schema data_lake"
echo ""
echo "Interactive mode:"
echo "  trino --server http://localhost:8080"
echo ""
echo "Execute query from file:"
echo "  trino --server http://localhost:8080 --file queries/iceberg-examples.sql"
echo ""
echo "Quick queries:"
echo "  trino --server http://localhost:8080 --execute 'SHOW CATALOGS'"
echo "  trino --server http://localhost:8080 --execute 'SHOW SCHEMAS FROM iceberg'"
echo ""

# Execute example query
echo "Running sample query..."
trino --server http://localhost:8080 --execute "SHOW CATALOGS" 2>/dev/null || echo "⚠️ Trino not ready yet, wait a moment and try again"
