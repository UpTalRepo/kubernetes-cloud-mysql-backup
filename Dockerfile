FROM alpine:3.15.0

RUN apk -v --update add \
    python3 \
    py-pip \
    mysql-client \
    curl \
    bash \
    coreutils \
    gzip && \
    pip3 install --upgrade azure-cli && \
    rm /var/cache/apk/*

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
CMD ["sh", "/perform-backup.sh"]
