#!/usr/bin/env bash
# TEST_FILTER for the suites under tools/tests/ (issue #126). A suite sources this file and gates its cases through it:
#
#   TEST_FILTER='#75-AC3.1' tools/tests/<suite>.sh     runs only the cases whose name or spec id contains the text
#
# The text is matched literally (no regular expression), so `.*`, `[x]` or `?` mean themselves. A spec id (`#<issue>-AC<n>`,
# optionally with `.<m>` parts) must not run into more digits: `#75-AC3.1` selects `#75-AC3.1` and `#75-AC3.1.2`, never
# `#75-AC3.10`. An empty value is the same as an unset one. A run with a filter prints one summary line naming the filter,
# how many cases ran and how many were filtered out, and exits 1 when no case ran, so a mistyped filter never looks like a
# pass. The suites check nothing else: with no filter their behaviour and output are unchanged.
#
# CI never sets a filter (a filtered run proves nothing about the rest): sourcing this file with CI and TEST_FILTER both
# set stops the suite with exit 1, and the gate job fails the same way.
#
# Functions (a case is whatever the suite counts as one check; the suite says how it is named):
#   filter_selected <text>...   0 when no filter is set or the text matches it
#   filter_gate <text>...       like filter_selected, and counts a case that does not match as filtered out
#   filter_site_gate            for a suite whose pass marker `ok` takes no name (the Docker suites, where a case is often
#                               `cond && ok || bad "<id>" "<description>"`): called from inside `ok`, it names the case by the
#                               source of the line that called `ok`, up to the `bad` that follows it, and counts it as
#                               filtered out when the filter is not in that text. Use a spec id with these suites: a
#                               description built at run time is only seen in its unexpanded form here.
#   filter_run <function>       calls a group of cases, unless a filter is set and its text appears nowhere in the group's
#                               source (the group is then counted as not run: its setup is the slow part, so skipping it
#                               is the point). A case name built at run time is only seen when the group runs.
#   filter_precheck <file>...   for suites that need Docker: exits 1 at once when a filter is set that none of the files
#                               contain, before any container starts
#   filter_report <pass> <failed>  prints the summary line; returns 1 when a filter is set and nothing ran

if [ -n "${TEST_FILTER:-}" ] && [ -n "${CI:-}" ]; then
    echo "TEST_FILTER must not be set in CI: a filtered run is not a verdict on the suite" >&2
    exit 1
fi

filter_skipped=0
filter_groups=0

filter_selected() {
    [ -z "${TEST_FILTER:-}" ] && return 0
    local text="$*" re
    if [[ "$TEST_FILTER" =~ ^#[0-9]+-AC[0-9]+(\.[0-9]+)*$ ]]; then
        re="${TEST_FILTER//./\\.}([^0-9]|\$)"
        [[ "$text" =~ $re ]]
        return
    fi
    case "$text" in
        *"$TEST_FILTER"*) return 0 ;;
    esac
    return 1
}

filter_gate() {
    filter_selected "$@" && return 0
    filter_skipped=$((filter_skipped + 1))
    return 1
}

filter_site_gate() {
    [ -z "${TEST_FILTER:-}" ] && return 0
    local file="${BASH_SOURCE[2]:-}" line="${BASH_LINENO[1]:-0}" text
    # the call and the lines after it up to the first `bad` (at most 8), or, with no `bad` there, the call and the 3 lines before it
    text="$(awk -v n="$line" 'NR >= n && NR < n + 8 { print; if ($0 ~ /(^|[^[:alnum:]_])bad /) exit }' "$file" 2>/dev/null)"
    if ! grep -qE '(^|[^[:alnum:]_])bad ' <<<"$text"; then
        text="$(awk -v n="$line" 'NR >= n - 3 && NR <= n { print }' "$file" 2>/dev/null)"
    fi
    filter_gate "$text"
}

filter_run() {
    if [ -z "${TEST_FILTER:-}" ] || declare -f "$1" | grep -qF -- "$TEST_FILTER"; then
        "$1"
    else
        filter_groups=$((filter_groups + 1))
    fi
}

filter_precheck() {
    [ -z "${TEST_FILTER:-}" ] && return 0
    local f
    for f in "$@"; do
        grep -qF -- "$TEST_FILTER" "$f" 2>/dev/null && return 0
    done
    echo "filter '$TEST_FILTER': 0 ran, 0 filtered out: no case matches"
    exit 1
}

filter_report() {
    [ -z "${TEST_FILTER:-}" ] && return 0
    local ran=$(($1 + $2)) line
    line="filter '$TEST_FILTER': $ran ran, $filter_skipped filtered out"
    [ "$filter_groups" -eq 0 ] || line+=" ($filter_groups groups not run)"
    if [ "$ran" -eq 0 ]; then
        if [ "$filter_groups" -eq 0 ]; then
            echo "$line: no case matches"
        else
            echo "$line: no case matched in the groups read (a name that is built or extended at run time is seen only in a group that runs)"
        fi
        return 1
    fi
    echo "$line"
}
