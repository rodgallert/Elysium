#!/usr/bin/env bash
# Checks the `image:` names in Compose files against what the repository publishes (#74):
#   - an image of ours (ghcr.io/rodgallert/elysium-...) must be one tools/list-images.sh publishes,
#     elysium-<service folder>-<service>, lower case, and carry a tag or a digest;
#   - a service with both `build` and `image` must name the image its build publishes;
#   - any other image needs a tag or a digest (no implicit :latest), a valid tag (at most 128 characters) and a
#     lower case repository name; no ${VAR} (the check runs without a .env), no whitespace, never empty.
# Usage: tools/check-compose-images.sh [docker-compose.yml ...]   (no argument: every docker-compose.yml of the repository)
# Every failure is one line, "<file>: <service>: <reason>", and the exit is non-zero; a file `docker compose config`
# rejects is reported the same way (service "<config>") and never counted as fine.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
registry="ghcr.io/rodgallert"
status=0
all_mode=0

fail() { # file service reason
    printf '%s: %s: %s\n' "$1" "$2" "$3"
    status=1
}

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
    all_mode=1
    cd "$root" || exit 1
    while IFS= read -r f; do files+=("${f#./}"); done < <(find . -name docker-compose.yml -not -path '*/node_modules/*' -not -path './.claude/*' -not -path './.git/*' | sort)
fi

# Pass 1: read every file. --no-interpolate like list-images.sh: no .env is needed.
declare -A config=()
declare -A published=()
for f in "${files[@]}"; do
    if ! out="$(docker compose -f "$f" config --no-interpolate --format json 2>&1)"; then
        fail "$f" "<config>" "docker compose config failed: $(head -1 <<<"$out")"
        continue
    fi
    config[$f]="$out"
    folder="$(basename "$(dirname "$(realpath "$f")")" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r s; do
        published["$registry/elysium-$folder-$(tr '[:upper:]' '[:lower:]' <<<"$s")"]=1
    done < <(jq -r '.services | to_entries[] | select(.value.build) | .key' <<<"$out")
done

# In the repository's own run, the names derived here are the ones the publish job builds
if [ "$all_mode" -eq 1 ]; then
    if listed="$("$root/tools/list-images.sh" 2>&1)"; then
        want="$(jq -r '.[].image' <<<"$listed" | sed "s#^#$registry/#" | sort)"
        have="$(printf '%s\n' "${!published[@]}" | sort)"
        [ "$want" = "$have" ] || fail "tools/list-images.sh" "<published>" "publishes different names than the Compose files give: $(diff <(echo "$want") <(echo "$have") | grep '^[<>]' | tr '\n' ' ')"
    else
        fail "tools/list-images.sh" "<published>" "failed: $(head -1 <<<"$listed")"
    fi
fi

# one reference: prints the reason it is wrong, nothing when it is fine
ref_problem() {
    local ref="$1" name digest="" last tag="" repo host
    [ -n "$ref" ] || { echo "empty image"; return; }
    case "$ref" in *[[:space:]]*) echo "a space in the image name"; return ;; esac
    case "$ref" in *'$'*) echo "a variable in the image name (the check runs without a .env)"; return ;; esac
    name="$ref"
    if [[ "$ref" == *@* ]]; then
        name="${ref%%@*}"
        digest="${ref#*@}"
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "digest is not sha256:<64 hex characters>"; return; }
    fi
    last="${name##*/}"
    if [[ "$last" == *:* ]]; then
        tag="${last#*:}"
        if [ "${#tag}" -gt 128 ]; then echo "tag has ${#tag} characters, over Docker's limit of 128"; return; fi
        [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { echo "tag is not valid"; return; }
        name="${name%:*}"
    fi
    [ -n "$tag$digest" ] || { echo "no tag or digest"; return; }
    # the registry host (with a port) may have capitals; the repository path may not
    repo="$name"
    host="${name%%/*}"
    if [[ "$name" == */* && ( "$host" == *.* || "$host" == *:* || "$host" == localhost ) ]]; then repo="${name#*/}"; fi
    [ "$repo" = "$(tr '[:upper:]' '[:lower:]' <<<"$repo")" ] || { echo "name must be lower case"; return; }
    return 0
}

# Pass 2: every service
services=0
for f in "${files[@]}"; do
    [ -n "${config[$f]:-}" ] || continue
    folder="$(basename "$(dirname "$(realpath "$f")")" | tr '[:upper:]' '[:lower:]')"
    while IFS=$'\t' read -r svc has_image has_build image; do
        services=$((services + 1))
        [ "$has_image" = true ] || continue
        problem="$(ref_problem "$image")"
        if [ -n "$problem" ]; then
            fail "$f" "$svc" "$problem"
            continue
        fi
        name="${image%%@*}"
        last="${name##*/}"
        [[ "$last" == *:* ]] && name="${name%:*}"
        derived="$registry/elysium-$folder-$(tr '[:upper:]' '[:lower:]' <<<"$svc")"
        if [[ "$name" == "$registry/elysium-"* ]]; then
            if [ -z "${published[$name]:-}" ]; then
                fail "$f" "$svc" "$name is an image of ours that no Compose build publishes (tools/list-images.sh would not)"
            elif [ "$has_build" = true ] && [ "$name" != "$derived" ]; then
                fail "$f" "$svc" "build and image disagree: the build publishes $derived, the image is $name"
            fi
        elif [ "$has_build" = true ]; then
            fail "$f" "$svc" "build and image disagree: the build publishes $derived, the image is $name"
        fi
    done < <(jq -r '.services | to_entries[] | [.key, (.value | has("image")), (.value | has("build")), (.value.image // "")] | @tsv' <<<"${config[$f]}")
done

[ "$status" -eq 0 ] || exit 1
echo "compose images ok: ${#files[@]} files, $services services"
