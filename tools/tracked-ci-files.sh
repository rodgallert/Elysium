#!/bin/sh
# Lists the files the pin and permission checks read (#83): what git tracks (`git ls-files -s -z`, so a name git would
# quote is read like any other) among .github/workflows/*.yml|yaml and every action.yml / action.yaml.
# Usage: tools/tracked-ci-files.sh <repository root>
# Output, one record per line, sorted by path: "<kind> <path>" with kind
#   F  a regular file (mode 100644 or 100755) to scan;
#   S  a symlink, G anything else that is not a regular file (a submodule): never scanned, always an offender;
#   U  a path with a control character (a tab, a newline), a double quote or a backslash in it: an offender. A name
#      without a newline is also listed as F so its content is scanned; a newline is shown as "?" and never scanned.
# Exit 2 when git cannot list the files. POSIX sh.
set -eu

root="${1:?usage: tracked-ci-files.sh <repository root>}"
cd "$root"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
git ls-files -s -z >"$tmp" 2>/dev/null || exit 2
tr '\000\n' '\001\002' <"$tmp" | awk '
BEGIN { RS = "\001" }
{
    t = index($0, "\t")
    if (t == 0) next
    split(substr($0, 1, t - 1), m, " ")
    mode = m[1]
    path = substr($0, t + 1)
    if (!(path ~ /^[.]github\/workflows\/[^\/]+[.]ya?ml$/ || path ~ /(^|\/)action[.]ya?ml$/)) next
    shown = path
    gsub(/\002/, "?", shown)
    if (mode == "120000") print "S " shown
    else if (mode != "100644" && mode != "100755") print "G " shown
    else if (index(path, "\002") > 0) print "U " shown
    else {
        if (path ~ /[[:cntrl:]"\\]/) print "U " path
        print "F " path
    }
}' | LC_ALL=C sort -s -k2
