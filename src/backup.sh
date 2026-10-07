#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

echo "Creating backup of $POSTGRES_DATABASE database..."
pg_dump --format=custom \
        -h $POSTGRES_HOST \
        -p $POSTGRES_PORT \
        -U $POSTGRES_USER \
        -d $POSTGRES_DATABASE \
        $PGDUMP_EXTRA_OPTS \
        > db.dump

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
s3_uri="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump.gpg"

echo "Encrypting backup..."
rm -f db.dump.gpg
gpg --symmetric --batch --passphrase "$PASSPHRASE" db.dump
rm db.dump

echo "Uploading backup to $S3_BUCKET..."
aws $aws_args s3 cp db.dump.gpg "$s3_uri"
rm db.dump.gpg

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
