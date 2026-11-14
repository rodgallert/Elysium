#!/usr/bin/env bash
# Fixture tests for the release scripts (tools/release-*.sh, tools/check-prod-pins.sh). Offline: no registry.
# Run from anywhere: tools/tests/release-tools.sh (VERBOSE=1 also shows each case's output)
set -uo pipefail

tools="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

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
git push -q origin "$elsewhere:refs/heads/release/fake-api-0.4"
STUB_REVISION="$elsewhere" STUB_ATTESTED="$elsewhere" state ok "the same tag once its commit is on a release branch: released" released

git remote set-url origin "$work/nowhere.git"
state fail "a git remote that can't be read fails"

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures failed"
    exit 1
fi
echo "All passed"
