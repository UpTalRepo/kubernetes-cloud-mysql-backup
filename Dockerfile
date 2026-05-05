FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    default-mysql-client \
    curl \
    bash \
    gzip && \
    pip3 install --break-system-packages azure-storage-blob && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ENV BACKUP_CREATE_DATABASE_STATEMENT=false
ENV TARGET_DATABASE_PORT=3306
ENV SLACK_ENABLED=false
ENV SLACK_USERNAME=kubernetes-cloud-mysql-backup
ENV BACKUP_PROVIDER=azure
ENV MAX_FILES_TO_KEEP=0
ENV MYSQL_AUTH_PLUGIN=caching_sha2_password

COPY resources/slack-alert.sh /
RUN chmod +x /slack-alert.sh

COPY resources/stream-to-azure.py /
RUN chmod +x /stream-to-azure.py

COPY resources/perform-backup.sh /
RUN chmod +x /perform-backup.sh
CMD ["bash", "/perform-backup.sh"]
