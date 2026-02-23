#!/usr/bin/env bash
set -euo pipefail

NAMESPACE_DEFAULT="${NAMESPACE_DEFAULT:-default}"

CATALOG_NAME="${CATALOG_NAME:-lakekeeper_iceberg}"
ICEBERG_NAMESPACE="${ICEBERG_NAMESPACE:-default}"
ICEBERG_TABLE="${ICEBERG_TABLE:-image_uploads_processed}"
ICEBERG_WAREHOUSE="${ICEBERG_WAREHOUSE:-seaweedfs}"

LIMIT_ROWS="${LIMIT_ROWS:-5}"

DORIS_FE_POD=$(kubectl get pod -n "$NAMESPACE_DEFAULT" -l app=doris-fe -o jsonpath='{.items[0].metadata.name}')
DORIS_BE_POD=$(kubectl get pod -n "$NAMESPACE_DEFAULT" -l app=doris-be -o jsonpath='{.items[0].metadata.name}')

LAKEKEEPER_URI="${LAKEKEEPER_URI:-http://iceberg-rest.${NAMESPACE_DEFAULT}.svc.cluster.local:8181/catalog}"
S3_ENDPOINT_HOSTPORT="${S3_ENDPOINT_HOSTPORT:-seaweedfs-s3.${NAMESPACE_DEFAULT}.svc.cluster.local:8333}"

S3_ACCESS_KEY=$(kubectl get secret -n "$NAMESPACE_DEFAULT" seaweedfs-s3 -o jsonpath='{.data.access-key}' | base64 -d)
S3_SECRET_KEY=$(kubectl get secret -n "$NAMESPACE_DEFAULT" seaweedfs-s3 -o jsonpath='{.data.secret-key}' | base64 -d)

wait_ready() {
  local kind="$1" ns="$2" name="$3"
  kubectl wait -n "$ns" --for=condition=ready "$kind/$name" --timeout=180s >/dev/null
}

mysql_exec() {
  local sql="$1"
  kubectl exec -n "$NAMESPACE_DEFAULT" -c doris-fe "$DORIS_FE_POD" -- \
    mysql --batch --raw -h 127.0.0.1 -P 9030 -uroot -e "$sql"
}

echo "🔎 Doris FE pod: $DORIS_FE_POD"
echo "🔎 Doris BE pod: $DORIS_BE_POD"

echo "⏳ Waiting for Doris FE/BE to be Ready..."
wait_ready pod "$NAMESPACE_DEFAULT" "$DORIS_FE_POD"
wait_ready pod "$NAMESPACE_DEFAULT" "$DORIS_BE_POD"

echo "✅ Doris is ready"

printf "\n📚 Ensuring Iceberg catalog '%s' exists and is configured\n" "$CATALOG_NAME"
set +e
mysql_exec "CREATE CATALOG $CATALOG_NAME PROPERTIES (\
  'type'='iceberg',\
  'iceberg.catalog.type'='rest',\
  'iceberg.rest.uri'='$LAKEKEEPER_URI',\
  'warehouse'='$ICEBERG_WAREHOUSE',\
  's3.endpoint'='$S3_ENDPOINT_HOSTPORT',\
  's3.access_key'='$S3_ACCESS_KEY',\
  's3.secret_key'='$S3_SECRET_KEY',\
  's3.region'='us-east-1',\
  's3.enable_ssl'='false',\
  's3.path_style_access'='true',\
  's3.use_path_style'='true',\
  'use_path_style'='true',\
  'use_virtual_addressing'='false',\
  's3.use_virtual_addressing'='false',\
  's3.virtual_hosted_style'='false'\
);" 2>/dev/null
CREATE_RC=$?
set -e
if [ $CREATE_RC -ne 0 ]; then
  echo "ℹ️  Catalog already exists (or Doris rejected CREATE). Applying ALTER to enforce properties..."
fi

mysql_exec "ALTER CATALOG $CATALOG_NAME SET PROPERTIES (\
  'iceberg.rest.uri'='$LAKEKEEPER_URI',\
  'warehouse'='$ICEBERG_WAREHOUSE',\
  's3.endpoint'='$S3_ENDPOINT_HOSTPORT',\
  's3.access_key'='$S3_ACCESS_KEY',\
  's3.secret_key'='$S3_SECRET_KEY',\
  's3.region'='us-east-1',\
  's3.enable_ssl'='false',\
  's3.path_style_access'='true',\
  's3.use_path_style'='true',\
  'use_path_style'='true',\
  'use_virtual_addressing'='false',\
  's3.use_virtual_addressing'='false',\
  's3.virtual_hosted_style'='false'\
);" >/dev/null

printf "\n🧾 Catalog definition:\n"
mysql_exec "SHOW CREATE CATALOG $CATALOG_NAME;" | cat

printf "\n🧊 Iceberg verification:\n"
mysql_exec "SWITCH $CATALOG_NAME; USE $ICEBERG_NAMESPACE; SHOW TABLES;" | cat

printf "\nRow count:\n"
mysql_exec "SWITCH $CATALOG_NAME; USE $ICEBERG_NAMESPACE; SELECT COUNT(*) FROM $ICEBERG_TABLE;" | cat

printf "\nLatest rows:\n"
mysql_exec "SWITCH $CATALOG_NAME; USE $ICEBERG_NAMESPACE; SELECT processed_at, file_hash, filename, file_size, mime_type FROM $ICEBERG_TABLE ORDER BY processed_at DESC LIMIT $LIMIT_ROWS;" | cat
