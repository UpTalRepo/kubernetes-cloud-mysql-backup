#!/bin/sh

# Set the has_failed variable to false. This will change if any of the subsequent database backups/uploads fail.
has_failed=false

# Streaming mode: pipe mysqldump | gzip directly to cloud storage without writing to local disk.
# This prevents ephemeral disk exhaustion on single-node clusters with large databases.
# Each database is uploaded as a separate compressed blob.

BACKUP_TIMESTAMP_VALUE=$(date +${BACKUP_TIMESTAMP})

# Create the GCloud Authentication file if set
if [ ! -z "$GCP_GCLOUD_AUTH" ]; then

    # Check if we are already base64 decoded, credit: https://stackoverflow.com/questions/8571501/how-to-check-whether-a-string-is-base64-encoded-or-not
    if echo "$GCP_GCLOUD_AUTH" | grep -Eq '^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)?$'; then
        echo "$GCP_GCLOUD_AUTH" | base64 --decode >"$HOME"/gcloud.json
    else
        echo "$GCP_GCLOUD_AUTH" >"$HOME"/gcloud.json
    fi

    # Activate the Service Account
    gcloud auth activate-service-account --key-file=$HOME/gcloud.json

fi

# Configure Azure CLI authentication if Azure credentials are set
if [ ! -z "$AZURE_STORAGE_ACCOUNT_NAME" ] && [ ! -z "$AZURE_STORAGE_ACCESS_KEY" ]; then
    export AZURE_STORAGE_ACCOUNT="$AZURE_STORAGE_ACCOUNT_NAME"
    export AZURE_STORAGE_KEY="$AZURE_STORAGE_ACCESS_KEY"
fi

# Set the BACKUP_CREATE_DATABASE_STATEMENT variable
if [ "$BACKUP_CREATE_DATABASE_STATEMENT" = "true" ]; then
    BACKUP_CREATE_DATABASE_STATEMENT="--databases"
else
    BACKUP_CREATE_DATABASE_STATEMENT=""
fi

# Set default authentication plugin if not specified
if [ -z "$MYSQL_AUTH_PLUGIN" ]; then
    MYSQL_AUTH_PLUGIN="caching_sha2_password"
fi

# Build MySQL connection options with authentication plugin
MYSQL_AUTH_OPTS="--default-auth=$MYSQL_AUTH_PLUGIN"

if [ "$TARGET_ALL_DATABASES" = "true" ]; then
    # Ignore any databases specified by TARGET_DATABASE_NAMES
    if [ ! -z "$TARGET_DATABASE_NAMES" ]
    then
        echo "Both TARGET_ALL_DATABASES is set to 'true' and databases are manually specified by 'TARGET_DATABASE_NAMES'. Ignoring 'TARGET_DATABASE_NAMES'..."
        TARGET_DATABASE_NAMES=""
    fi
    # Build Database List
    ALL_DATABASES_EXCLUSION_LIST="'mysql','sys','tmp','information_schema','performance_schema'"
    ALL_DATABASES_SQLSTMT="SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN (${ALL_DATABASES_EXCLUSION_LIST})"
    if ! ALL_DATABASES_DATABASE_LIST=`mysql $MYSQL_AUTH_OPTS -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT -ANe"${ALL_DATABASES_SQLSTMT}"`
    then
        echo -e "Building list of all databases failed at $(date +'%d-%m-%Y %H:%M:%S')." | tee -a /tmp/kubernetes-cloud-mysql-backup.log
        has_failed=true
    fi
    if [ "$has_failed" = false ]; then
        for DB in ${ALL_DATABASES_DATABASE_LIST}
        do
            TARGET_DATABASE_NAMES="${TARGET_DATABASE_NAMES}${DB},"
        done
        #Remove trailing comma
        TARGET_DATABASE_NAMES=${TARGET_DATABASE_NAMES%?}
        echo -e "Successfully built list of all databases (${TARGET_DATABASE_NAMES}) at $(date +'%d-%m-%Y %H:%M:%S')."
    fi
fi

# Convert BACKUP_PROVIDER to lowercase
BACKUP_PROVIDER=$(echo "$BACKUP_PROVIDER" | awk '{print tolower($0)}')

# Convert BACKUP_COMPRESS to lowercase
BACKUP_COMPRESS=$(echo "$BACKUP_COMPRESS" | awk '{print tolower($0)}')

# Set compression level
if [ -z "$BACKUP_COMPRESS_LEVEL" ]; then
    BACKUP_COMPRESS_LEVEL="9"
fi

# Loop through all the defined databases, separating by a ,
if [ "$has_failed" = false ]; then
    for CURRENT_DATABASE in ${TARGET_DATABASE_NAMES//,/ }; do

        # Build the blob/object name for this database
        DUMP_NAME="${CURRENT_DATABASE}${BACKUP_TIMESTAMP_VALUE}.sql"
        if [ "$BACKUP_COMPRESS" = "true" ]; then
            DUMP_NAME="${DUMP_NAME}.gz"
        fi

        echo -e "Starting streaming backup for database: $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S')..."

        # ---- AZURE: Stream mysqldump | gzip | python3 stream-to-azure.py ----
        if [ "$BACKUP_PROVIDER" = "azure" ]; then

            # Construct the blob path
            AZURE_BLOB_PATH="${AZURE_BACKUP_PATH#/}"
            if [ ! -z "$AZURE_BLOB_PATH" ]; then
                AZURE_BLOB_PATH="${AZURE_BLOB_PATH}/${DUMP_NAME}"
            else
                AZURE_BLOB_PATH="${DUMP_NAME}"
            fi

            if [ "$BACKUP_COMPRESS" = "true" ]; then
                # Stream: mysqldump | gzip | python upload via block blob API (stdin, no disk)
                # Use pipefail-safe approach: write mysqldump exit code to a temp file
                PIPE_STATUS_FILE=$(mktemp)
                (mysqldump $MYSQL_AUTH_OPTS -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST \
                    -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT \
                    $BACKUP_ADDITIONAL_PARAMS $BACKUP_CREATE_DATABASE_STATEMENT \
                    $CURRENT_DATABASE 2>/tmp/mysqldump_stderr_${CURRENT_DATABASE}.log; \
                    echo $? > "$PIPE_STATUS_FILE") | \
                    gzip -${BACKUP_COMPRESS_LEVEL} | \
                    python3 /stream-to-azure.py "$AZURE_CONTAINER_NAME" "$AZURE_BLOB_PATH" \
                        2>/tmp/az_stderr_${CURRENT_DATABASE}.log

                AZ_EXIT=$?
                MYSQLDUMP_EXIT=$(cat "$PIPE_STATUS_FILE" 2>/dev/null || echo "1")
                rm -f "$PIPE_STATUS_FILE"
            else
                # Stream without compression: mysqldump | python upload via block blob API (stdin, no disk)
                PIPE_STATUS_FILE=$(mktemp)
                (mysqldump $MYSQL_AUTH_OPTS -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST \
                    -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT \
                    $BACKUP_ADDITIONAL_PARAMS $BACKUP_CREATE_DATABASE_STATEMENT \
                    $CURRENT_DATABASE 2>/tmp/mysqldump_stderr_${CURRENT_DATABASE}.log; \
                    echo $? > "$PIPE_STATUS_FILE") | \
                    python3 /stream-to-azure.py "$AZURE_CONTAINER_NAME" "$AZURE_BLOB_PATH" \
                        2>/tmp/az_stderr_${CURRENT_DATABASE}.log

                AZ_EXIT=$?
                MYSQLDUMP_EXIT=$(cat "$PIPE_STATUS_FILE" 2>/dev/null || echo "1")
                rm -f "$PIPE_STATUS_FILE"
            fi

            # Check mysqldump exit code
            if [ "$MYSQLDUMP_EXIT" != "0" ]; then
                MYSQLDUMP_ERR=$(cat /tmp/mysqldump_stderr_${CURRENT_DATABASE}.log 2>/dev/null)
                echo -e "Database backup FAILED for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). mysqldump error: $MYSQLDUMP_ERR" | tee -a /tmp/kubernetes-cloud-mysql-backup.log
                has_failed=true
                # Delete the partial/corrupt blob if it was uploaded
                az storage blob delete --container-name "$AZURE_CONTAINER_NAME" --name "$AZURE_BLOB_PATH" 2>/dev/null || true
                continue
            fi

            # Check upload exit code
            if [ "$AZ_EXIT" != "0" ]; then
                AZ_ERR=$(cat /tmp/az_stderr_${CURRENT_DATABASE}.log 2>/dev/null)
                echo -e "Database backup upload FAILED for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). Azure error: $AZ_ERR" | tee -a /tmp/kubernetes-cloud-mysql-backup.log
                has_failed=true
                continue
            fi

            echo -e "Database backup successfully streamed and uploaded for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S')."

        # ---- AWS: Stream mysqldump | gzip | aws s3 cp ----
        elif [ "$BACKUP_PROVIDER" = "aws" ]; then

            # If the AWS_S3_ENDPOINT variable isn't empty, then populate the --endpoint-url parameter
            if [ ! -z "$AWS_S3_ENDPOINT" ]; then
                ENDPOINT="--endpoint-url=$AWS_S3_ENDPOINT"
            fi

            S3_PATH="s3://$AWS_BUCKET_NAME$AWS_BUCKET_BACKUP_PATH/$DUMP_NAME"

            if [ "$BACKUP_COMPRESS" = "true" ]; then
                PIPE_STATUS_FILE=$(mktemp)
                (mysqldump $MYSQL_AUTH_OPTS -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST \
                    -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT \
                    $BACKUP_ADDITIONAL_PARAMS $BACKUP_CREATE_DATABASE_STATEMENT \
                    $CURRENT_DATABASE 2>/tmp/mysqldump_stderr_${CURRENT_DATABASE}.log; \
                    echo $? > "$PIPE_STATUS_FILE") | \
                    gzip -${BACKUP_COMPRESS_LEVEL} | \
                    aws $ENDPOINT s3 cp - "$S3_PATH" \
                        2>/tmp/aws_stderr_${CURRENT_DATABASE}.log

                AWS_EXIT=$?
                MYSQLDUMP_EXIT=$(cat "$PIPE_STATUS_FILE" 2>/dev/null || echo "1")
                rm -f "$PIPE_STATUS_FILE"
            else
                PIPE_STATUS_FILE=$(mktemp)
                (mysqldump $MYSQL_AUTH_OPTS -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST \
                    -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT \
                    $BACKUP_ADDITIONAL_PARAMS $BACKUP_CREATE_DATABASE_STATEMENT \
                    $CURRENT_DATABASE 2>/tmp/mysqldump_stderr_${CURRENT_DATABASE}.log; \
                    echo $? > "$PIPE_STATUS_FILE") | \
                    aws $ENDPOINT s3 cp - "$S3_PATH" \
                        2>/tmp/aws_stderr_${CURRENT_DATABASE}.log

                AWS_EXIT=$?
                MYSQLDUMP_EXIT=$(cat "$PIPE_STATUS_FILE" 2>/dev/null || echo "1")
                rm -f "$PIPE_STATUS_FILE"
            fi

            if [ "$MYSQLDUMP_EXIT" != "0" ]; then
                MYSQLDUMP_ERR=$(cat /tmp/mysqldump_stderr_${CURRENT_DATABASE}.log 2>/dev/null)
                echo -e "Database backup FAILED for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). mysqldump error: $MYSQLDUMP_ERR" | tee -a /tmp/kubernetes-cloud-mysql-backup.log
                has_failed=true
                aws $ENDPOINT s3 rm "$S3_PATH" 2>/dev/null || true
                continue
            fi

            if [ "$AWS_EXIT" != "0" ]; then
                AWS_ERR=$(cat /tmp/aws_stderr_${CURRENT_DATABASE}.log 2>/dev/null)
                echo -e "Database backup upload FAILED for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). AWS error: $AWS_ERR" | tee -a /tmp/kubernetes-cloud-mysql-backup.log
                has_failed=true
                continue
            fi

            echo -e "Database backup successfully streamed and uploaded for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S')."

        # ---- GCP: Stream mysqldump | gzip | gsutil cp ----
        elif [ "$BACKUP_PROVIDER" = "gcp" ]; then

            GCS_PATH="gs://$GCP_BUCKET_NAME$GCP_BUCKET_BACKUP_PATH/$DUMP_NAME"

            if [ "$BACKUP_COMPRESS" = "true" ]; then
                PIPE_STATUS_FILE=$(mktemp)
                (mysqldump $MYSQL_AUTH_OPTS -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST \
                    -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT \
                    $BACKUP_ADDITIONAL_PARAMS $BACKUP_CREATE_DATABASE_STATEMENT \
                    $CURRENT_DATABASE 2>/tmp/mysqldump_stderr_${CURRENT_DATABASE}.log; \
                    echo $? > "$PIPE_STATUS_FILE") | \
                    gzip -${BACKUP_COMPRESS_LEVEL} | \
                    gsutil cp - "$GCS_PATH" \
                        2>/tmp/gcs_stderr_${CURRENT_DATABASE}.log

                GCS_EXIT=$?
                MYSQLDUMP_EXIT=$(cat "$PIPE_STATUS_FILE" 2>/dev/null || echo "1")
                rm -f "$PIPE_STATUS_FILE"
            else
                PIPE_STATUS_FILE=$(mktemp)
                (mysqldump $MYSQL_AUTH_OPTS -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST \
                    -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT \
                    $BACKUP_ADDITIONAL_PARAMS $BACKUP_CREATE_DATABASE_STATEMENT \
                    $CURRENT_DATABASE 2>/tmp/mysqldump_stderr_${CURRENT_DATABASE}.log; \
                    echo $? > "$PIPE_STATUS_FILE") | \
                    gsutil cp - "$GCS_PATH" \
                        2>/tmp/gcs_stderr_${CURRENT_DATABASE}.log

                GCS_EXIT=$?
                MYSQLDUMP_EXIT=$(cat "$PIPE_STATUS_FILE" 2>/dev/null || echo "1")
                rm -f "$PIPE_STATUS_FILE"
            fi

            if [ "$MYSQLDUMP_EXIT" != "0" ]; then
                MYSQLDUMP_ERR=$(cat /tmp/mysqldump_stderr_${CURRENT_DATABASE}.log 2>/dev/null)
                echo -e "Database backup FAILED for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). mysqldump error: $MYSQLDUMP_ERR" | tee -a /tmp/kubernetes-cloud-mysql-backup.log
                has_failed=true
                gsutil rm "$GCS_PATH" 2>/dev/null || true
                continue
            fi

            if [ "$GCS_EXIT" != "0" ]; then
                GCS_ERR=$(cat /tmp/gcs_stderr_${CURRENT_DATABASE}.log 2>/dev/null)
                echo -e "Database backup upload FAILED for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). GCP error: $GCS_ERR" | tee -a /tmp/kubernetes-cloud-mysql-backup.log
                has_failed=true
                continue
            fi

            echo -e "Database backup successfully streamed and uploaded for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S')."

        else
            echo -e "Unknown BACKUP_PROVIDER: $BACKUP_PROVIDER. Skipping $CURRENT_DATABASE." | tee -a /tmp/kubernetes-cloud-mysql-backup.log
            has_failed=true
        fi

        # Clean up stderr files for this database
        rm -f /tmp/mysqldump_stderr_${CURRENT_DATABASE}.log
        rm -f /tmp/az_stderr_${CURRENT_DATABASE}.log
        rm -f /tmp/aws_stderr_${CURRENT_DATABASE}.log
        rm -f /tmp/gcs_stderr_${CURRENT_DATABASE}.log

    done
fi

# Check if any of the backups have failed. If so, exit with a status of 1. Otherwise exit cleanly with a status of 0.
if [ "$has_failed" = true ]; then

    # Convert SLACK_ENABLED to lowercase before executing if statement
    SLACK_ENABLED=$(echo "$SLACK_ENABLED" | awk '{print tolower($0)}')

    # If Slack alerts are enabled, send a notification alongside a log of what failed
    if [ "$SLACK_ENABLED" = "true" ]; then
        # Put the contents of the database backup logs into a variable
        logcontents=$(cat /tmp/kubernetes-cloud-mysql-backup.log)

        # Send Slack alert
        /slack-alert.sh "One or more backups on database host $TARGET_DATABASE_HOST failed. The error details are included below:" "$logcontents"
    fi

    echo -e "kubernetes-cloud-mysql-backup encountered 1 or more errors. Exiting with status code 1."
    exit 1

else

    # If Slack alerts are enabled, send a notification that all database backups were successful
    if [ "$SLACK_ENABLED" = "true" ]; then
        /slack-alert.sh "All database backups successfully completed on database host $TARGET_DATABASE_HOST."
    fi

    if [ "$MAX_FILES_TO_KEEP" -gt 0 ]; then
        # Delete files when MAX_FILES_TO_KEEP is greater than zero

        deleted_files=0
        if [ "$BACKUP_PROVIDER" = "aws" ]; then
            num_files=$(aws $ENDPOINT s3 ls s3://$AWS_BUCKET_NAME$AWS_BUCKET_BACKUP_PATH/ | wc -l)
            while [ $num_files -gt $MAX_FILES_TO_KEEP ]
            do
                oldest_file=$(aws $ENDPOINT s3 ls s3://$AWS_BUCKET_NAME$AWS_BUCKET_BACKUP_PATH/ | head -n 1 | awk '{print $4}')
                aws $ENDPOINT s3 rm s3://$AWS_BUCKET_NAME$AWS_BUCKET_BACKUP_PATH/$oldest_file
                num_files=$(($num_files - 1))
                deleted_files=$(($deleted_files + 1))
            done
        fi

        if [ "$BACKUP_PROVIDER" = "gcp" ]; then
            num_files=$(gsutil ls gs://$GCP_BUCKET_NAME$GCP_BUCKET_BACKUP_PATH/ | wc -l)
            while [ $num_files -gt $MAX_FILES_TO_KEEP ]
            do
                oldest_file=$(gsutil ls -l gs://$GCP_BUCKET_NAME$GCP_BUCKET_BACKUP_PATH/ | sort -k2,1 | head -n 2 | tail -n 1 | awk '{print $NF}')
                oldest_file=$(basename $oldest_file)
                gsutil rm gs://$GCP_BUCKET_NAME$GCP_BUCKET_BACKUP_PATH/$oldest_file
                num_files=$(($num_files - 1))
                deleted_files=$(($deleted_files + 1))
            done
        fi

        if [ "$BACKUP_PROVIDER" = "azure" ]; then
            # Construct the blob prefix path (remove leading slash if present)
            AZURE_BLOB_PREFIX="${AZURE_BACKUP_PATH#/}"
            if [ ! -z "$AZURE_BLOB_PREFIX" ]; then
                AZURE_BLOB_PREFIX="${AZURE_BLOB_PREFIX}/"
            fi

            # Get list of blobs sorted by creation time
            num_files=$(az storage blob list --container-name "$AZURE_CONTAINER_NAME" --prefix "$AZURE_BLOB_PREFIX" --query "length([])" --output tsv)
            while [ $num_files -gt $MAX_FILES_TO_KEEP ]
            do
                # Get oldest blob by creation time
                oldest_blob=$(az storage blob list --container-name "$AZURE_CONTAINER_NAME" --prefix "$AZURE_BLOB_PREFIX" --query "sort_by([], &properties.creationTime)[0].name" --output tsv)
                az storage blob delete --container-name "$AZURE_CONTAINER_NAME" --name "$oldest_blob"
                num_files=$(($num_files - 1))
                deleted_files=$(($deleted_files + 1))
            done
        fi

        echo -e "Number of deleted files: $deleted_files"
    fi


    exit 0

fi
