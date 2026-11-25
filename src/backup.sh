#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
s3_uri="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump.gpg"

uploaded=no
cleanup() {
  if [ "$uploaded" != "yes" ]; then
    echo "Backup failed, removing truncated upload..."
    aws $aws_args s3 rm "$s3_uri"
  fi
}
trap cleanup EXIT

# Streamed, so nothing touches the container disk. A stream upload is capped
# at 10000 parts, so 64MB parts allow dumps up to 640GB.
aws configure set default.s3.multipart_chunksize 64MB

echo "Streaming backup of $POSTGRES_DATABASE database to $S3_BUCKET..."
pg_dump --format=custom \
        -h $POSTGRES_HOST \
        -p $POSTGRES_PORT \
        -U $POSTGRES_USER \
        -d $POSTGRES_DATABASE \
        $PGDUMP_EXTRA_OPTS \
  | gpg --symmetric --batch --passphrase "$PASSPHRASE" --compress-algo none \
  | aws $aws_args s3 cp - "$s3_uri"
uploaded=yes

echo "Backup complete."

sec=$((86400*BACKUP_KEEP_DAYS))
date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].{Key: Key}"

echo "Removing old backups from $S3_BUCKET..."
aws $aws_args s3api list-objects \
  --bucket "${S3_BUCKET}" \
  --prefix "${S3_PREFIX}" \
  --query "${backups_query}" \
  --output text \
  | xargs -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
echo "Removal complete."
