#!/usr/bin/env bash
# Fixture tests for the password redaction of Prince/file-storage-entrypoint.sh (#74-AC5.10): a failed bucket creation is
# logged with the password replaced, whatever characters it holds (a bracket or a star is not a pattern). No Docker.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export FILE_STORAGE_ENTRYPOINT_SOURCE_ONLY=1
# shellcheck source=lib/filter.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/filter.sh"
pass=0
failed=0

# redacts <name> <password> <message> <expected>
redacts() {
    local got
    filter_gate "$1" || return 0
    # shellcheck source=/dev/null
    got="$(FILE_STORAGE_ROOT_PASSWORD="$2" bash -c 'source "$1"; redact "$2"' _ "$root/Prince/file-storage-entrypoint.sh" "$3")"
    if [ "$got" = "$4" ]; then pass=$((pass + 1)); else
        failed=$((failed + 1))
        echo "FAIL: $1 (expected \"$4\", got \"$got\")"
    fi
}

redacts "plain password" 'ChangeMe123!' 'bad key ChangeMe123! here' 'bad key *** here'
redacts "bracketed password" 'pa[ab]ss' 'url http://u:pa[ab]ss@host' 'url http://u:***@host'
redacts "a pattern must not match its own look-alike" 'pa[ab]ss' 'paass is not the password' 'paass is not the password'
redacts "star and question mark" 'a*b?c1234' 'x a*b?c1234 y' 'x *** y'
redacts "star does not match everything" 'a*b?c1234' 'axxb1c1234' 'axxb1c1234'
redacts "backslash" 'a\b\c12345' 'x a\b\c12345 y' 'x *** y'
redacts "@ / # % ?" 'ab@cd/12#3%4?x' 'http://u:ab@cd/12#3%4?x@h' 'http://u:***@h'
redacts "twice in one message" 'Secret99!x' 'Secret99!x and Secret99!x' '*** and ***'
redacts "no password in the message" 'Secret99!x' 'connection refused' 'connection refused'

echo "file-storage redaction tests: $pass passed, $failed failed"
filter_report "$pass" "$failed" || exit 1
[ "$failed" -eq 0 ]
