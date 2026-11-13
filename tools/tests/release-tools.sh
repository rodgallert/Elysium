#!/usr/bin/env bash
# Fixture tests for the release scripts (tools/release-*.sh, tools/check-prod-pins.sh). Offline: no registry.
# Run from anywhere: tools/tests/release-tools.sh
set -uo pipefail

tools="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# expect <ok|fail> <description> <command...>: runs the command and checks its exit status
expect() {
    local want="$1" what="$2" out got
    shift 2
    if out="$("$@" 2>&1)"; then got=ok; else got=fail; fi
    if [ "$got" = "$want" ]; then
        echo "ok    $what"
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

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures failed"
    exit 1
fi
echo "All passed"
