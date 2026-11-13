#!/usr/bin/env bash
# Moves an issue to a column of the Elysium project board, adding it to the board first if needed.
# Usage: tools/board.sh <issue number> <Backlog|Ready|In progress|In review|Ready to Merge|Done>
# Needs gh logged in as the repo owner with the "project" scope (gh auth login --skip-ssh-key -s project), and jq.
set -euo pipefail

command -v jq >/dev/null || { echo "board.sh needs jq" >&2; exit 1; }

owner="rodgallert"
repo="rodgallert/Elysium"
title="Elysium"

# gh stays logged in as another account for other repos, so use the Elysium owner's token without switching
if [ -z "${GH_TOKEN:-}" ]; then
    GH_TOKEN=$(gh auth token --user "$owner" 2>/dev/null) || { echo "gh has no login for $owner: gh auth login --skip-ssh-key -s project" >&2; exit 1; }
    export GH_TOKEN
fi

if [ $# -ne 2 ]; then
    echo "Usage: $0 <issue number> <Backlog|Ready|In progress|In review|Ready to Merge|Done>" >&2
    exit 2
fi
issue="$1"
status="$2"

number=$(gh project list --owner "$owner" --format json --jq ".projects[] | select(.title == \"$title\") | .number")
if [ -z "$number" ]; then
    echo "No project board titled \"$title\" for $owner" >&2
    exit 1
fi
if [ "$(wc -l <<<"$number")" -ne 1 ]; then
    echo "More than one project board is titled \"$title\" for $owner (numbers: $(tr '\n' ' ' <<<"$number"))" >&2
    exit 1
fi
project_id=$(gh project view "$number" --owner "$owner" --format json --jq .id)

field=$(gh project field-list "$number" --owner "$owner" --format json --jq '.fields[] | select(.name == "Status")')
if [ -z "$field" ]; then
    echo "The \"$title\" board has no Status field" >&2
    exit 1
fi
field_id=$(jq -r .id <<<"$field")
option_id=$(jq -r --arg s "$status" '.options[] | select(.name == $s) | .id' <<<"$field")
if [ -z "$option_id" ]; then
    echo "Unknown status \"$status\". Columns: $(jq -r '[.options[].name] | join(", ")' <<<"$field")" >&2
    exit 1
fi

# item-add returns the existing item when the issue is already on the board
url=$(gh issue view "$issue" -R "$repo" --json url --jq .url)
item_id=$(gh project item-add "$number" --owner "$owner" --url "$url" --format json --jq .id)

gh project item-edit --id "$item_id" --project-id "$project_id" --field-id "$field_id" --single-select-option-id "$option_id" >/dev/null
echo "#$issue → $status"
