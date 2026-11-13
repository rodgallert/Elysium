#!/usr/bin/env bash
# Saves every board item's value for one field, and checks them again later, so a change to that field's
# options (adding, renaming or removing one) can't silently clear values. Run "save" before the change and
# "check" after it.
# Usage: tools/board-field.sh save <field name> <file>
#        tools/board-field.sh check <field name> <file>
# Needs gh logged in as the repo owner with the "project" scope, and jq.
set -euo pipefail

owner="rodgallert"
title="Elysium"

# gh stays logged in as another account for other repos, so use the Elysium owner's token without switching
if [ -z "${GH_TOKEN:-}" ]; then
    GH_TOKEN=$(gh auth token --user "$owner" 2>/dev/null) || { echo "gh has no login for $owner: gh auth login --skip-ssh-key -s project" >&2; exit 1; }
    export GH_TOKEN
fi

command -v jq >/dev/null || { echo "board-field.sh needs jq" >&2; exit 1; }
if [ $# -ne 3 ] || { [ "$1" != save ] && [ "$1" != check ]; }; then
    echo "Usage: $0 save|check <field name> <file>" >&2
    exit 2
fi
mode="$1"
field="$2"
file="$3"

number=$(gh project list --owner "$owner" --format json --jq ".projects[] | select(.title == \"$title\") | .number")
if [ -z "$number" ] || [ "$(wc -l <<<"$number")" -ne 1 ]; then
    echo "Expected exactly one project board titled \"$title\" for $owner" >&2
    exit 1
fi
# Read the list first, so a failed gh call stops here with its own error instead of reading as "no such field"
fields=$(gh project field-list "$number" --owner "$owner" --format json --jq '.fields[].name')
if ! grep -qxF "$field" <<<"$fields"; then
    echo "The \"$title\" board has no field named \"$field\"" >&2
    exit 1
fi

# Item fields come back keyed by the field name in lower case; an item without a value has no key
key=$(tr '[:upper:]' '[:lower:]' <<<"$field")
current=$(gh project item-list "$number" --owner "$owner" --format json --limit 10000 \
    | jq --arg k "$key" '[.items[] | {id, title, value: (.[$k] // null)}] | sort_by(.id)')

if [ "$mode" = save ]; then
    # Never replace a snapshot: a second save after the change would overwrite the good values with cleared ones
    if [ -e "$file" ]; then
        echo "$file already exists: check against it, or remove it first if it's from an earlier change" >&2
        exit 1
    fi
    printf '%s\n' "$current" >"$file"
    echo "Saved \"$field\" for $(jq length <<<"$current") items ($(jq '[.[] | select(.value != null)] | length' <<<"$current") with a value) to $file"
    exit 0
fi

[ -f "$file" ] || { echo "No saved values at $file: run \"$0 save\" first" >&2; exit 1; }
changed=$(jq -n --argjson before "$(cat "$file")" --argjson after "$current" '
    ($after | map({(.id): .value}) | add // {}) as $now
    | [$before[] | select(.value != null) | select($now[.id] != .value)
       | "\(.title): \(.value) -> \($now[.id] // "no value")"]')
if [ "$(jq length <<<"$changed")" -eq 0 ]; then
    echo "\"$field\" unchanged on every item that had a value"
    exit 0
fi
echo "\"$field\" changed on $(jq length <<<"$changed") items:" >&2
jq -r '.[]' <<<"$changed" >&2
exit 1
