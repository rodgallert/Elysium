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

# The bucket creation hands the Silo credentials to mcli in a URL (MC_HOST_local, user:password@host): a colon splits user
# from password, so every call fails with "security token invalid" (measured on the pinned image, also when written as
# %3A). @ / # % ? work as they are.
for name in FILE_STORAGE_ROOT_USER FILE_STORAGE_ROOT_PASSWORD; do
    case "$(value "$name")" in
    *":"*) bad "$name" "must not contain a colon (the bucket creation passes it in a URL)" ;;
    esac
done

# Postgres values go into Npgsql connection strings (Key=Value;Key=Value), where a semicolon ends the value
for name in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB; do
    case "$(value "$name")" in
    *";"*) bad "$name" "must not contain a semicolon (the connection strings are semicolon separated)" ;;
    esac
done

# Bucket names follow S3's rules: 3 to 63 characters of lower case letters, digits, dots and hyphens; they start
# and end with a letter or digit, have no two dots in a row and aren't written like an IP address
bucket="$(value FILE_STORAGE_BUCKET)"
if [ -n "$bucket" ]; then
    ok=1
    [ "${#bucket}" -ge 3 ] && [ "${#bucket}" -le 63 ] || ok=0
    [ -z "$(printf '%s' "$bucket" | tr -d 'a-z0-9.-')" ] || ok=0
    case "$bucket" in
    [!a-z0-9]* | *[!a-z0-9] | *..*) ok=0 ;;
    esac
    if [ -z "$(printf '%s' "$bucket" | tr -d '0-9.')" ]; then
        case "$bucket" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) ok=0 ;;
        esac
    fi
    [ "$ok" -eq 1 ] || bad FILE_STORAGE_BUCKET "must follow S3 bucket names: 3 to 63 lower case letters, digits, dots and hyphens, starting and ending with a letter or digit, no two dots in a row, not an IP address"
fi

# The Jobs admin's email is its Identity user name, which allows only letters, digits and - . _ @ +
email="$(value JOBS_ADMIN_EMAIL)"
if [ -n "$email" ] && [ -n "$(printf '%s' "$email" | tr -d 'a-zA-Z0-9._@+-')" ]; then
    bad JOBS_ADMIN_EMAIL "may only contain ASCII letters, digits and the characters - . _ @ +"
fi

# The Jobs dashboard's admin is created with ASP.NET Identity's default password policy; when the password
# breaks it the account is never created and the login fails without a log line. Identity counts UTF-16 code
# units (a character outside the BMP counts twice) and takes only ASCII letters and digits as such, so any
# other character, accented letters included, is the symbol. The length counts UTF-8 bytes that aren't
# continuation bytes, plus one more for each 4-byte lead byte.
jobs="$(value JOBS_ADMIN_PASSWORD)"
if [ -n "$jobs" ]; then
    ok=1
    units=$(($(printf '%s' "$jobs" | tr -d '\200-\277' | wc -c) + $(printf '%s' "$jobs" | tr -cd '\360-\364' | wc -c)))
    [ "$units" -ge 6 ] || ok=0
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
