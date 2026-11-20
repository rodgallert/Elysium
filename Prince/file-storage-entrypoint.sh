#!/bin/sh
# Entrypoint of the `file-storage` service (Silo): starts the server, then creates the bucket (idempotently) with the
# image's own client. The service's health check also asks for the bucket, so file-storage is healthy only once it exists
# and nothing has to start, run and exit after it.
#
# The credentials reach mcli through the environment (MC_HOST_local), never as an argument, so they are not in a process
# list; mcli's own output is not shown (it can echo the endpoint). A failed creation is retried every 2 s and logged as one
# line without the cause's details; until it works the health check keeps the service unhealthy.
# Usage: file-storage-entrypoint.sh <arguments of the Silo image's entrypoint, e.g. server /data ...>
# Limit: the credentials sit in a URL, so a user name or password with @ / : % ? # would need percent-encoding.

/usr/bin/docker-entrypoint.sh "$@" &
server=$!
trap 'kill -TERM "$server" 2>/dev/null' TERM INT

MC_HOST_local="http://$FILE_STORAGE_ROOT_USER:$FILE_STORAGE_ROOT_PASSWORD@127.0.0.1:9000"
export MC_HOST_local

(
    failures=0
    until mcli mb --ignore-existing "local/$FILE_STORAGE_BUCKET" >/dev/null 2>&1; do
        kill -0 "$server" 2>/dev/null || exit 0
        failures=$((failures + 1))
        # the first tries fail while the server starts; say so only when it goes on
        [ "$failures" -eq 15 ] && echo "file-storage: creating the bucket still fails after 30 s; retrying (the service stays unhealthy until it works)"
        sleep 2
    done
) &

wait "$server"
status=$?
# a TERM interrupts the first wait: wait again for the server to finish, then report its status
wait "$server" 2>/dev/null
exit "$status"
