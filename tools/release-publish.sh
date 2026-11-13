#!/usr/bin/env bash
# Publishes one release part after its release PR merged; run by the release job on the merge commit (HEAD).
# The images were built, pushed by digest and attested by the prepare run, and the release PR pinned those
# digests in docker-compose.prod.yml. This only:
#   1. checks every pinned digest of the part carries SBOM and provenance attestations signed by the release
#      workflow of this repository (so a digest written by hand can't be released);
#   2. checks the part's service folder at HEAD is identical to the commit the images were built from (their
#      org.opencontainers.image.revision label), so nothing changed between the prepare run and the merge;
#   3. tags every image <version> (same digest, no rebuild), creates the annotated git tag <part>-v<version> on
#      HEAD and the GitHub Release with the part's changelog section and the attested SBOMs.
# Re-running is safe: steps already done are skipped, and something tagged differently fails. A version that is
# already fully released (a hotfix's version and pin copied back to main) is skipped.
#
#   release-publish.sh <part> <version>
# Needs: GH_TOKEN, GITHUB_REPOSITORY (owner/repo), docker logged in to the registry (RELEASE_REGISTRY, ghcr.io).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

part="${1:?usage: release-publish.sh <part> <version>}"
version="${2:?usage: release-publish.sh <part> <version>}"
repository="${GITHUB_REPOSITORY:?}"
owner="${repository%%/*}"
registry="${RELEASE_REGISTRY:-ghcr.io}"
tag="$part-v$version"
signer="$repository/.github/workflows/release.yml"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

fail() { echo "$part $version: $*" >&2; exit 1; }
remote_digest() { docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest // empty' || true; }

info="$(tools/release-parts.sh | jq -c --arg p "$part" '.[] | select(.part == $p)')"
[ -n "$info" ] || fail "no such release part"
[ "$(jq -r .version <<<"$info")" = "$version" ] || fail "the part's version file says $(jq -r .version <<<"$info")"
folder="$(jq -r .folder <<<"$info")"
changelog="$(jq -r .changelog <<<"$info")"

# The pinned digest of every image of the part
declare -A digests
while IFS= read -r image; do
    line="$(docker compose -f docker-compose.prod.yml config --no-interpolate --format json |
        jq -r --arg r "$registry/$owner/$image:$version@" '.services // {} | .[].image // empty | select(startswith($r))' | head -1)"
    [ -n "$line" ] || fail "docker-compose.prod.yml doesn't pin $image at $version"
    digests[$image]="${line##*@}"
done < <(jq -r '.images[].image' <<<"$info")

# Already released (every image tag, the git tag and the Release exist and agree): nothing to do
released=true
for image in "${!digests[@]}"; do
    [ "$(remote_digest "$registry/$owner/$image:$version")" = "${digests[$image]}" ] || released=false
done
if $released && git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null && gh release view "$tag" -R "$repository" >/dev/null 2>&1; then
    echo "$tag is already released; nothing to do"
    exit 0
fi

# 1. Attestations, and the commit the images were built from
built_from=""
for image in "${!digests[@]}"; do
    ref="oci://$registry/$owner/$image@${digests[$image]}"
    gh attestation verify "$ref" -R "$repository" --signer-workflow "$signer" >/dev/null ||
        fail "$image: no build provenance signed by $signer"
    gh attestation verify "$ref" -R "$repository" --signer-workflow "$signer" \
        --predicate-type https://spdx.dev/Document/v2.3 --format json |
        jq '.[0].verificationResult.statement.predicate' >"$out/$image.spdx.json" ||
        fail "$image: no SBOM attestation signed by $signer"
    revision="$(docker buildx imagetools inspect "$registry/$owner/$image@${digests[$image]}" --format '{{json .Image}}' |
        jq -r '.config.Labels["org.opencontainers.image.revision"] // empty')"
    [ -n "$revision" ] || fail "$image: no revision label"
    [ -z "$built_from" ] || [ "$built_from" = "$revision" ] || fail "the images were built from different commits"
    built_from="$revision"
done

# 2. Nothing in the service changed between the prepare run and the merge
git cat-file -e "$built_from^{commit}" 2>/dev/null || git fetch -q --no-tags origin "$built_from" ||
    fail "can't fetch $built_from, the commit the images were built from"
if [ "$(git rev-parse "$built_from:$folder")" != "$(git rev-parse "HEAD:$folder")" ]; then
    fail "$folder changed between the prepare run ($built_from) and the merge; release a new version"
fi

# 3. Image tags, git tag, GitHub Release
for image in "${!digests[@]}"; do
    name="$registry/$owner/$image"
    current="$(remote_digest "$name:$version")"
    if [ "$current" = "${digests[$image]}" ]; then
        echo "$name:$version already tagged"
    elif [ -n "$current" ]; then
        fail "$name:$version already exists as $current; release tags never move"
    else
        docker buildx imagetools create --prefer-index=false --tag "$name:$version" "$name@${digests[$image]}"
        [ "$(remote_digest "$name:$version")" = "${digests[$image]}" ] || fail "$name:$version doesn't point at the pinned digest after tagging"
    fi
done

if existing="$(git ls-remote --tags origin "refs/tags/$tag^{}" | cut -f1)" && [ -n "$existing" ]; then
    [ "$existing" = "$(git rev-parse HEAD)" ] || fail "tag $tag already exists on $existing"
    echo "tag $tag already exists"
else
    git tag -a "$tag" -m "$part $version" HEAD
    git push origin "refs/tags/$tag"
fi

tools/release-notes.sh "$changelog" "$part" "$version" >"$out/notes.md"
if gh release view "$tag" -R "$repository" >/dev/null 2>&1; then
    echo "Release $tag already exists"
else
    gh release create "$tag" -R "$repository" --verify-tag --latest=false --title "$part $version" \
        --notes-file "$out/notes.md" "$out"/*.spdx.json
fi
echo "Released $tag"
