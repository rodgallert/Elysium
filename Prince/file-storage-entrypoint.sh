#!/bin/bash
# Entrypoint of the `file-storage` service (Silo): starts the server, then creates the bucket (idempotently) with the
# image's own client. The service's health check also asks for the bucket, so file-storage is healthy only once it exists
# and no service has to start, run and exit after it.
#
# The credentials reach mcli through the environment (MC_HOST_local), never as an argument, so they are in no command
# line or process list. mcli's message is logged with the password replaced, one line each time the reason changes; the
# creation is retried every 2 s, and until it works the health check keeps the service unhealthy.
# Usage: file-storage-entrypoint.sh <arguments of the Silo image's entrypoint, e.g. server /data ...>
# Limit: the credentials sit in a URL, so a colon in the user name or password breaks every call ("security token
# invalid", also when written as %3A); env-check refuses it. @ / # % ? work as they are; percent-encoding them breaks the login.

# the message with the password replaced (quoted, so [ ] * ? in a password are literal, not a pattern)
redact() { # message
    printf '%s' "${1//"$FILE_STORAGE_ROOT_PASSWORD"/***}"
}
# tools/tests/file-storage-entrypoint.sh sources the file for redact() only
[ "${FILE_STORAGE_ENTRYPOINT_SOURCE_ONLY:-}" = 1 ] && return 0

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
        reason="$(redact "$err")"
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
# A TERM interrupts the first wait (its status is then 143, 128 + 15, and the container exits 143); the trap has passed the
# TERM on, so wait again for the server to finish before leaving. If the server exits by itself, its own status is kept.
wait "$server" 2>/dev/null
exit "$status"
