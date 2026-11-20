#!/bin/bash
# Entrypoint of the `file-storage` service (Silo): starts the server, then creates the bucket (idempotently) with the
# image's own client. The service's health check also asks for the bucket, so file-storage is healthy only once it exists
# and no service has to start, run and exit after it.
#
# The credentials reach mcli through the environment (MC_HOST_local), never as an argument, so they are in no command
# line or process list. mcli's message is logged with the password replaced, one line each time the reason changes; the
# creation is retried every 2 s, and until it works the health check keeps the service unhealthy.
# Usage: file-storage-entrypoint.sh <arguments of the Silo image's entrypoint, e.g. server /data ...>
# Limit: the credentials sit in a URL, so a user name or password with @ / : % ? # would need percent-encoding.

/usr/bin/docker-entrypoint.sh "$@" &
server=$!
trap 'kill -TERM "$server" 2>/dev/null' TERM INT

MC_HOST_local="http://$FILE_STORAGE_ROOT_USER:$FILE_STORAGE_ROOT_PASSWORD@127.0.0.1:9000"
export MC_HOST_local
bucket="local/$FILE_STORAGE_BUCKET"

(
    last=""
    while kill -0 "$server" 2>/dev/null; do
        if mcli stat "$bucket" >/dev/null 2>&1; then
            echo "file-storage: bucket $FILE_STORAGE_BUCKET already exists"
            exit 0
        fi
        if err="$(mcli mb "$bucket" 2>&1)"; then
            echo "file-storage: bucket $FILE_STORAGE_BUCKET created"
            exit 0
        fi
        reason="${err//$FILE_STORAGE_ROOT_PASSWORD/***}"
        reason="${reason%%$'\n'*}"
        if [ "$reason" != "$last" ]; then
            echo "file-storage: bucket creation failed: $reason"
            last="$reason"
        fi
        sleep 2
    done
) &

wait "$server"
status=$?
# a TERM interrupts the first wait: wait again for the server to finish, then report its status
wait "$server" 2>/dev/null
exit "$status"
