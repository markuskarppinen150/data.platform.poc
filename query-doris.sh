#!/bin/bash
# Query Apache Doris/Iceberg from command line

echo "🔍 Apache Doris Query Tool"
echo "=========================="

# Setup port-forward if not already running
if ! pgrep -f "port-forward.*doris-fe" > /dev/null; then
    echo "Setting up Doris port-forward..."
    kubectl port-forward svc/doris-fe 9030:9030 8030:8030 > /dev/null 2>&1 &
    sleep 3
fi

# Check if mysql client is installed
if ! command -v mysql &> /dev/null; then
    echo "⚠️ MySQL client not found. Install it with:"
    echo "  Ubuntu/Debian: sudo apt install mysql-client"
    echo "  MacOS: brew install mysql-client"
    exit 1
fi

echo ""
echo "✅ Doris Query Interface ready!"
echo ""
echo "Connection details:"
echo "  Host: localhost"
echo "  Port: 9030"
echo "  User: root"
echo "  Password: (none)"
echo ""
echo "Example queries:"
echo "  mysql -h 127.0.0.1 -P 9030 -u root"
echo ""
echo "Quick queries:"
echo "  mysql -h 127.0.0.1 -P 9030 -u root -e 'SHOW DATABASES;'"
echo "  mysql -h 127.0.0.1 -P 9030 -u root -e 'SHOW CATALOGS;'"
echo ""
echo "Execute query from file:"
echo "  mysql -h 127.0.0.1 -P 9030 -u root < queries/iceberg-examples.sql"
echo ""
echo "Web UI: http://localhost:8030 (admin/admin)"
echo ""

# Execute example query
echo "Running sample query..."
mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW DATABASES;" 2>/dev/null || echo "⚠️ Doris not ready yet, wait a moment and try again"
