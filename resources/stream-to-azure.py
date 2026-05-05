#!/usr/bin/env python3
"""
Azure Blob Storage helpers for the backup script.

Commands:
    stream <container> <blob_name>          Stream stdin to a block blob
    delete <container> <blob_name>          Delete a blob
    count  <container> <prefix>             Count blobs with prefix
    oldest <container> <prefix>             Print name of oldest blob with prefix

Environment variables:
    AZURE_STORAGE_ACCOUNT  - Storage account name
    AZURE_STORAGE_KEY      - Storage account access key
"""

import os
import sys
import base64


def get_client():
    account_name = os.environ.get("AZURE_STORAGE_ACCOUNT")
    account_key = os.environ.get("AZURE_STORAGE_KEY")
    if not account_name or not account_key:
        print("Error: AZURE_STORAGE_ACCOUNT and AZURE_STORAGE_KEY must be set", file=sys.stderr)
        sys.exit(1)
    from azure.storage.blob import BlobServiceClient
    conn = (
        f"DefaultEndpointsProtocol=https;"
        f"AccountName={account_name};"
        f"AccountKey={account_key};"
        f"EndpointSuffix=core.windows.net"
    )
    return BlobServiceClient.from_connection_string(conn)


def cmd_stream(container, blob_name):
    client = get_client().get_blob_client(container=container, blob=blob_name)
    from azure.storage.blob import BlobBlock
    BLOCK_SIZE = 4 * 1024 * 1024
    block_list = []
    block_num = 0
    total_bytes = 0
    buf = sys.stdin.buffer
    while True:
        data = buf.read(BLOCK_SIZE)
        if not data:
            break
        block_id = base64.b64encode(f"block-{block_num:06d}".encode()).decode()
        client.stage_block(block_id=block_id, data=data, length=len(data))
        block_list.append(block_id)
        total_bytes += len(data)
        block_num += 1
        if block_num % 25 == 0:
            print(f"  Uploaded {total_bytes / (1024*1024):.0f} MB ({block_num} blocks)...", file=sys.stderr)
    if block_num == 0:
        print("Error: No data received on stdin", file=sys.stderr)
        sys.exit(1)
    client.commit_block_list([BlobBlock(block_id=bid) for bid in block_list])
    print(f"  Upload complete: {total_bytes / (1024*1024):.1f} MB in {block_num} blocks -> {blob_name}", file=sys.stderr)


def cmd_delete(container, blob_name):
    client = get_client().get_blob_client(container=container, blob=blob_name)
    client.delete_blob()


def cmd_count(container, prefix):
    container_client = get_client().get_container_client(container)
    count = sum(1 for _ in container_client.list_blobs(name_starts_with=prefix))
    print(count)


def cmd_oldest(container, prefix):
    container_client = get_client().get_container_client(container)
    oldest = None
    for blob in container_client.list_blobs(name_starts_with=prefix):
        if oldest is None or blob.creation_time < oldest.creation_time:
            oldest = blob
    if oldest:
        print(oldest.name)
    else:
        sys.exit(1)


def main():
    if len(sys.argv) < 2:
        print("Usage: stream-to-azure.py <command> [args...]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "stream" and len(sys.argv) == 4:
        cmd_stream(sys.argv[2], sys.argv[3])
    elif cmd == "delete" and len(sys.argv) == 4:
        cmd_delete(sys.argv[2], sys.argv[3])
    elif cmd == "count" and len(sys.argv) == 4:
        cmd_count(sys.argv[2], sys.argv[3])
    elif cmd == "oldest" and len(sys.argv) == 4:
        cmd_oldest(sys.argv[2], sys.argv[3])
    else:
        print(f"Unknown command or wrong args: {sys.argv[1:]}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
