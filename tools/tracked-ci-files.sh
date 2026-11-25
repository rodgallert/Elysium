#!/bin/sh
# Lists the files the pin and permission checks read (#83): what git tracks (`git ls-files -s -z`, so a name git would
# quote is read like any other) among .github/workflows/*.yml|yaml and every action.yml / action.yaml.
# Usage: tools/tracked-ci-files.sh <repository root>
# Output, one record per line, sorted by path: "<kind> <path>" with kind
#   F  a regular file (mode 100644 or 100755) to scan;
#   S  a symlink, G anything else that is not a regular file (a submodule): never scanned, always an offender;
#   U  a path under .github/ or ending in action.yml / action.yaml with a byte outside [A-Za-z0-9._/-] (a space, "=", a
#      quote, a backslash, a tab, a newline, non-UTF-8 bytes): an offender, never scanned (a newline is shown as "?").
# Bytes are decided in the C locale. Exit 2 when git cannot list the files, 3 when a tracked path contains the byte 0x01
# or 0x02 (the separators used below). POSIX sh.
set -eu

root="${1:?usage: tracked-ci-files.sh <repository root>}"
cd "$root"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
git ls-files -s -z >"$tmp" 2>/dev/null || exit 2
# The records are separated with the bytes 0x01 (record) and 0x02 (stands for a newline), so a listing that contains either
# cannot be split safely: refuse it rather than split around it
# shellcheck disable=SC2094 # cmp only reads the file
if ! tr -d '\001\002' <"$tmp" | cmp -s - "$tmp"; then
    exit 3
fi
tr '\000\n' '\001\002' <"$tmp" | LC_ALL=C awk '
BEGIN { RS = "\001" }
{
    t = index($0, "\t")
    if (t == 0) next
    split(substr($0, 1, t - 1), m, " ")
    mode = m[1]
    path = substr($0, t + 1)
    # candidates, decided byte-wise: anything under .github/ and any action.yml / action.yaml
    if (!(index(path, ".github/") == 1 || path ~ /(^|\/)action[.]ya?ml$/)) next
    shown = path
    gsub(/\002/, "?", shown)
    if (path ~ /[^A-Za-z0-9._\/-]/) {
        print "U " shown
        next
    }
    if (!(path ~ /^[.]github\/workflows\/[^\/]+[.]ya?ml$/ || path ~ /(^|\/)action[.]ya?ml$/)) next
    if (mode == "120000") print "S " shown
    else if (mode != "100644" && mode != "100755") print "G " shown
    else print "F " path
}' | LC_ALL=C sort -s -k2
