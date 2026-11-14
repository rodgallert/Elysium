#!/usr/bin/env bash
# Prints the GitHub Release notes for a release part's version: its section of the part's CHANGELOG.md, the lines
# under "## <version>" or "## [<version>]" up to the next "## " heading. Fails when there is no such section,
# or when it has no "Breaking changes" heading (Docs/workflow.md, Releases).
#
#   release-notes.sh <changelog> <part> <version>          a release: the section must exist
#   release-notes.sh --draft <changelog> <part> <version>  a dry run before the release PR exists: falls back to
#                                                          the "Unreleased" section, then to the subjects of the
#                                                          commits with the service's scope since the part's
#                                                          last release tag
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

draft=false
if [ "${1:-}" = "--draft" ]; then draft=true; shift; fi
usage="usage: release-notes.sh [--draft] <changelog> <part> <version>"
changelog="${1:?$usage}"
part="${2:?$usage}"
version="${3:?$usage}"

section() { # <heading pattern, as an awk regex>
    [ -f "$changelog" ] || return 0
    PATTERN="$1" awk '
        /^## / { if (inside) exit; if ($0 ~ ENVIRON["PATTERN"]) { inside = 1; next } }
        inside { print }
    ' "$changelog"
}

escaped="${version//./\\.}"
notes="$(section "^## \\[?$escaped\\]?([^0-9.]|$)")"

if [ -z "$(tr -d '[:space:]' <<<"$notes")" ]; then
    if ! $draft; then
        echo "$changelog has no section for $version (a '## $version' heading); the release PR adds it" >&2
        exit 1
    fi
    notes="$(section '^## \[?Unreleased\]?')"
    if [ -z "$(tr -d '[:space:]' <<<"$notes")" ]; then
        service="${part%%-*}"
        since="$(git describe --tags --abbrev=0 --match "$part-v*" 2>/dev/null || true)"
        notes="$(printf '_Draft from the commits with the %s scope%s; the release PR writes the changelog section._\n\n' \
            "$service" "${since:+ since $since}")"
        notes+=$'\n\n'
        notes+="$(git log --format='- %s' ${since:+"$since"..HEAD} | grep -E "^- [a-z]+\\($service(-[a-z]+)?\\)!?: " || true)"
        notes+=$'\n\n### Breaking changes\n\nDraft: see the commits marked with "!" above.'
    fi
fi

if ! grep -qiE '^#+ *Breaking changes' <<<"$notes"; then
    echo "$changelog, section $version: no 'Breaking changes' heading (list them, or write 'None')" >&2
    exit 1
fi

# Trim leading and trailing blank lines
sed -e '/./,$!d' <<<"$notes" | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
