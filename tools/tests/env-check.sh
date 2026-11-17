#!/usr/bin/env bash
# Tests for Prince/env-check.sh, the script of the `env-check` Compose service. It needs no Docker: the script runs
# with `sh` and the values it checks in its environment (an empty environment, so nothing leaks in from the caller).
# Usage: tools/tests/env-check.sh
# With ENV_CHECK_IMAGE=<image> the script runs in that image (no network, as the compose service does) instead of the
# local sh, to test it under the shell the container really has (busybox ash in alpine).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/Prince/env-check.sh"
pass=0
failed=0

# The values of Prince/.env.example, as the starting point of every case
valid=(
    POSTGRES_USER=prince POSTGRES_PASSWORD=changeme POSTGRES_DB=prince REVERSE_PROXY_PORT=8080
    JOBS_ADMIN_EMAIL=admin@prince.local 'JOBS_ADMIN_PASSWORD=ChangeMe123!'
    FILE_STORAGE_ROOT_USER=prince-admin 'FILE_STORAGE_ROOT_PASSWORD=ChangeMe123!' FILE_STORAGE_BUCKET=product-files
)

run() { # variable=value overrides... ; sets $out and $rc; an override without a value leaves the variable unset
    local -a vars=()
    local item name override
    for item in "${valid[@]}"; do
        name="${item%%=*}"
        for override in "$@"; do
            [ "${override%%=*}" = "$name" ] && continue 2
        done
        vars+=("$item")
    done
    for override in "$@"; do
        case "$override" in *=*) vars+=("$override") ;; esac
    done
    if [ -n "${ENV_CHECK_IMAGE:-}" ]; then
        local -a envs=()
        for item in "${vars[@]}"; do envs+=(-e "$item"); done
        out="$(docker run --rm --network none --read-only --user 65534:65534 "${envs[@]}" -v "$script":/env-check.sh:ro \
            "$ENV_CHECK_IMAGE" sh /env-check.sh 2>&1)"
    else
        out="$(env -i PATH="$PATH" "${vars[@]}" sh "$script" 2>&1)"
    fi
    rc=$?
}

# fails <name> <variable> <override>...: exit 1, one line naming the variable, no other variable named
fails() {
    local name="$1" variable="$2"
    shift 2
    run "$@"
    if [ "$rc" -eq 1 ] && [ "$(grep -c '^env-check: ' <<<"$out")" -eq 1 ] && grep -q "^env-check: $variable " <<<"$out"; then
        pass=$((pass + 1))
    else
        failed=$((failed + 1))
        echo "FAIL: $name (expected exit 1 naming only $variable, got exit $rc)"
        printf '%s\n' "    ${out//$'\n'/$'\n    '}"
    fi
}

# passes <name> <override>...: exit 0 and the OK line
passes() {
    local name="$1"
    shift
    run "$@"
    if [ "$rc" -eq 0 ] && grep -q '^env-check: OK' <<<"$out"; then
        pass=$((pass + 1))
    else
        failed=$((failed + 1))
        echo "FAIL: $name (expected exit 0, got exit $rc)"
        printf '%s\n' "    ${out//$'\n'/$'\n    '}"
    fi
}

passes "the example values pass"

# Silo's rules
passes "Silo password of exactly 8 characters" FILE_STORAGE_ROOT_PASSWORD=12345678
fails "Silo password of 7 characters" FILE_STORAGE_ROOT_PASSWORD FILE_STORAGE_ROOT_PASSWORD=1234567
fails "empty Silo password" FILE_STORAGE_ROOT_PASSWORD FILE_STORAGE_ROOT_PASSWORD=
fails "missing Silo password" FILE_STORAGE_ROOT_PASSWORD FILE_STORAGE_ROOT_PASSWORD
passes "Silo user of exactly 3 characters" FILE_STORAGE_ROOT_USER=abc
fails "Silo user of 2 characters" FILE_STORAGE_ROOT_USER FILE_STORAGE_ROOT_USER=ab
fails "empty Silo user" FILE_STORAGE_ROOT_USER FILE_STORAGE_ROOT_USER=

# Silo's bucket
passes "bucket of 3 characters" FILE_STORAGE_BUCKET=a-1
fails "bucket of 2 characters" FILE_STORAGE_BUCKET FILE_STORAGE_BUCKET=ab
fails "bucket of 64 characters" FILE_STORAGE_BUCKET "FILE_STORAGE_BUCKET=$(printf 'a%.0s' {1..64})"
fails "bucket with an upper case letter" FILE_STORAGE_BUCKET FILE_STORAGE_BUCKET=Product-files
fails "bucket with an underscore" FILE_STORAGE_BUCKET FILE_STORAGE_BUCKET=product_files
fails "bucket starting with a hyphen" FILE_STORAGE_BUCKET FILE_STORAGE_BUCKET=-abc
fails "bucket ending with a hyphen" FILE_STORAGE_BUCKET FILE_STORAGE_BUCKET=abc-
fails "bucket starting with a dot" FILE_STORAGE_BUCKET FILE_STORAGE_BUCKET=.abc
fails "bucket with two dots in a row" FILE_STORAGE_BUCKET FILE_STORAGE_BUCKET=a..b
fails "bucket written like an IP address" FILE_STORAGE_BUCKET FILE_STORAGE_BUCKET=192.168.1.1
passes "bucket with dots and hyphens" FILE_STORAGE_BUCKET=my-files.v1
fails "empty bucket" FILE_STORAGE_BUCKET FILE_STORAGE_BUCKET=

# The Jobs admin password: ASP.NET Identity's default policy
passes "Jobs password of exactly 6 characters meeting the policy" JOBS_ADMIN_PASSWORD=Ab1!cd
fails "Jobs password of 5 characters" JOBS_ADMIN_PASSWORD JOBS_ADMIN_PASSWORD=Ab1!c
fails "Jobs password without an uppercase letter" JOBS_ADMIN_PASSWORD JOBS_ADMIN_PASSWORD=changeme123!
fails "Jobs password without a lowercase letter" JOBS_ADMIN_PASSWORD JOBS_ADMIN_PASSWORD=CHANGEME123!
fails "Jobs password without a digit" JOBS_ADMIN_PASSWORD JOBS_ADMIN_PASSWORD=ChangeMeNow!
fails "Jobs password without a symbol" JOBS_ADMIN_PASSWORD JOBS_ADMIN_PASSWORD=ChangeMe123
fails "empty Jobs password" JOBS_ADMIN_PASSWORD JOBS_ADMIN_PASSWORD=
fails "missing Jobs password" JOBS_ADMIN_PASSWORD JOBS_ADMIN_PASSWORD
passes "Jobs password with a space as the symbol" 'JOBS_ADMIN_PASSWORD=Change Me1'
passes "Jobs password with characters the shell treats specially" 'JOBS_ADMIN_PASSWORD=A1b$`"\*'"'"'-x'
# Identity counts UTF-16 code units and takes only ASCII letters and digits as such, so other letters are symbols
passes "Jobs password with an accented letter as the symbol" 'JOBS_ADMIN_PASSWORD=Abcdef1é'
fails "Jobs password of 5 characters, one of them two bytes long" JOBS_ADMIN_PASSWORD 'JOBS_ADMIN_PASSWORD=Ab1!é'
fails "Jobs password with an accented capital as its only capital" JOBS_ADMIN_PASSWORD 'JOBS_ADMIN_PASSWORD=Ébcde1!'
passes "Jobs password with a character outside the BMP as the symbol (2 units)" 'JOBS_ADMIN_PASSWORD=Abc1😀'
fails "Jobs password of 5 units with a symbol outside the BMP" JOBS_ADMIN_PASSWORD 'JOBS_ADMIN_PASSWORD=Ab😀1'

# The Jobs email is the Identity user name
passes "Jobs email with every allowed character" 'JOBS_ADMIN_EMAIL=a.B-c_d+1@prince.local'
fails "Jobs email with an apostrophe" JOBS_ADMIN_EMAIL "JOBS_ADMIN_EMAIL=o'brien@prince.local"
fails "Jobs email with a space" JOBS_ADMIN_EMAIL 'JOBS_ADMIN_EMAIL=a b@prince.local'
fails "Jobs email with an accented letter" JOBS_ADMIN_EMAIL 'JOBS_ADMIN_EMAIL=é@prince.local'

# A semicolon splits the connection strings
for variable in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB; do
    fails "$variable with a semicolon" "$variable" "$variable=a;b"
done
passes "Postgres password with other special characters" 'POSTGRES_PASSWORD=a b$`"\*'"'"'='

# The other values only need to be set
for variable in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB REVERSE_PROXY_PORT JOBS_ADMIN_EMAIL; do
    fails "empty $variable" "$variable" "$variable="
    fails "missing $variable" "$variable" "$variable"
done

# Every broken value is reported, one line each
run FILE_STORAGE_ROOT_PASSWORD=short JOBS_ADMIN_PASSWORD=nosymbol1 FILE_STORAGE_ROOT_USER=ab
if [ "$rc" -eq 1 ] && [ "$(grep -c '^env-check: ' <<<"$out")" -eq 3 ]; then
    pass=$((pass + 1))
else
    failed=$((failed + 1))
    echo "FAIL: three broken values give three lines (got exit $rc)"
    printf '%s\n' "    ${out//$'\n'/$'\n    '}"
fi

# A value never shows up in the output: not in the failing lines, not in the OK line, and neither does its length
secret_runs=(
    "FILE_STORAGE_ROOT_PASSWORD=Sh0rt!x"
    "JOBS_ADMIN_PASSWORD=Nosymbol9ZZ"
    "FILE_STORAGE_ROOT_USER=zq"
    "FILE_STORAGE_BUCKET=BadBucketValue"
)
for item in "${secret_runs[@]}"; do
    run "$item" POSTGRES_PASSWORD=PostgresSecretZZ
    value="${item#*=}"
    if [ "$rc" -eq 1 ] && ! grep -qF -e "$value" -e "PostgresSecretZZ" <<<"$out"; then
        pass=$((pass + 1))
    else
        failed=$((failed + 1))
        echo "FAIL: ${item%%=*} is broken, but its value must not appear in the output (exit $rc)"
        printf '%s\n' "    ${out//$'\n'/$'\n    '}"
    fi
done
run POSTGRES_PASSWORD=PostgresSecretZZ JOBS_ADMIN_PASSWORD=ValidSecret9!ZZ FILE_STORAGE_ROOT_PASSWORD=ValidSecret9!QQ
if [ "$rc" -eq 0 ] && ! grep -qE 'PostgresSecretZZ|ValidSecret9' <<<"$out" && ! grep -q '[0-9]\+ char' <<<"$out"; then
    pass=$((pass + 1))
else
    failed=$((failed + 1))
    echo "FAIL: the OK output must not contain a value (exit $rc)"
    printf '%s\n' "    ${out//$'\n'/$'\n    '}"
fi

# The compose file passes the script exactly the variables it checks, and gives it no network
compose_vars="$(awk '/^  env-check:/{f=1;next} f&&/^  [a-z]/{f=0} f' "$root/Prince/docker-compose.yml" | sed -n 's/^      \([A-Z_]*\): \${.*/\1/p' | sort | tr '\n' ' ')"
script_vars="$(printf '%s\n' "${valid[@]%%=*}" | sort | tr '\n' ' ')"
if [ "$compose_vars" = "$script_vars" ]; then
    pass=$((pass + 1))
else
    failed=$((failed + 1))
    echo "FAIL: env-check's environment in docker-compose.yml differs from the variables the tests know"
    echo "    compose: $compose_vars"
    echo "    tests:   $script_vars"
fi

# The Postgres healthcheck reads the user and database from the container's environment, quoted, so a space or a
# shell character in a value can't break or add to the command
health="$(grep 'pg_isready' "$root/Prince/docker-compose.yml")"
if [ "$(wc -l <<<"$health")" -eq 1 ] && grep -qF -- '-U \"$$POSTGRES_USER\" -d \"$$POSTGRES_DB\"' <<<"$health"; then
    pass=$((pass + 1))
else
    failed=$((failed + 1))
    echo "FAIL: the Postgres healthcheck must use \"\$\$POSTGRES_USER\" and \"\$\$POSTGRES_DB\" (quoted, from the container)"
    echo "    $health"
fi

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
