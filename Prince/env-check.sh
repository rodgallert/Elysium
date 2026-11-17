#!/bin/sh
# Checks the .env values that otherwise fail quietly, and says which one is wrong and why. It runs as the
# one-shot `env-check` service of docker-compose.yml, which the services using these values wait for.
#
# Prints one line per broken value, naming the variable and the rule, and never the value or its length.
# Exits 1 when any value is broken, 0 otherwise. Variables it doesn't receive count as empty.
#
# POSIX sh (the container is Alpine's busybox ash); tools/tests/env-check.sh runs it without Docker.
set -u
LC_ALL=C
export LC_ALL

failed=0

bad() { # variable, rule
    echo "env-check: $1 $2"
    failed=1
}

# Value of a variable by name, so no check ever puts a value on a command line
value() { eval "printf '%s' \"\${$1:-}\""; }

required() { # variable
    [ -n "$(value "$1")" ] || bad "$1" "is empty or missing (set it in .env, see .env.example)"
}

min_length() { # variable, minimum
    v="$(value "$1")"
    [ -z "$v" ] && return 0 # reported as empty already
    [ "${#v}" -ge "$2" ] || bad "$1" "must be at least $2 characters"
}

for name in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB REVERSE_PROXY_PORT JOBS_ADMIN_EMAIL JOBS_ADMIN_PASSWORD \
    FILE_STORAGE_ROOT_USER FILE_STORAGE_ROOT_PASSWORD FILE_STORAGE_BUCKET; do
    required "$name"
done

# Silo refuses to start with a short root user or password and exits 1, which Compose reports only as
# "dependency failed to start"
min_length FILE_STORAGE_ROOT_USER 3
min_length FILE_STORAGE_ROOT_PASSWORD 8

# Bucket names follow S3's rules: 3 to 63 characters, lower case letters, digits, dots and hyphens
bucket="$(value FILE_STORAGE_BUCKET)"
if [ -n "$bucket" ]; then
    if [ "${#bucket}" -lt 3 ] || [ "${#bucket}" -gt 63 ] || [ -n "$(printf '%s' "$bucket" | tr -d 'a-z0-9.-')" ]; then
        bad FILE_STORAGE_BUCKET "must be 3 to 63 characters: lower case letters, digits, dots and hyphens"
    fi
fi

# The Jobs dashboard's admin is created with ASP.NET Identity's default password policy; when the password
# breaks it the account is never created and the login fails without a log line
jobs="$(value JOBS_ADMIN_PASSWORD)"
if [ -n "$jobs" ]; then
    ok=1
    [ "${#jobs}" -ge 6 ] || ok=0
    [ -n "$(printf '%s' "$jobs" | tr -cd '[:lower:]')" ] || ok=0
    [ -n "$(printf '%s' "$jobs" | tr -cd '[:upper:]')" ] || ok=0
    [ -n "$(printf '%s' "$jobs" | tr -cd '0-9')" ] || ok=0
    [ -n "$(printf '%s' "$jobs" | tr -d 'A-Za-z0-9')" ] || ok=0
    if [ "$ok" -eq 0 ]; then
        bad JOBS_ADMIN_PASSWORD "must be at least 6 characters with an uppercase letter, a lowercase letter, a digit and a symbol"
    fi
fi

if [ "$failed" -eq 0 ]; then
    echo "env-check: OK, the .env values meet the rules"
fi
exit "$failed"
