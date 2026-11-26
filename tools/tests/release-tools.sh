#!/usr/bin/env bash
# Fixture tests for the release scripts (tools/release-*.sh, tools/check-prod-pins.sh). Offline: no registry.
# Run from anywhere: tools/tests/release-tools.sh (VERBOSE=1 also shows each case's output)
# shellcheck disable=SC2016 # the cases hand single-quoted scripts to inner shells, which expand their own parameters
set -uo pipefail

tools="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
# shellcheck source=lib/filter.sh
source "$(dirname "$0")/lib/filter.sh"
filter_precheck "$0" # the cases build on each other, so every command runs: a filter no case names stops here
ran=0

# Guard: every git command here must act on the fixture repository under $work, never on the real one. The
# cases change remotes and push tags; run against the real repository, they would rewrite its origin or push
# to GitHub. So git ignores the user's and the system's configuration, never searches above $work for a
# repository, and the script stops unless the fixture repository resolves inside $work (checked below).
case "$work" in
    "${TMPDIR:-/tmp}"/*) ;;
    *) echo "Refusing to run: the work directory $work is not a fresh temporary directory" >&2; exit 1 ;;
esac
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$work"

# expect <ok|fail> <description> <command...>: runs the command and checks its exit status
expect() {
    local want="$1" what="$2" out got
    shift 2
    if out="$("$@" 2>&1)"; then got=ok; else got=fail; fi
    # the cases build on each other (a command changes what the next one looks at), so every command runs; only the cases the
    # filter names are reported and counted
    filter_gate "$what" || return 0
    ran=$((ran + 1))
    if [ "$got" = "$want" ]; then
        echo "ok    $what"
        # VERBOSE=1 shows why each case passed or failed
        # shellcheck disable=SC2001 # indents every line of the output
        [ -z "${VERBOSE:-}" ] || sed "s/^/      /" <<<"$out"
    else
        echo "FAIL  $what (wanted $want, got $got)"
        # shellcheck disable=SC2001 # indents every line of the output
        sed "s/^/      /" <<<"$out"
        failures=$((failures + 1))
    fi
}
# jqok <description> <command> <jq filter>: the command succeeds and its JSON output matches the filter
jqok() { expect ok "$1" bash -c "$2 | jq -e '$3' >/dev/null"; }

# A fixture repository: a copy of the tools and one service, Fake, with two images (api and web)
repo="$work/repo"
mkdir -p "$repo/Fake/api" "$repo/Fake/web"
cp -r "$tools" "$repo/tools"
echo 'FROM scratch' >"$repo/Fake/api/Dockerfile"
echo 'FROM scratch' >"$repo/Fake/web/Dockerfile"
compose_plain='services:
  api:
    build: ./api
  web:
    build: ./web'
echo "$compose_plain" >"$repo/Fake/docker-compose.yml"
git -C "$repo" init -q -b main
if [ "$(command git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" != "$(cd "$repo" && pwd -P)/.git" ]; then
    echo "Refusing to run: the fixture repository doesn't resolve to $repo/.git" >&2
    exit 1
fi
git() { command git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
git add -A
git commit -qm "chore: start"
commit() { git add -A; git commit -qm "$1" --allow-empty; }
props() { printf '<Project>\n  <PropertyGroup>\n    <VersionPrefix>%s</VersionPrefix>\n  </PropertyGroup>\n</Project>\n' "$1" >"$2"; }
pkg() { printf '{\n  "name": "web",\n  "version": "%s"\n}\n' "$1" >"$2"; }
T="$repo/tools"

echo "== release-parts.sh"
jqok "a service without a version file has no part" "$T/release-parts.sh" '. == []'
props 0.1.0 "$repo/Fake/Directory.Build.props"
jqok "Directory.Build.props at the service root makes one part with every image" "$T/release-parts.sh" \
    '. == [{"part":"fake","service":"fake","folder":"Fake","versionFile":"Fake/Directory.Build.props","changelog":"Fake/CHANGELOG.md","version":"0.1.0","images":[{"image":"elysium-fake-api","context":"Fake/api","file":"Fake/api/Dockerfile"},{"image":"elysium-fake-web","context":"Fake/web","file":"Fake/web/Dockerfile"}]}]'
rm "$repo/Fake/Directory.Build.props"
pkg 0.4.0 "$repo/Fake/package.json"
jqok "package.json at the service root versions it when there is no Directory.Build.props" "$T/release-parts.sh" '.[0].version == "0.4.0"'
rm "$repo/Fake/package.json"

declare_parts() { # <images of fake-api> <images of fake-web> [<name of the first part>]
    cat >"$repo/Fake/docker-compose.yml" <<EOF
x-release-parts:
  ${3:-fake-api}:
    version: api/Directory.Build.props
    images: [$1]
  fake-web:
    version: web/package.json
    images: [$2]
$compose_plain
EOF
}
props 0.1.0 "$repo/Fake/api/Directory.Build.props"
pkg 1.0.0 "$repo/Fake/web/package.json"
declare_parts api web
jqok "declared parts each get their version file, changelog and images" "$T/release-parts.sh" '
    map({part, version, changelog, images: [.images[].image]}) == [
      {"part":"fake-api","version":"0.1.0","changelog":"Fake/api/CHANGELOG.md","images":["elysium-fake-api"]},
      {"part":"fake-web","version":"1.0.0","changelog":"Fake/web/CHANGELOG.md","images":["elysium-fake-web"]}]'
declare_parts api ""
expect fail "an image in no part fails" "$T/release-parts.sh"
declare_parts "api, web" web
expect fail "an image in two parts fails" "$T/release-parts.sh"
declare_parts "api, worker" web
expect fail "a part listing an image the file doesn't build fails" "$T/release-parts.sh"
declare_parts api web other-api
expect fail "a part whose name doesn't start with the service's fails" "$T/release-parts.sh"
declare_parts api web
commit "chore: declare parts"

echo "== release-plan.sh"
expect fail "adding version files outside a release commit fails" "$T/release-plan.sh" merged HEAD
commit "docs: unrelated"
jqok "an ordinary commit releases nothing" "$T/release-plan.sh merged HEAD" '. == {"parts":[],"images":[]}'
pkg 1.1.0 "$repo/Fake/web/package.json"; commit "chore(release): fake-web 1.1.0"
jqok "a release commit releases only the part whose version changed, with its images" "$T/release-plan.sh merged HEAD" \
    '(.parts | map([.part, .version])) == [["fake-web","1.1.0"]] and (.images | map([.part, .version, .image])) == [["fake-web","1.1.0","elysium-fake-web"]]'
props 0.2.0 "$repo/Fake/api/Directory.Build.props"; pkg 1.2.0 "$repo/Fake/web/package.json"; commit "chore(release): fake-api 0.2.0, fake-web 1.2.0"
jqok "one release commit can release several parts" "$T/release-plan.sh merged HEAD" '(.parts | map(.part)) == ["fake-api","fake-web"]'
props 0.3.0 "$repo/Fake/api/Directory.Build.props"; commit "feat(fake): something"
expect fail "a version change outside a release commit fails" "$T/release-plan.sh" merged HEAD
commit "chore(release): nothing"
expect fail "a release commit without a version change fails" "$T/release-plan.sh" merged HEAD
props 0.4 "$repo/Fake/api/Directory.Build.props"; commit "chore(release): fake-api 0.4"
expect fail "a version that isn't x.y.z fails" "$T/release-plan.sh" merged HEAD
props 0.4.0 "$repo/Fake/api/Directory.Build.props"; commit "chore(release): fake-api 0.4.0"
props 0.5.0 "$repo/Fake/api/Directory.Build.props"; commit "chore(release)!: fake-api 0.5.0"
jqok "a breaking release title (chore(release)!:) is a release commit too" "$T/release-plan.sh merged HEAD" '.parts[0].version == "0.5.0"'
jqok "a pull request's version change with a release title is a release" "$T/release-plan.sh changed HEAD~2 HEAD 'chore(release): fake-api 0.5.0'" '(.parts | map(.part)) == ["fake-api"]'
expect fail "a pull request's version change under another title fails" "$T/release-plan.sh" changed HEAD~2 HEAD "fix(fake): typo"
expect fail "a pull request with a release title and no version change fails" "$T/release-plan.sh" changed HEAD HEAD "chore(release): fake-api 0.5.0"
jqok "a pull request with neither releases nothing" "$T/release-plan.sh changed HEAD HEAD 'fix(fake): typo'" '.parts == []'
props 0.4.0 "$repo/Fake/api/Directory.Build.props"; commit "chore(release): fake-api 0.4.0 again, for the cases below"
jqok "a manual run takes the part's version, or the one given" "$T/release-plan.sh part fake-api 9.9.9" '.parts[0].version == "9.9.9"'
expect fail "a manual run for an unknown part fails" "$T/release-plan.sh" part nothing 1.0.0
mkdir -p "$repo/Other/app"; echo 'FROM scratch' >"$repo/Other/app/Dockerfile"; printf 'services:\n  app:\n    build: ./app\n' >"$repo/Other/docker-compose.yml"
expect fail "a service without a version file can't be released" "$T/release-plan.sh" part other 0.1.0
jqok "with --drafts it can be dry-run, as one part named after the service" "$T/release-plan.sh --drafts part other 0.1.0" \
    '.parts[0].part == "other" and .images[0].image == "elysium-other-app"'
rm -r "$repo/Other"

echo "== release-notes.sh"
cl="$repo/Fake/api/CHANGELOG.md"
cat >"$cl" <<'EOF'
# Changelog

## Unreleased

- Coming soon

## [0.2.0] - 2026-11-20

- Added things

### Breaking changes

None

## 0.1.0

- First
EOF
expect ok   "the version's section is printed, without the next one" \
    bash -c "out=\$('$T/release-notes.sh' '$cl' fake-api 0.2.0) && grep -q 'Added things' <<<\"\$out\" && ! grep -q First <<<\"\$out\""
expect fail "a section without a Breaking changes heading fails" "$T/release-notes.sh" "$cl" fake-api 0.1.0
expect fail "a missing section fails a release" "$T/release-notes.sh" "$cl" fake-api 0.9.0
expect fail "a dry run falls back to Unreleased, which still needs Breaking changes" "$T/release-notes.sh" --draft "$cl" fake-api 0.9.0
sed -i 's/^- Coming soon$/- Coming soon\n\n### Breaking changes\n\nNone/' "$cl"
expect ok   "a dry run uses Unreleased" bash -c "'$T/release-notes.sh' --draft '$cl' fake-api 0.9.0 | grep -q 'Coming soon'"
rm "$cl"
expect ok   "a dry run without a changelog drafts from the service's commits" \
    bash -c "'$T/release-notes.sh' --draft '$cl' fake-api 0.9.0 | grep -q 'feat(fake): something'"

echo "== release-pin.sh"
d1="sha256:$(printf '1%.0s' {1..64})"
d2="sha256:$(printf '2%.0s' {1..64})"
d3="sha256:$(printf '3%.0s' {1..64})"
prod="$work/prod.yml"
cat >"$prod" <<EOF
services:
  api:
    image: ghcr.io/rodgallert/elysium-fake-api:0.4.0 # first release: tag only
  web:
    image: "ghcr.io/rodgallert/elysium-fake-web:1.1.0@$d3"
  db:
    image: postgres:17.6-alpine@$d3
EOF
expect ok   "the images get the version and their digests" "$T/release-pin.sh" --file "$prod" 0.4.0 "elysium-fake-api=$d1"
expect ok   "the line is rewritten, comment kept, other lines untouched" bash -c "
    grep -qx '    image: ghcr.io/rodgallert/elysium-fake-api:0.4.0@$d1 # first release: tag only' '$prod' &&
    grep -qx '    image: \"ghcr.io/rodgallert/elysium-fake-web:1.1.0@$d3\"' '$prod' && grep -q 'postgres:17.6-alpine@$d3' '$prod'"
expect ok   "quoted lines keep their quotes" "$T/release-pin.sh" --file "$prod" 1.2.0 "elysium-fake-web=$d2"
expect ok   "  (checked)" grep -qx "    image: \"ghcr.io/rodgallert/elysium-fake-web:1.2.0@$d2\"" "$prod"
expect fail "an image with no line in the file fails" "$T/release-pin.sh" --file "$prod" 0.4.0 "elysium-fake-api=$d2" "elysium-fake-worker=$d1"
expect ok   "a failed run leaves the file unchanged" grep -q "elysium-fake-api:0.4.0@$d1" "$prod"
expect fail "a malformed digest fails" "$T/release-pin.sh" --file "$prod" 0.4.0 "elysium-fake-api=sha256:abc"

echo "== check-prod-pins.sh (offline)"
cp "$prod" "$repo/docker-compose.prod.yml"
expect ok   "each image pinned at its own part's version passes" "$T/check-prod-pins.sh" --offline
check() { # <ok|fail> <description> <line replacing the db service's image line>
    sed "s#^    image: postgres.*#    $3#" "$prod" >"$repo/docker-compose.prod.yml"
    expect "$1" "$2" "$T/check-prod-pins.sh" --offline
}
check fail "ours without a digest fails" "image: ghcr.io/rodgallert/elysium-fake-api:0.4.0"
check fail "ours without a tag fails" "image: ghcr.io/rodgallert/elysium-fake-api@$d1"
check fail "ours at another version than its part fails" "image: ghcr.io/rodgallert/elysium-fake-web:1.1.0@$d1"
check fail "ours at a tag that isn't a version fails" "image: ghcr.io/rodgallert/elysium-fake-api:main@$d1"
check fail "ours in no release part fails" "image: ghcr.io/rodgallert/elysium-fake-worker:0.4.0@$d1"
check fail "a short digest fails" "image: postgres:17.6-alpine@sha256:1234"
check fail "a service that builds from source fails" "build: ./Fake/api"
check ok   "a Docker Hub image with a full tag and digest passes" "image: pgsty/silo:RELEASE.2026-11-12T00-00-00Z@$d1"
check ok   "an MCR image with a full tag and digest passes" "image: mcr.microsoft.com/dotnet/aspnet:10.0.1@$d1"
check fail "a third-party image without a digest fails" "image: redis:8.2-alpine"
check fail "latest fails" "image: redis:latest@$d1"
check fail "a bare major tag fails" "image: postgres:17-alpine@$d1"
check fail "a floating name fails" "image: nginx:stable@$d1"
check fail "a registry that isn't allowed fails" "image: quay.io/team/thing:1.2.3@$d1"
printf 'services: {}\n' >"$repo/docker-compose.prod.yml"
expect ok   "an empty production list passes" "$T/check-prod-pins.sh" --offline

echo "== release-state.sh (stubbed Releases API, registry and attestations; the fixture's own git remote)"
# The fixture's own bare remote holds main, the release branches and the tags. curl, gh and
# `docker buildx imagetools` are the stubs in tools/tests/stubs, answering from STUB_HTTP (the Releases API),
# STUB_REGISTRY (an image tag's digest), STUB_REVISION (the images' revision label) and STUB_ATTESTED (the commit
# the attestations were made for)
git init -q --bare "$work/origin.git"
git remote add origin "$work/origin.git"
git push -q origin main
stubs="$tools/tests/stubs"
export REAL_DOCKER RELEASE_TOOLS_TEST=1
REAL_DOCKER="$(command -v docker)"
# state <ok|fail> <description> [<expected output>]; the STUB_* values come from the caller
state() {
    local cmd=(env PATH="$stubs:$PATH" GITHUB_REPOSITORY=rodgallert/Elysium "$T/release-state.sh" fake-api 0.4.0)
    if [ -n "${3:-}" ]; then
        # shellcheck disable=SC2016 # expanded by the inner shell
        expect "$1" "$2" bash -c '[ "$("$@")" = "$0" ]' "$3" "${cmd[@]}"
    else
        expect "$1" "$2" "${cmd[@]}"
    fi
}
expect fail "a stub refuses to run outside the tests" env -u RELEASE_TOOLS_TEST "$stubs/curl"
expect fail "the docker stub refuses an empty REAL_DOCKER" env REAL_DOCKER= "$stubs/docker" compose version
mkdir -p "$repo/.github/workflows" "$repo/.github/actions/release-image"
echo "name: Release" >"$repo/.github/workflows/release.yml"
echo "name: Release image" >"$repo/.github/actions/release-image/action.yml"
printf 'services:\n  api:\n    image: ghcr.io/rodgallert/elysium-fake-api:0.4.0@%s\n' "$d1" >"$repo/docker-compose.prod.yml"
commit "chore(release): pin fake-api 0.4.0"
git push -q origin main
built="$(git rev-parse HEAD)"

export STUB_REVISION="$built" STUB_ATTESTED="$built"
STUB_HTTP=404 STUB_REGISTRY=missing state ok "nothing released yet: unreleased (the source check runs)" unreleased
# A decoy tag (ls-remote matches by the end of a name) is no tag of the version
git tag -a "x/refs/tags/fake-api-v0.4.0" -m decoy "$built"
git push -q origin "refs/tags/x/refs/tags/fake-api-v0.4.0"
STUB_HTTP=404 STUB_REGISTRY=missing state ok "a decoy tag x/refs/tags/<tag> doesn't make an unreleased version look partly released" unreleased
git push -q origin ":refs/tags/x/refs/tags/fake-api-v0.4.0"
git tag -d "x/refs/tags/fake-api-v0.4.0" >/dev/null
STUB_HTTP=500 STUB_REGISTRY=missing state fail "a Releases API error fails, never read as unreleased"
STUB_HTTP=000 STUB_REGISTRY=missing state fail "no answer from the Releases API fails"
STUB_HTTP=404 STUB_REGISTRY=error state fail "a registry error fails, never read as not tagged"

# The release: the tag on the commit the images were built from, on main
git tag -a fake-api-v0.4.0 -m "fake-api 0.4.0" "$built"
git push -q origin fake-api-v0.4.0
export STUB_HTTP=200 STUB_REGISTRY="$d1"
state ok "a hotfix copy-back of a real release: released (the source check is skipped)" released
STUB_REGISTRY="$d2" state fail "released, but the pin isn't the released digest: fails"
STUB_HTTP=404 state fail "a tag without a Release (partly released) fails"
STUB_REGISTRY=error state fail "a registry error on a released version fails"
STUB_ATTESTED="" state fail "a tag, Release and image tag with no attested images (forged) fail"
STUB_ATTESTED="$(printf 'b%.0s' {1..40})" state fail "images attested for another commit fail"
STUB_REVISION="not-a-commit" STUB_ATTESTED="not-a-commit" state fail "a revision label that isn't a commit id fails"

# Images built from a commit whose release tooling differs from the tagged one
git checkout -q -b tooling-change
echo "changed" >"$repo/tools/fixture-change"
commit "ci: change the release tooling"
changed="$(git rev-parse HEAD)"
git checkout -q main
STUB_REVISION="$changed" STUB_ATTESTED="$changed" state fail "images built with other release tooling than the tagged commit's fail"

# A tag put on an older commit on main, with that commit's own genuine, attested build, under a version it never had
older="$(git log --format=%H -1 --fixed-strings --grep="chore(release): fake-api 0.2.0")"
git tag -f -a fake-api-v0.4.0 -m "fake-api 0.4.0" "$older" >/dev/null
git push -q -f origin fake-api-v0.4.0
STUB_REVISION="$older" STUB_ATTESTED="$older" state fail "a tag on an older main commit whose version file says another version fails"

# A tag moved onto a commit that is only on an unprotected branch (same service and tooling trees)
git checkout -q -b unprotected
echo "elsewhere" >"$repo/OTHER.md"
commit "docs: elsewhere"
elsewhere="$(git rev-parse HEAD)"
git checkout -q main
git push -q origin unprotected
git tag -f -a fake-api-v0.4.0 -m "fake-api 0.4.0" "$elsewhere" >/dev/null
git push -q -f origin fake-api-v0.4.0
STUB_REVISION="$elsewhere" STUB_ATTESTED="$elsewhere" state fail "a tag on a commit that isn't on main or a release branch fails"
# Decoy branches (ls-remote matches by the end of a name) outside the rulesets don't count as main or a release branch
git push -q origin "$elsewhere:refs/heads/x/refs/heads/main" "$elsewhere:refs/heads/y/refs/heads/release/fake"
STUB_REVISION="$elsewhere" STUB_ATTESTED="$elsewhere" state fail "a tag on a commit that is only on decoy x/refs/heads/main and y/refs/heads/release/ branches fails"
git push -q origin ":refs/heads/x/refs/heads/main" ":refs/heads/y/refs/heads/release/fake"
git push -q origin "$elsewhere:refs/heads/release/fake-api-0.4"
STUB_REVISION="$elsewhere" STUB_ATTESTED="$elsewhere" state ok "the same tag once its commit is on a release branch: released" released

echo "== release-publish.sh (stubbed registry, Releases and source check; its own bare remote)"
# Claiming the version: the git tag is pushed first, and a run that doesn't win it never tags an image. The remote
# has a pre-receive hook (tools/tests/publish-stubs/pre-receive) that lets a "racing" run win the push first.
pubremote="$work/publish-origin.git"
git init -q --bare -b main "$pubremote"
git push -q "$pubremote" "main:refs/heads/main" "$elsewhere:refs/heads/other"
cp "$tools/tests/publish-stubs/pre-receive" "$pubremote/hooks/pre-receive"
pub="$work/publish"
command git clone -q -b main "$pubremote" "$pub"
if [ "$(command git -C "$pub" rev-parse --absolute-git-dir 2>/dev/null)" != "$(cd "$pub" && pwd -P)/.git" ]; then
    echo "Refusing to run: the publish fixture doesn't resolve to $pub/.git" >&2
    exit 1
fi
cp "$tools/tests/publish-stubs/release-check-source.sh" "$pub/tools/release-check-source.sh"
printf '# Changelog\n\n## 0.4.0\n\n- Released\n\n### Breaking changes\n\nNone\n' >"$pub/Fake/api/CHANGELOG.md"
pubhead="$(command git -C "$pub" rev-parse HEAD)"
export STUB_TAGS="$work/registry"
image="ghcr.io/rodgallert/elysium-fake-api"
tagfile="$STUB_TAGS/${image//\//_}:0.4.0"
publish() { # <ok|fail> <description> [<text a failure must print>]: one release run for fake-api 0.4.0 in the clone
    local run=(env PATH="$tools/tests/publish-stubs:$PATH" GITHUB_REPOSITORY=rodgallert/Elysium GH_TOKEN=x \
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
        "$pub/tools/release-publish.sh" fake-api 0.4.0)
    if [ -n "${3:-}" ]; then
        # shellcheck disable=SC2016 # expanded by the inner shell
        [ "$1" = fail ] || { echo "publish: a message is only for a failure" >&2; exit 1; }
        expect ok "$2" bash -c 'out="$("$@" 2>&1)"; status=$?; echo "$out"; [ $status -ne 0 ] && grep -qF -- "$0" <<<"$out"' "$3" "${run[@]}"
    else
        expect "$1" "$2" "${run[@]}"
    fi
}
fresh() { rm -rf "$STUB_TAGS"; mkdir -p "$STUB_TAGS"; command git -C "$pub" tag -d fake-api-v0.4.0 >/dev/null 2>&1 || true; }
remote_tag() { command git -C "$pubremote" rev-parse -q --verify "refs/tags/fake-api-v0.4.0^{commit}" || true; }
tagged_images() { grep -c '^tag ' "$STUB_TAGS/log" 2>/dev/null || true; }

fresh
publish ok "a release run claims the tag, tags the image and creates the Release"
expect ok "  (the tag is on the merge commit, the image tagged with the pinned digest, the Release created)" \
    bash -c '[ "$(git -C "$0" rev-parse "refs/tags/fake-api-v0.4.0^{commit}")" = "$1" ] && [ "$(cat "$2")" = "$3" ] && [ -f "$4/release-fake-api-v0.4.0" ]' \
    "$pubremote" "$pubhead" "$tagfile" "$d1" "$STUB_TAGS"
# A run that died after the tag and the images, before the Release: its re-run finds the tag on this commit
rm "$STUB_TAGS/release-fake-api-v0.4.0"
publish ok "re-running the winner is idempotent: the tag is on this commit, so it carries on"
expect ok "  (the image isn't tagged a second time, and the Release is there)" \
    bash -c '[ "$(grep -c "^tag " "$0/log")" = 1 ] && [ -f "$0/release-fake-api-v0.4.0" ]' "$STUB_TAGS"

# A pre-existing tag on another commit: refused before any image tag
fresh
command git -C "$pubremote" tag -d fake-api-v0.4.0 >/dev/null
command git -C "$pubremote" -c user.name=t -c user.email=t@t tag -a fake-api-v0.4.0 -m other "$elsewhere"
publish fail "a tag already on another commit fails" "not on this commit; no image was tagged"
expect ok "  (no image was tagged and no Release created)" bash -c '[ ! -e "$0/log" ]' "$STUB_TAGS"
command git -C "$pubremote" tag -d fake-api-v0.4.0 >/dev/null
command git -C "$pubremote" tag fake-api-v0.4.0 "$elsewhere"
fresh
publish fail "a lightweight tag on another commit fails too" "not on this commit; no image was tagged"
expect ok "  (no image was tagged)" bash -c '[ ! -e "$0/log" ]' "$STUB_TAGS"

# Two runs for one version, on different commits: the loser's push is rejected because the winner got there first
command git -C "$pubremote" tag -d fake-api-v0.4.0 >/dev/null
fresh
STUB_RACE_COMMIT="$elsewhere" publish fail "a run that loses the tag push fails" "not on this commit; no image was tagged"
expect ok "  (it tagged no image and created no Release; the winner's tag stands)" \
    bash -c '[ ! -e "$0/log" ] && [ "$(git -C "$1" rev-parse "refs/tags/fake-api-v0.4.0^{commit}")" = "$2" ]' "$STUB_TAGS" "$pubremote" "$elsewhere"
# Two runs of the same merge: the loser sees the tag on its own commit and carries on, with the same digests
command git -C "$pubremote" tag -d fake-api-v0.4.0 >/dev/null
fresh
STUB_RACE_COMMIT="$pubhead" publish ok "a run that loses the push to another run of the same commit carries on"
expect ok "  (the image is tagged with the pinned digest)" bash -c '[ "$(cat "$0")" = "$1" ]' "$tagfile" "$d1"
# An image version tag that points elsewhere still fails, after the claim
command git -C "$pubremote" tag -d fake-api-v0.4.0 >/dev/null
fresh
printf '%s' "$d2" >"$tagfile"
publish fail "an image tag that already points at another digest fails" "release tags never move"
expect ok "  (before the git tag is pushed, and nothing was moved)" \
    bash -c '[ "$(cat "$0")" = "$1" ] && [ ! -e "$2/log" ] && [ -z "$(git -C "$3" tag -l fake-api-v0.4.0)" ]' "$tagfile" "$d2" "$STUB_TAGS" "$pubremote"

# Release notes that can't be built fail before the git tag is pushed, so an honest failure doesn't use the version up
fresh
mv "$pub/Fake/api/CHANGELOG.md" "$work/CHANGELOG.md"
publish fail "a missing changelog section fails" "has no section for 0.4.0"
expect ok "  (before the git tag is pushed)" bash -c '[ ! -e "$0/log" ] && [ -z "$(git -C "$1" tag -l fake-api-v0.4.0)" ]' "$STUB_TAGS" "$pubremote"
mv "$work/CHANGELOG.md" "$pub/Fake/api/CHANGELOG.md"

# A decoy tag: ls-remote matches refs by the end of their name, so x/refs/tags/<tag> answers a lookup of <tag>.
# Only the exact name counts.
decoy="x/refs/tags/fake-api-v0.4.0"
command git -C "$pubremote" -c user.name=t -c user.email=t@t tag -a "$decoy" -m decoy "$pubhead"
fresh
command git -C "$pubremote" tag fake-api-v0.4.0 "$elsewhere"
publish fail "a real tag on another commit and a decoy on the merge commit fails" "not on this commit; no image was tagged"
expect ok "  (no image tagged, no Release; the decoy is no claim)" bash -c '[ ! -e "$0/log" ]' "$STUB_TAGS"
command git -C "$pubremote" tag -d fake-api-v0.4.0 >/dev/null
fresh
publish ok "a decoy and no real tag: the decoy is ignored and the run claims the real tag"
expect ok "  (the real tag is on the merge commit)" \
    bash -c '[ "$(git -C "$0" rev-parse "refs/tags/fake-api-v0.4.0^{commit}")" = "$1" ]' "$pubremote" "$pubhead"
command git -C "$pubremote" tag -d "$decoy" >/dev/null
command git -C "$pubremote" tag -d fake-api-v0.4.0 >/dev/null
expect ok "release-tag-commit.sh ignores a decoy named x/refs/tags/<tag>" bash -c '
    git -C "$0" tag fake-api-v0.4.0 "$1" && git -C "$0" tag "x/refs/tags/fake-api-v0.4.0" "$2" &&
    [ "$(cd "$3" && ./tools/release-tag-commit.sh fake-api-v0.4.0)" = "$1" ] &&
    git -C "$0" tag -d fake-api-v0.4.0 >/dev/null && [ -z "$(cd "$3" && ./tools/release-tag-commit.sh fake-api-v0.4.0)" ]' \
    "$pubremote" "$elsewhere" "$pubhead" "$pub"
command git -C "$pubremote" tag -d "x/refs/tags/fake-api-v0.4.0" >/dev/null

git remote set-url origin "$work/nowhere.git"
state fail "a git remote that can't be read fails"

echo
filter_report "$ran" 0 || exit 1
if [ "$failures" -gt 0 ]; then
    echo "$failures failed"
    exit 1
fi
echo "All passed"
