#!/usr/bin/env bash
# The verdict of the Build workflow's `gate` job, the one check main and release/** require.
# Reads the `needs` context as JSON in NEEDS, and EVENT and REF (the workflow's event name and ref).
#
# Every job is held to exactly what it should have done, so a job that was skipped when it should have run (because
# something it needs failed, say) fails the gate as well as the job that really failed:
#   - a change that only touches Markdown (changes.code = false): nothing but `changes` runs;
#   - any other change: every job succeeds, except `frontends` (skipped when the repository has no app) and
#     `publish` (it runs only on a push to main with images to publish, and is skipped otherwise).
# Anything not expected, missing, failed or cancelled fails the gate. Prints one line per problem.
set -euo pipefail

: "${NEEDS:?NEEDS is the needs context as JSON}"
: "${EVENT:?EVENT is the workflow event name}"
: "${REF:?REF is the workflow ref}"

problems=0
problem() { echo "gate: $*"; problems=$((problems + 1)); }

result() { jq -r --arg j "$1" 'if has($j) then .[$j].result // "missing" else "missing" end' <<<"$NEEDS"; }
output() { jq -r --arg j "$1" --arg o "$2" '.[$j].outputs[$o] // ""' <<<"$NEEDS"; }

expect() { # job, expected result
    local got
    got="$(result "$1")"
    [ "$got" = "$2" ] || problem "$1 was $got, expected $2"
}

# A job added to the workflow but not to this list (or to gate.needs) would go unchecked: refuse unknown jobs
known="changes boundaries dotnet release-checks action-pins find-frontends frontends find-images publish"
for job in $(jq -r 'keys[]' <<<"$NEEDS"); do
    case " $known " in
        *" $job "*) ;;
        *) problem "$job is in needs but ci-gate.sh doesn't know it" ;;
    esac
done

expect changes success
code="$(output changes code)"
case "$code" in
    true | false) ;;
    *) problem "changes did not say whether code changed (got '$code')"; code=true ;;
esac

if [ "$code" = false ]; then
    for job in boundaries dotnet release-checks action-pins find-frontends frontends find-images publish; do
        expect "$job" skipped
    done
else
    for job in boundaries dotnet release-checks action-pins find-frontends find-images; do
        expect "$job" success
    done

    apps="$(output find-frontends apps)"
    case "$apps" in
        '[]') expect frontends skipped ;;
        *) expect frontends success ;;
    esac

    images="$(output find-images images)"
    if [ "$EVENT" = push ] && [ "$REF" = refs/heads/main ] && [ "$images" != '[]' ]; then
        expect publish success
    else
        expect publish skipped
    fi
fi

if [ "$problems" -gt 0 ]; then
    exit 1
fi
echo "gate: every job did what this change calls for (code changed: $code)"
