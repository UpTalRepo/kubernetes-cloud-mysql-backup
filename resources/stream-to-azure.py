#!/usr/bin/env python3
"""
Stream stdin to Azure Blob Storage as a block blob.

Usage:
    cat data | python3 stream-to-azure.py <container> <blob_name>

Environment variables:
    AZURE_STORAGE_ACCOUNT  - Storage account name
    AZURE_STORAGE_KEY      - Storage account access key

This uploads stdin in 4MB chunks as block blob blocks, then commits them.
No local disk is used. Handles arbitrarily large streams.
"""

import os
import sys
import base64

def main():
    if len(sys.argv) != 3:
        print("Usage: stream-to-azure.py <container_name> <blob_name>", file=sys.stderr)
        sys.exit(1)

    container_name = sys.argv[1]
    blob_name = sys.argv[2]

    account_name = os.environ.get("AZURE_STORAGE_ACCOUNT")
    account_key = os.environ.get("AZURE_STORAGE_KEY")

    if not account_name or not account_key:
        print("Error: AZURE_STORAGE_ACCOUNT and AZURE_STORAGE_KEY must be set", file=sys.stderr)
        sys.exit(1)

    try:
        from azure.storage.blob import BlobServiceClient
    except ImportError:
        print("Error: azure-storage-blob package not installed", file=sys.stderr)
        sys.exit(1)

    connection_string = (
        f"DefaultEndpointsProtocol=https;"
        f"AccountName={account_name};"
        f"AccountKey={account_key};"
        f"EndpointSuffix=core.windows.net"
    )

    blob_service_client = BlobServiceClient.from_connection_string(connection_string)
    blob_client = blob_service_client.get_blob_client(container=container_name, blob=blob_name)

    # Upload stdin in 4MB chunks as block blob blocks
    BLOCK_SIZE = 4 * 1024 * 1024  # 4 MB per block
    block_list = []
    block_num = 0
    total_bytes = 0

    stdin_buffer = sys.stdin.buffer  # binary mode

    while True:
        data = stdin_buffer.read(BLOCK_SIZE)
        if not data:
            break

        # Generate a block ID (must be consistent length, base64 encoded)
        block_id = base64.b64encode(f"block-{block_num:06d}".encode()).decode()
        blob_client.stage_block(block_id=block_id, data=data, length=len(data))
        block_list.append(block_id)

        total_bytes += len(data)
        block_num += 1

        # Progress indicator (every 100MB)
        if block_num % 25 == 0:
            print(f"  Uploaded {total_bytes / (1024*1024):.0f} MB ({block_num} blocks)...", file=sys.stderr)

    if block_num == 0:
        print("Error: No data received on stdin", file=sys.stderr)
        sys.exit(1)

    # Commit all blocks to form the final blob
    from azure.storage.blob import BlobBlock
    blob_client.commit_block_list([BlobBlock(block_id=bid) for bid in block_list])

    print(f"  Upload complete: {total_bytes / (1024*1024):.1f} MB in {block_num} blocks -> {blob_name}", file=sys.stderr)

if __name__ == "__main__":
    main()
