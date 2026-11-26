#!/usr/bin/env bash
# A small suite on the shared filter library (#126): four cases, one of them failing on purpose.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/filter.sh
source "$here/lib/filter.sh"
pass=0
failed=0
check() { # name, command...
    filter_gate "$1" || return 0
    if "${@:2}"; then pass=$((pass + 1)); else
        failed=$((failed + 1))
        echo "FAIL  $1"
    fi
}
check "#900-AC1 alpha one" true
check "#900-AC1.1 alpha two" true
check "#900-AC2 beta [x] (literal) * ?" true
check "#900-AC3 gamma fails" false
echo "$pass passed, $failed failed"
filter_report "$pass" "$failed" || exit 1
[ "$failed" -eq 0 ]
