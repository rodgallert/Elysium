#!/usr/bin/env bash
# Drift check for a deployed container, to be sourced by smoke tests (the prod-update check will reuse it with image
# digests). Needs Docker and sha256sum.
#
# deploy_drift <container> <project> <started_ns> <image_id> <config_in_container> <config_file>
#   container           container id or name
#   project             the Compose project it must belong to (label com.docker.compose.project)
#   started_ns          `date +%s%N` taken just before the deploy began: the container must have been created after it
#   image_id            the image id (sha256:...) the deploy just built or pulled: the container must run exactly it
#   config_in_container the config file inside the container (read with `docker exec ... cat`)
#   config_file         the file in the commit that config must be identical to (by sha256)
# Prints one line per mismatch, "drift: <container name>: <field>: expected <x>, got <y>", with the field one of
# image, config, created or project, and returns 1 when there is any; returns 0 and prints nothing otherwise.
deploy_drift() {
    local id="$1" project="$2" started_ns="$3" want_image="$4" conf_in="$5" conf_file="$6"
    local name got created_ns want_hash got_hash rc=0
    name="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null)"
    name="${name#/}"
    if [ -z "$name" ]; then
        echo "drift: ${id:-<no container>}: container: expected a container, got none"
        return 1
    fi

    got="$(docker inspect -f '{{.Image}}' "$id" 2>/dev/null)"
    [ "$got" = "$want_image" ] || { echo "drift: $name: image: expected $want_image, got $got"; rc=1; }

    got="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$id" 2>/dev/null)"
    [ "$got" = "$project" ] || { echo "drift: $name: project: expected $project, got ${got:-<no label>}"; rc=1; }

    got="$(docker inspect -f '{{.Created}}' "$id" 2>/dev/null)"
    created_ns="$(date -d "$got" +%s%N 2>/dev/null)"
    if [ -z "$created_ns" ] || [ "$created_ns" -lt "$started_ns" ]; then
        echo "drift: $name: created: expected after the deploy started ($started_ns ns), got ${got:-<unknown>}"
        rc=1
    fi

    want_hash="$(sha256sum <"$conf_file" | cut -d' ' -f1)"
    got_hash="$(docker exec "$id" cat "$conf_in" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [ "$got_hash" = "$want_hash" ] || { echo "drift: $name: config: expected sha256 $want_hash of $conf_file, got $got_hash of $conf_in"; rc=1; }

    return "$rc"
}
