#!/usr/bin/env bash
# Prints, as JSON, which release parts (tools/release-parts.sh) a release run handles, and their images:
#   {"parts":[{"part":"prince","service":"prince","folder":"Prince","versionFile":"...","changelog":"...","version":"0.1.0"}],
#    "images":[{"part":"prince","version":"0.1.0","image":"elysium-prince-core-api","context":"...","file":"..."}]}
#
#   release-plan.sh merged <commit>           the parts whose version the commit changed (a squash merge into
#                                             main or a release branch; the checkout must be at that commit).
#                                             A version change is only allowed in a release commit
#                                             ("chore(release): ..." or "chore(release)!: ..."), and a release
#                                             commit must change a version; anything else fails.
#   release-plan.sh changed <base> <head> <subject>
#                                             the same between two commits, with <subject> as the commit's
#                                             subject (a pull request: its merge ref, base and title)
#   release-plan.sh part <name> [<version>]   one part, at <version> or its current version (manual runs)
#   release-plan.sh all                       every part at its version (dry runs of the tooling)
# With --drafts (before the subcommand), a service with images but no version file yet counts as one part named
# after the service, at 0.0.0 or the given version, so dry runs work before a service's first release.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
fail() { echo "$*" >&2; exit 1; }

parts="$(tools/release-parts.sh)"
if [ "${1:-}" = "--drafts" ]; then
    shift
    parts="$(jq -c --argjson images "$(tools/list-images.sh)" '
        . + [($images | map(.file | split("/")[0]) | unique[]) as $folder
             | select(all(.[]; .folder != $folder))
             | {part: ($folder | ascii_downcase), service: ($folder | ascii_downcase), folder: $folder,
                versionFile: null, changelog: ($folder + "/CHANGELOG.md"), version: "0.0.0",
                images: [$images[] | select(.file | startswith($folder + "/"))]}]' <<<"$parts")"
fi

case "${1:-}" in
    merged | changed)
        if [ "$1" = merged ]; then
            head="${2:?usage: release-plan.sh merged <commit>}"
            base="$head^"
            subject="$(git log -1 --format=%s "$head")"
        else
            base="${2:?usage: release-plan.sh changed <base> <head> <subject>}"
            head="${3:?usage: release-plan.sh changed <base> <head> <subject>}"
            subject="${4?usage: release-plan.sh changed <base> <head> <subject>}"
        fi
        release_commit=false
        release_title='^chore\(release\)!?: '
        if [[ "$subject" =~ $release_title ]]; then release_commit=true; fi
        chosen='[]'
        while IFS=$'\t' read -r part file; do
            [ -n "$part" ] || continue
            old="$(tools/release-parts.sh version "$file" "$base")"
            new="$(tools/release-parts.sh version "$file" "$head")"
            [ "$old" != "$new" ] || continue
            chosen="$(jq -c --arg p "$part" --arg v "$new" --argjson parts "$parts" \
                '. + [$parts[] | select(.part == $p) | .version = $v]' <<<"$chosen")"
        done < <(jq -r '.[] | [.part, .versionFile] | @tsv' <<<"$parts")
        released="$(jq -r 'map(.part) | join(", ")' <<<"$chosen")"
        if [ -n "$released" ] && ! $release_commit; then
            fail "'$subject' changes the version of $released but is not a release commit (chore(release): ...)"
        fi
        if [ -z "$released" ] && $release_commit; then
            fail "'$subject' is a release commit but changes no release part's version"
        fi
        ;;
    part)
        name="${2:?usage: release-plan.sh part <name> [<version>]}"
        chosen="$(jq -c --arg p "$name" --arg v "${3:-}" \
            '[.[] | select(.part == $p) | if $v != "" then .version = $v else . end]' <<<"$parts")"
        [ "$(jq length <<<"$chosen")" -eq 1 ] ||
            fail "No release part '$name' (parts: $(jq -r 'map(.part) | join(", ")' <<<"$parts"); a service without a version file has none)"
        ;;
    all)
        chosen="$(jq -c 'map(if .version == "" then .version = "0.0.0" else . end)' <<<"$parts")"
        ;;
    *)
        fail "usage: release-plan.sh merged <commit> | changed <base> <head> <subject> | part <name> [<version>] | all"
        ;;
esac

while IFS=$'\t' read -r part version; do
    [[ "$version" =~ $semver ]] || fail "$part: version '$version' is not x.y.z"
done < <(jq -r '.[] | [.part, .version] | @tsv' <<<"$chosen")

jq -c '{parts: map(del(.images)), images: [.[] as $p | $p.images[] | {part: $p.part, version: $p.version} + .]}' <<<"$chosen"
