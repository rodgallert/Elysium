#!/usr/bin/env bash
# Tests for tools/wt.sh (issue #72): creating and removing a ticket's git worktree under .claude/worktrees/. Every case
# runs against a fresh fixture repository (with a bare "origin") under one temporary directory; nothing here touches the
# real repository's worktrees, and no case reaches GitHub (wt.sh makes no gh call: a stub gh would record one). Each test
# function and check cites the criterion or edge case it covers (#72-AC<n>, #72-AC<n>.<m>).
# Run from anywhere: tools/tests/wt-tools.sh (VERBOSE=1 also shows the output of passing cases)
# shellcheck disable=SC2016 # some checks pass strings with literal $( ) on purpose
set -uo pipefail

tools="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$tools/wt.sh"
stubs="$tools/tests/wt-stubs"
real_git="$(command -v git)"
work="$(mktemp -d /tmp/wt.XXXXXX)"
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
pass=0
failed=0

# Guard: every file this test writes lives under the fresh temporary directory, and git never looks above it
case "$work" in
    /tmp/wt.*) ;;
    *) echo "Refusing to run: the work directory $work is not a fresh temporary directory" >&2; exit 1 ;;
esac
work="$(cd -P "$work" && pwd -P)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$work"
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.invalid GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.invalid
mkdir -p "$work/home"

# ---- fixtures ---------------------------------------------------------------------------------------------------

n=0
repo="" root="" wtd="" origin="" sd="" head0="" wt=""

g() { "$real_git" -C "$repo" "$@"; }

# new_repo: a repository at $work/r<n> with one commit on main pushed to a bare origin, and its stub directory
new_repo() {
    n=$((n + 1))
    repo="$work/r$n"
    origin="$work/o$n.git"
    sd="$work/s$n"
    mkdir -p "$sd"
    "$real_git" init -q --bare -b main "$origin"
    "$real_git" init -q -b main "$repo"
    echo base >"$repo/file.txt"
    # the repository's own tracked .gitignore, so a missing .claude/worktrees/ entry shows up as an untracked directory
    cp "$tools/../.gitignore" "$repo/.gitignore"
    g add file.txt .gitignore
    g commit -qm "base"
    g remote add origin "$origin"
    g push -q -u origin main
    root="$repo"
    wtd="$root/.claude/worktrees"
    head0=$(g rev-parse HEAD)
}

# plain_wt <branch>: the branch off main, pushed to origin, and a worktree at the path wt.sh uses, made with plain git
plain_wt() {
    local b="$1" name="${1//\//-}"
    g branch "$b" main
    g push -q origin "$b"
    mkdir -p "$wtd"
    g worktree add -q "$wtd/$name" "$b"
    wt="$wtd/$name"
}
wcommit() { # <file> [text]: a commit in the current worktree (not pushed)
    printf '%s\n' "${2:-text}" >"$wt/$1"
    "$real_git" -C "$wt" add "$1"
    "$real_git" -C "$wt" commit -qm "add $1"
}
wpush() { "$real_git" -C "$wt" push -q origin HEAD; }

# runw <prefix> <args...>: runs wt.sh with the stubs first in PATH, in $WCWD (default the main copy); output in <prefix>.out,
# <prefix>.err and <prefix>.rc
runw() {
    local prefix="$1"
    shift
    (
        cd "${WCWD:-$repo}" || exit 99
        env -i PATH="$stubs:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$work" \
            GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.invalid GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.invalid \
            STUB_DIR="$sd" REAL_GIT="$real_git" WT_GIT_FAIL="${WT_GIT_FAIL:-}" WT_RM_FAIL_UNDER="${WT_RM_FAIL_UNDER:-}" \
            ${W_GIT_DIR:+GIT_DIR="$W_GIT_DIR"} ${W_GIT_WORK_TREE:+GIT_WORK_TREE="$W_GIT_WORK_TREE"} bash "$script" "$@" >"$prefix.out" 2>"$prefix.err" </dev/null
        echo $? >"$prefix.rc"
    )
}
# w <args...>: one run in the foreground; sets $out, $err and $rc
w() {
    : >"$sd/git.log"
    runw "$work/run" "$@"
    rc=$(<"$work/run.rc")
    out=$(<"$work/run.out")
    err=$(<"$work/run.err")
}

check() { # <name> <command...>: passes when the command succeeds
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass=$((pass + 1))
        [ -z "${VERBOSE:-}" ] || echo "ok    $name"
    else
        failed=$((failed + 1))
        echo "FAIL  $name"
        printf '      rc=%s\n      out: %s\n      err: %s\n' "${rc:-?}" "${out//$'\n'/ | }" "${err//$'\n'/ | }"
    fi
}
rc_is() { [ "$rc" -eq "$1" ]; }
says() { grep -qF -- "$1" <<<"$out
$err"; }
silent_on() { ! grep -qF -- "$1" <<<"$out
$err"; }
eq() { [ "$1" = "$2" ]; }
registered() { g worktree list --porcelain | grep -qxF "worktree $1"; }
unregistered() { ! registered "$1"; }
nwt() { g worktree list --porcelain | grep -c '^worktree '; }
exists_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
is_empty_or_absent() { [ ! -d "$1" ] || [ -z "$(ls -A "$1")" ]; }
main_untouched() { [ "$(g symbolic-ref --short HEAD)" = main ] && [ -z "$(g status --porcelain)" ] && [ "$(g rev-parse HEAD)" = "$head0" ] && [ "$(cat "$repo/file.txt")" = base ]; }
git_log_has() { grep -qE -- "$1" "$sd/git.log"; }
err_nonempty() { [ -n "$err" ]; }
err_lines_at_most() { [ "$(printf '%s\n' "$err" | grep -c '')" -le "$1" ]; }
one_line() { [ "$(printf '%s' "$err" | grep -c '')" -eq 1 ]; }

# ---- #72-AC1: add -------------------------------------------------------------------------------------------------

test_ac1_add() {
    new_repo
    g branch feat/x
    w add feat/x
    check "#72-AC1 add exits 0" rc_is 0
    check "#72-AC1 prints the absolute path .claude/worktrees/feat-x (the branch with / replaced by -) and nothing else" eq "$out" "$wtd/feat-x"
    check "#72-AC1 the worktree is registered with git" registered "$wtd/feat-x"
    check "#72-AC1 the branch is checked out there" eq "$("$real_git" -C "$wtd/feat-x" symbolic-ref --short HEAD 2>/dev/null)" feat/x
    check "#72-AC1 the checkout has the branch's files" test -f "$wtd/feat-x/file.txt"
    check "#72-AC1 the main working copy's branch, commit and files are unchanged" main_untouched
    check "#72-AC1 stderr is empty on success" eq "$err" ""
    check "#72-AC1 the tracked .gitignore ignores .claude/worktrees/ (no local exclude in the fixtures)" g check-ignore -q .claude/worktrees/feat-x
    check "#72-AC1 git status in the main copy is empty after add (nothing for git add -A to stage)" eq "$(g status --porcelain)" ""

    # a branch that exists only as origin/<branch> (the ticket flow creates it on GitHub, then fetches): a local branch tracking it
    new_repo
    "$real_git" clone -q "$origin" "$work/clone$n"
    "$real_git" -C "$work/clone$n" switch -q -c feat/r
    echo r >"$work/clone$n/r.txt"
    "$real_git" -C "$work/clone$n" add r.txt
    "$real_git" -C "$work/clone$n" commit -qm r
    "$real_git" -C "$work/clone$n" push -q origin feat/r
    g fetch -q origin
    w add feat/r
    check "#72-AC1 a branch that exists only on origin: exits 0" rc_is 0
    check "#72-AC1 a branch that exists only on origin: checked out at origin's commit" eq "$("$real_git" -C "$wtd/feat-r" rev-parse HEAD 2>/dev/null)" "$(g rev-parse origin/feat/r)"
    check "#72-AC1 a branch that exists only on origin: tracks origin/feat/r" eq "$("$real_git" -C "$wtd/feat-r" rev-parse --abbrev-ref '@{u}' 2>/dev/null)" origin/feat/r

    # --new: from origin/main, no upstream
    new_repo
    echo later >"$repo/later.txt"
    g add later.txt
    g commit -qm "local only"
    w add --new feat/n
    check "#72-AC1 --new exits 0" rc_is 0
    check "#72-AC1 --new prints the path" eq "$out" "$wtd/feat-n"
    check "#72-AC1 --new starts from origin/main, not from the local main" eq "$("$real_git" -C "$wtd/feat-n" rev-parse HEAD 2>/dev/null)" "$(g rev-parse origin/main)"
    check "#72-AC1 --new checks the new branch out" eq "$("$real_git" -C "$wtd/feat-n" symbolic-ref --short HEAD 2>/dev/null)" feat/n
    check "#72-AC1 --new sets no upstream (a push must not go to main)" bash -c '! "'"$real_git"'" -C "'"$wtd"'/feat-n" rev-parse --abbrev-ref "@{u}"'
    w add feat/n --new
    check "#72-AC1 --new after the branch works again: already exists, exit 0" rc_is 0
    check "#72-AC1 --new again says already exists" says "already exists: $wtd/feat-n"

    new_repo
    g branch feat/e
    w add --new feat/e
    check "#72-AC1 --new with a branch that exists refuses (exit 1)" rc_is 1
    check "#72-AC1 --new with a branch that exists names the branch" says feat/e
    check "#72-AC1 --new with a branch that exists creates nothing" is_empty_or_absent "$wtd"
    g update-ref -d refs/remotes/origin/main
    w add --new feat/m
    check "#72-AC1 --new without origin/main refuses (exit 1)" rc_is 1
    check "#72-AC1 --new without origin/main names origin/main" says origin/main
    check "#72-AC1 --new without origin/main creates no branch" bash -c '! "'"$real_git"'" -C "'"$repo"'" show-ref --verify --quiet refs/heads/feat/m'
}

test_ac1_1_inputs() {
    new_repo
    local b
    for b in 'x y' 'a..b' '-x' '--foo' 'a/' $'a\tb' $'a\nb' $'a\x01b' $'a\x7fb' '' ' ' 'a:b' 'a~1' 'a^b' 'a?b' 'a*b' 'a[b' 'a\b' '.a' 'a/.b' 'a//b' 'a.lock' '/a' 'a@{b' 'a;b' 'a$b'; do
        w add "$b"
        check "#72-AC1.1 refuses [$(printf '%q' "$b")] with exit 2" rc_is 2
        check "#72-AC1.1 [$(printf '%q' "$b")] makes no git call" bash -c '[ ! -s "'"$sd"'/git.log" ]'
        check "#72-AC1.1 [$(printf '%q' "$b")] creates no directory" is_empty_or_absent "$wtd"
    done
    # names the character check lets through but git rejects
    for b in 'a.' 'x.lock/y' '@' 'a/b.lock'; do
        w add "$b"
        check "#72-AC1.1 git's own rules (check-ref-format) refuse [$b] with exit 2" rc_is 2
        check "#72-AC1.1 [$b] reaches no worktree call" bash -c '! grep -q worktree "'"$sd"'/git.log"'
    done
    w add -- --foo
    check "#72-AC1.1 add -- --foo is a leading dash: exit 2" rc_is 2
    w add
    check "#72-AC1.1 add without a branch: exit 2" rc_is 2
    check "#72-AC1.1 add without a branch prints the usage" says "Usage:"
    w add a b
    check "#72-AC1.1 two branches: exit 2" rc_is 2
    w add --force x
    check "#72-AC1.1 an option add doesn't have: exit 2" rc_is 2
    w
    check "#72-AC1.1 no command: exit 2" rc_is 2
    check "#72-AC1.1 the usage shows add [--new] <branch>" says "add [--new] <branch>"
    check "#72-AC1.1 the usage shows rm <branch> [--force]" says "rm <branch> [--force]"
    w frob x
    check "#72-AC1.1 an unknown command: exit 2" rc_is 2

    g branch feat/opt
    w add feat/opt
    check "#72-AC1.1 a valid branch is handed to git after --" git_log_has 'worktree add.* -- '
}

test_ac1_2_boundaries() {
    new_repo
    g branch a
    w add a
    check "#72-AC1.2 a 1-character branch works" rc_is 0
    check "#72-AC1.2 a 1-character branch is at .claude/worktrees/a" eq "$out" "$wtd/a"
    local long200 long_ok long_over len
    long200=$(printf 'b%.0s' $(seq 1 200))
    g branch "$long200"
    w add "$long200"
    check "#72-AC1.2 a 200-character branch works" rc_is 0
    check "#72-AC1.2 a 200-character branch gets its worktree" registered "$wtd/$long200"
    len=${#wtd}
    long_ok=$(printf 'c%.0s' $(seq 1 $((255 - len - 1))))
    long_over=$(printf 'd%.0s' $(seq 1 $((256 - len - 1))))
    g branch "$long_ok"
    w add "$long_ok"
    check "#72-AC1.2 a path of exactly 255 characters works" rc_is 0
    w add "$long_over"
    check "#72-AC1.2 a path of 256 characters is refused (exit 1)" rc_is 1
    check "#72-AC1.2 the refusal names the limit" says 255
    check "#72-AC1.2 the refusal names the branch" says "${long_over:0:20}"
    check "#72-AC1.2 nothing is created for it" unregistered "$wtd/$long_over"
    check "#72-AC1.2 no directory is left for it" test ! -e "$wtd/$long_over"
}

test_ac1_3_state() {
    new_repo
    g worktree add -q -b feat/o "$work/hand$n"
    w add feat/o
    check "#72-AC1.3 a branch checked out in another worktree refuses (exit 1)" rc_is 1
    check "#72-AC1.3 it names the other worktree's path" says "$work/hand$n"
    check "#72-AC1.3 it creates nothing" is_empty_or_absent "$wtd"
    w add main
    check "#72-AC1.3 the branch checked out in the main copy refuses (exit 1)" rc_is 1
    check "#72-AC1.3 it names the main copy" says "$root"

    new_repo
    g branch feat/p
    mkdir -p "$wtd/feat-p"
    echo keep >"$wtd/feat-p/f"
    w add feat/p
    check "#72-AC1.3 a target path that already exists refuses (exit 1)" rc_is 1
    check "#72-AC1.3 it names the path" says "$wtd/feat-p"
    check "#72-AC1.3 what was there stays" eq "$(cat "$wtd/feat-p/f" 2>/dev/null)" keep
    check "#72-AC1.3 it is not registered" unregistered "$wtd/feat-p"

    new_repo
    w add feat/nope
    check "#72-AC1.3 a branch that doesn't exist refuses (exit 1)" rc_is 1
    check "#72-AC1.3 it says the branch doesn't exist" says "does not exist"
    check "#72-AC1.3 it points at --new" says "--new"
    check "#72-AC1.3 it creates nothing" is_empty_or_absent "$wtd"

    new_repo
    g branch feat/i
    w add feat/i
    echo mine >"$wtd/feat-i/mine.txt"
    local list_before list_after
    list_before=$(g worktree list --porcelain)
    w add feat/i
    list_after=$(g worktree list --porcelain)
    check "#72-AC1.3 a second add exits 0" rc_is 0
    check "#72-AC1.3 a second add says already exists: <path>" says "already exists: $wtd/feat-i"
    check "#72-AC1.3 a second add prints the path as its stdout" eq "$out" "already exists: $wtd/feat-i"
    check "#72-AC1.3 a second add changes nothing in git" eq "$list_after" "$list_before"
    check "#72-AC1.3 a second add leaves the worktree's files alone" test -f "$wtd/feat-i/mine.txt"
    w add feat/i
    check "#72-AC1.7 a third add repeats the answer" eq "$out" "already exists: $wtd/feat-i"

    new_repo
    g branch a-b
    g branch a/b
    w add a-b
    w add a/b
    check "#72-AC1.3 two branches mapping to the same path: the second refuses (exit 1)" rc_is 1
    check "#72-AC1.3 it names the branch that holds the path" says a-b
    check "#72-AC1.3 the first worktree is still there" registered "$wtd/a-b"
}

test_ac1_5_concurrency() {
    local i rcs
    for i in 1 2 3 4 5; do
        new_repo
        g branch feat/c
        (runw "$work/c1" add feat/c) &
        (runw "$work/c2" add feat/c) &
        wait
        rcs="$(cat "$work/c1.rc") $(cat "$work/c2.rc")"
        check "#72-AC1.5 [$i] two adds for one branch: one exit 0, the other 0 or 1 ($rcs)" bash -c 'case "'"$rcs"'" in "0 0" | "0 1" | "1 0") true ;; *) false ;; esac'
        check "#72-AC1.5 [$i] exactly one worktree was created" eq "$(nwt)" 2
        check "#72-AC1.5 [$i] its checkout is complete" test -f "$wtd/feat-c/file.txt"
        check "#72-AC1.5 [$i] no other directory is left under .claude/worktrees" eq "$(ls -A "$wtd")" feat-c
        check "#72-AC1.5 [$i] a loser with exit 1 gives one line naming the problem" bash -c 'for k in 1 2; do if [ "$(cat "'"$work"'/c$k.rc")" = 1 ]; then [ -s "'"$work"'/c$k.err" ] || exit 1; fi; done'
    done
    for i in 1 2 3; do
        new_repo
        (runw "$work/c1" add --new feat/q) &
        (runw "$work/c2" add --new feat/q) &
        wait
        rcs="$(cat "$work/c1.rc") $(cat "$work/c2.rc")"
        check "#72-AC1.5 [new $i] two adds with --new: not both refused ($rcs)" bash -c 'case "'"$rcs"'" in "0 0" | "0 1" | "1 0") true ;; *) false ;; esac'
        check "#72-AC1.5 [new $i] exactly one worktree was created" eq "$(nwt)" 2
        check "#72-AC1.5 [new $i] the winner's checkout is complete" test -f "$wtd/feat-q/file.txt"
        check "#72-AC1.5 [new $i] no other directory is left" eq "$(ls -A "$wtd")" feat-q
    done
}

test_ac1_6_partial() {
    new_repo
    g branch feat/f
    mkdir -p "$wtd/other"
    echo mine >"$wtd/other/f"
    WT_GIT_FAIL=add-partial w add feat/f
    check "#72-AC1.6 a failed git worktree add exits 1" rc_is 1
    check "#72-AC1.6 the failure is reported (stderr is not empty)" err_nonempty
    check "#72-AC1.6 no directory is left for the branch" test ! -e "$wtd/feat-f"
    check "#72-AC1.6 a directory that was there before is not touched" eq "$(cat "$wtd/other/f" 2>/dev/null)" mine
    check "#72-AC1.6 nothing is registered" eq "$(nwt)" 1

    new_repo
    g branch feat/f
    WT_GIT_FAIL=add-partial w add feat/f
    check "#72-AC1.6 with no .claude/worktrees before: nothing is left under it" is_empty_or_absent "$wtd"
    w add feat/f
    check "#72-AC1.6 the add works once git does" rc_is 0
}

test_ac1_9_environment() {
    new_repo
    g branch feat/a
    g branch feat/b
    w add feat/a
    WCWD="$wtd/feat-a" w add feat/b
    check "#72-AC1.9 from inside another worktree: exit 0" rc_is 0
    check "#72-AC1.9 from inside another worktree the path is under the main copy's .claude/worktrees" eq "$out" "$wtd/feat-b"
    check "#72-AC1.9 worktrees never nest" test ! -e "$wtd/feat-a/.claude"
    mkdir -p "$repo/sub/dir"
    g branch feat/c
    WCWD="$repo/sub/dir" w add feat/c
    check "#72-AC1.9 from a subdirectory of the main copy: the same root" eq "$out" "$wtd/feat-c"
    check "#72-AC1.9 nothing was made under the subdirectory" test ! -e "$repo/sub/dir/.claude"
    WCWD="$work" w add feat/c
    check "#72-AC1.9 outside any repository: refuses (exit 1)" rc_is 1
    check "#72-AC1.9 outside any repository: says it is not in a git repository" says "not in a git repository"
}

# a tag called origin/main or origin/<branch> must not be taken for the remote-tracking ref
test_ac1_decoy_tags() {
    local other
    new_repo
    other=$(g commit-tree -m decoy "$(g rev-parse 'main^{tree}')")
    g tag origin/main "$other"
    w add --new feat/n
    check "#72-AC1.3 a tag named origin/main: add --new exits 0" rc_is 0
    check "#72-AC1.3 a tag named origin/main: starts from refs/remotes/origin/main, not the tag" eq "$("$real_git" -C "$wtd/feat-n" rev-parse HEAD 2>/dev/null)" "$(g rev-parse refs/remotes/origin/main)"

    new_repo
    "$real_git" clone -q "$origin" "$work/clone$n"
    "$real_git" -C "$work/clone$n" switch -q -c feat/r
    echo r >"$work/clone$n/r.txt"
    "$real_git" -C "$work/clone$n" add r.txt
    "$real_git" -C "$work/clone$n" commit -qm r
    "$real_git" -C "$work/clone$n" push -q origin feat/r
    g fetch -q origin
    other=$(g commit-tree -m decoy "$(g rev-parse 'main^{tree}')")
    g tag origin/feat/r "$other"
    w add feat/r
    check "#72-AC1.3 a tag named origin/feat/r: add of a remote-only branch exits 0" rc_is 0
    check "#72-AC1.3 a tag named origin/feat/r: checked out at the remote-tracking commit, not the tag" eq "$("$real_git" -C "$wtd/feat-r" rev-parse HEAD 2>/dev/null)" "$(g rev-parse refs/remotes/origin/feat/r)"
    check "#72-AC1.3 a tag named origin/feat/r: still tracks origin/feat/r" eq "$("$real_git" -C "$wtd/feat-r" rev-parse --symbolic-full-name '@{u}' 2>/dev/null)" refs/remotes/origin/feat/r

    # a tag named like the branch makes git's own name lookup ambiguous: refuse, never check out the tag's commit
    new_repo
    g branch feat/t
    other=$(g commit-tree -m decoy "$(g rev-parse 'main^{tree}')")
    g tag feat/t "$other"
    w add feat/t
    check "#72-AC1.3 a tag named like the local branch: add refuses (exit 1)" rc_is 1
    check "#72-AC1.3 a tag named like the local branch: says a tag has that name" says "a tag named feat/t"
    check "#72-AC1.3 a tag named like the local branch: nothing is created" is_empty_or_absent "$wtd"
}

# git's own environment (GIT_DIR, GIT_WORK_TREE, as inside a hook) points at the main copy, never at a worktree
test_ac1_9_git_environment() {
    new_repo
    plain_wt feat/g
    wcommit unpushed.txt
    W_GIT_DIR="$repo/.git" W_GIT_WORK_TREE="$repo" w rm feat/g
    check "#72-AC2.9 GIT_DIR and GIT_WORK_TREE set: a worktree with an unpushed commit still refuses (exit 1)" rc_is 1
    check "#72-AC2.9 GIT_DIR and GIT_WORK_TREE set: the refusal counts the commit" says "1 unpushed commit"
    check "#72-AC2.9 GIT_DIR and GIT_WORK_TREE set: the worktree stays" registered "$wt"

    new_repo
    plain_wt feat/h
    echo dirty >"$wt/file.txt"
    W_GIT_DIR="$repo/.git" W_GIT_WORK_TREE="$repo" w rm feat/h
    check "#72-AC2.9 GIT_DIR and GIT_WORK_TREE set: a dirty worktree still refuses (exit 1)" rc_is 1
    check "#72-AC2.9 GIT_DIR and GIT_WORK_TREE set: the refusal counts the file" says "1 uncommitted file"

    new_repo
    g branch feat/a
    W_GIT_DIR="$repo/.git" W_GIT_WORK_TREE="$repo" w add feat/a
    check "#72-AC1.9 GIT_DIR and GIT_WORK_TREE set: add exits 0" rc_is 0
    check "#72-AC1.9 GIT_DIR and GIT_WORK_TREE set: the branch is checked out in the new worktree" eq "$("$real_git" -C "$wtd/feat-a" symbolic-ref --short HEAD 2>/dev/null)" feat/a
    check "#72-AC1.9 GIT_DIR and GIT_WORK_TREE set: the main copy is untouched" main_untouched
}

test_ac1_10_observability() {
    new_repo
    g worktree add -q -b feat/o "$work/hand$n"
    mkdir -p "$wtd/feat-p"
    g branch feat/p
    local case_
    for case_ in "feat/o" "feat/nope" "feat/p" "main"; do
        w add "$case_"
        check "#72-AC1.10 refusal for [$case_] is one line" one_line
        check "#72-AC1.10 refusal for [$case_] names the branch" says "$case_"
        check "#72-AC1.10 refusal for [$case_] exits 1" rc_is 1
    done
    w add 'x y'
    check "#72-AC1.10 a malformed name's refusal is one line naming the name" one_line
    check "#72-AC1.10 a malformed name's refusal says why" says "x y"
}

test_ac1_8_permissions() {
    new_repo
    g branch feat/g
    : >"$sd/gh.log"
    w add feat/g
    check "#72-AC1.8 add makes no gh call" test ! -s "$sd/gh.log"
    check "#72-AC1.8 add makes no network git call" bash -c '! grep -E "(^| )(fetch|pull|push|ls-remote|clone)( |$)" "'"$sd"'/git.log"'
    WT_GIT_FAIL=network w add --new feat/h
    check "#72-AC1.8 add works with the network down" rc_is 0
}

# ---- #72-AC2: rm --------------------------------------------------------------------------------------------------

test_ac2_clean() {
    new_repo
    plain_wt feat/c
    local sha
    sha=$(g rev-parse feat/c)
    w rm feat/c
    check "#72-AC2 a clean pushed worktree is removed: exit 0" rc_is 0
    check "#72-AC2 the directory is gone" test ! -e "$wtd/feat-c"
    check "#72-AC2 git no longer lists it" unregistered "$wtd/feat-c"
    check "#72-AC2 the branch itself stays" eq "$(g rev-parse feat/c)" "$sha"
    check "#72-AC2 it says what it removed" says "removed: $wtd/feat-c"
    check "#72-AC2 the main copy is untouched" main_untouched

    new_repo
    plain_wt feat/d
    echo changed >"$wt/file.txt"
    w rm feat/d
    check "#72-AC2 a tracked file changed: refuses (exit 1)" rc_is 1
    check "#72-AC2 a tracked file changed: says 1 uncommitted file" says "1 uncommitted file"
    check "#72-AC2 a tracked file changed: the worktree stays" registered "$wt"
    check "#72-AC2 a tracked file changed: the change stays" eq "$(cat "$wt/file.txt")" changed
    w rm --force feat/d
    check "#72-AC2 --force removes a dirty worktree (exit 0)" rc_is 0
    check "#72-AC2 --force: the directory is gone" test ! -e "$wt"
    check "#72-AC2 --force: git no longer lists it" unregistered "$wt"

    new_repo
    plain_wt feat/e
    echo changed >"$wt/file.txt"
    w rm feat/e --force
    check "#72-AC2 --force after the branch works too" rc_is 0

    new_repo
    plain_wt feat/f
    : >"$sd/gh.log"
    w rm feat/f
    check "#72-AC2.8 rm makes no gh call" test ! -s "$sd/gh.log"
}

test_ac2_2_boundaries() {
    new_repo
    plain_wt feat/u
    echo one >"$wt/new.txt"
    w rm feat/u
    check "#72-AC2.2 exactly one untracked file refuses (exit 1)" rc_is 1
    check "#72-AC2.2 one untracked file: says 1 uncommitted file" says "1 uncommitted file"
    check "#72-AC2.2 one untracked file: the worktree stays" registered "$wt"
    check "#72-AC2.2 one untracked file: the file stays" test -f "$wt/new.txt"

    new_repo
    plain_wt feat/p
    wcommit one.txt
    w rm feat/p
    check "#72-AC2.2 exactly one unpushed commit refuses (exit 1)" rc_is 1
    check "#72-AC2.2 one unpushed commit: says 1 unpushed commit" says "1 unpushed commit"
    check "#72-AC2.2 one unpushed commit: the worktree stays" registered "$wt"
    wpush
    w rm feat/p
    check "#72-AC2.2 the same commit once pushed: removed (exit 0)" rc_is 0

    new_repo
    plain_wt feat/two
    wcommit a.txt
    wcommit b.txt
    w rm feat/two
    check "#72-AC2.2 two unpushed commits: plural" says "2 unpushed commits"
    w rm --force feat/two
    check "#72-AC2.2 --force removes a worktree with unpushed commits (exit 0)" rc_is 0
    check "#72-AC2.2 --force: the unpushed commits stay reachable from the branch" eq "$(g rev-list --count main..feat/two)" 2

    new_repo
    plain_wt feat/i
    echo "node_modules/" >"$wt/.gitignore"
    "$real_git" -C "$wt" add .gitignore
    "$real_git" -C "$wt" commit -qm ignore
    wpush
    mkdir -p "$wt/node_modules/pkg"
    echo junk >"$wt/node_modules/pkg/index.js"
    w rm feat/i
    check "#72-AC2.2 a worktree with only ignored files counts as clean (exit 0)" rc_is 0
    check "#72-AC2.2 ignored files: the directory is gone" test ! -e "$wt"
}

test_ac2_3_state() {
    new_repo
    w rm feat/none
    check "#72-AC2.3 a branch with no worktree: exit 0" rc_is 0
    check "#72-AC2.3 a branch with no worktree: says nothing to remove" says "nothing to remove"

    # a squash-merged branch: remote branch deleted, its commits in origin/main
    new_repo
    plain_wt feat/s
    wcommit s.txt
    wpush
    g merge -q --ff-only feat/s
    g push -q origin main
    g push -q origin :feat/s
    g fetch -q --prune origin
    w rm feat/s
    check "#72-AC2.3 remote branch deleted, commits all in origin/main: counts as pushed (exit 0)" rc_is 0
    check "#72-AC2.3 that worktree is gone" test ! -e "$wt"

    new_repo
    plain_wt feat/t
    wcommit t.txt
    wpush
    g push -q origin :feat/t
    g fetch -q --prune origin
    w rm feat/t
    check "#72-AC2.3 remote branch deleted, commits in no remote: refuses (exit 1)" rc_is 1
    check "#72-AC2.3 that refusal counts the commit" says "1 unpushed commit"

    new_repo
    plain_wt feat/d
    "$real_git" -C "$wt" checkout -q --detach
    w rm feat/d
    check "#72-AC2.3 a detached HEAD worktree refuses (exit 1)" rc_is 1
    check "#72-AC2.3 a detached HEAD worktree: says detached" says "detached"
    check "#72-AC2.3 a detached HEAD worktree: stays" registered "$wt"
    w rm --force feat/d
    check "#72-AC2.3 a detached HEAD worktree: --force removes it (exit 0)" rc_is 0
    check "#72-AC2.3 a detached HEAD worktree: gone" test ! -e "$wt"

    new_repo
    plain_wt feat/l
    g worktree lock --reason test "$wt"
    w rm feat/l
    check "#72-AC2 a locked worktree refuses (exit 1)" rc_is 1
    check "#72-AC2 a locked worktree: says locked" says "locked"
    w rm --force feat/l
    check "#72-AC2 --force never removes a locked worktree (exit 1)" rc_is 1
    check "#72-AC2 --force and locked: says locked" says "locked"
    check "#72-AC2 a locked worktree stays registered" registered "$wt"
    check "#72-AC2 a locked worktree's directory stays" test -f "$wt/file.txt"

    new_repo
    plain_wt feat/w
    WCWD="$wt" w rm feat/w
    check "#72-AC2 the caller's current directory refuses (exit 1)" rc_is 1
    check "#72-AC2 current directory: says so" says "current directory"
    check "#72-AC2 current directory: the worktree stays" test -f "$wt/file.txt"
    WCWD="$wt" w rm --force feat/w
    check "#72-AC2 --force never removes the current directory (exit 1)" rc_is 1
    mkdir -p "$wt/sub/deep"
    WCWD="$wt/sub/deep" w rm --force feat/w
    check "#72-AC2 a directory below the worktree counts as inside (exit 1)" rc_is 1
    check "#72-AC2 below the worktree: it stays" registered "$wt"
    w rm feat/w
    check "#72-AC2 from outside it can go (exit 0)" rc_is 0
}

test_ac2_1_inputs() {
    new_repo
    plain_wt feat/k
    local b
    for b in '/tmp/x' "$wt" './feat-k' '../x' '.claude/worktrees/feat-k' 'x y' '-x' 'a..b' 'a/' '' $'a\tb'; do
        w rm "$b"
        check "#72-AC2.1 rm [$(printf '%q' "$b")] (a path or a bad name) exits 2" rc_is 2
        check "#72-AC2.1 rm [$(printf '%q' "$b")] makes no git call" bash -c '[ ! -s "'"$sd"'/git.log" ]'
    done
    check "#72-AC2.1 the worktree is still there" registered "$wt"
    w rm
    check "#72-AC2.1 rm without a branch: exit 2" rc_is 2
    w rm a b
    check "#72-AC2.1 rm with two branches: exit 2" rc_is 2
    w rm --new feat/k
    check "#72-AC2.1 rm with an option it doesn't have: exit 2" rc_is 2
    w rm -- --foo
    check "#72-AC2.1 rm -- --foo: exit 2" rc_is 2
    check "#72-AC2.1 the worktree is still there after all of it" registered "$wt"
}

test_ac2_5_concurrency() {
    local i
    for i in 1 2 3 4 5; do
        new_repo
        plain_wt feat/r
        (runw "$work/c1" rm feat/r) &
        (runw "$work/c2" rm feat/r) &
        wait
        check "#72-AC2.5 [$i] both rm runs exit 0" bash -c '[ "$(cat "'"$work"'/c1.rc")" = 0 ] && [ "$(cat "'"$work"'/c2.rc")" = 0 ]'
        check "#72-AC2.5 [$i] exactly one says removed" eq "$(cat "$work/c1.out" "$work/c2.out" | grep -c '^removed: ')" 1
        check "#72-AC2.5 [$i] the other says nothing to remove" eq "$(cat "$work/c1.out" "$work/c2.out" | grep -c 'nothing to remove')" 1
        check "#72-AC2.5 [$i] the worktree is gone" test ! -e "$wt"
        check "#72-AC2.5 [$i] git doesn't list it" unregistered "$wt"
    done
}

test_ac2_6_partial() {
    new_repo
    plain_wt feat/a
    g worktree add -q -b feat/stale "$work/stale$n"
    rm -rf "$work/stale$n"
    WT_GIT_FAIL=remove-after-delete w rm feat/a
    check "#72-AC2.6 a failure while deleting exits 1" rc_is 1
    check "#72-AC2.6 never a registered entry with a missing directory" bash -c '! { "'"$real_git"'" -C "'"$repo"'" worktree list --porcelain | grep -qxF "worktree '"$wt"'"; } || [ -d "'"$wt"'" ]'
    check "#72-AC2.6 the entry it removed is gone from git" unregistered "$wt"
    check "#72-AC2.6 another worktree's stale entry is not pruned (only what it removed)" registered "$work/stale$n"
    check "#72-AC2.6 the failure is reported" says "failed"

    if [ "$(id -u)" -ne 0 ]; then
        new_repo
        plain_wt feat/b
        echo "junk/" >"$wt/.gitignore"
        "$real_git" -C "$wt" add .gitignore
        "$real_git" -C "$wt" commit -qm ignore
        wpush
        mkdir -p "$wt/junk"
        echo x >"$wt/junk/f"
        chmod 555 "$wt/junk"
        w rm feat/b
        chmod -R u+rwx "$wt/junk" 2>/dev/null
        check "#72-AC2.6 a real deletion failure exits 1" rc_is 1
        check "#72-AC2.6 a real deletion failure: registered with its directory, or neither" bash -c '
            if "'"$real_git"'" -C "'"$repo"'" worktree list --porcelain | grep -qxF "worktree '"$wt"'"; then [ -d "'"$wt"'" ]; else true; fi'
    else
        echo "note: running as root, so the permission-based deletion failure case is skipped"
    fi
}

test_ac2_7_idempotence() {
    new_repo
    plain_wt feat/i
    w rm feat/i
    w rm feat/i
    check "#72-AC2.7 a second rm of a removed worktree exits 0" rc_is 0
    check "#72-AC2.7 a second rm says nothing to remove" says "nothing to remove"
    w rm feat/i
    check "#72-AC2.7 a third rm repeats it" says "nothing to remove"
}

test_ac2_9_environment() {
    new_repo
    plain_wt feat/o
    g remote set-url origin "$work/does-not-exist.git"
    wcommit local.txt
    w rm feat/o
    check "#72-AC2.9 with an unreachable origin an unpushed commit still refuses (exit 1)" rc_is 1
    check "#72-AC2.9 the refusal says the check uses the remote-tracking refs present locally" says "remote-tracking refs present locally"
    new_repo
    plain_wt feat/n
    g remote set-url origin "$work/does-not-exist.git"
    WT_GIT_FAIL=network w rm feat/n
    check "#72-AC2.9 with the network down a pushed worktree is removed (exit 0)" rc_is 0
    check "#72-AC2.9 rm makes no network git call" bash -c '! grep -E "(^| )(fetch|pull|push|ls-remote|clone)( |$)" "'"$sd"'/git.log"'
    check "#72-AC2.9 the removal says the check used the remote-tracking refs present locally" says "remote-tracking refs present locally"
}

test_ac2_10_observability() {
    new_repo
    plain_wt feat/m
    wcommit committed.txt
    echo TOPSECRETCONTENT >"$wt/secret-name.txt"
    echo more >"$wt/more.txt"
    echo changed >"$wt/file.txt"
    w rm feat/m
    check "#72-AC2.10 the refusal lists what blocks it: 3 uncommitted files, 1 unpushed commit" says "3 uncommitted files, 1 unpushed commit"
    check "#72-AC2.10 the refusal names the branch" says feat/m
    check "#72-AC2.10 the refusal never shows file contents" silent_on TOPSECRETCONTENT
    check "#72-AC2.10 the refusal never shows file names" silent_on secret-name
    check "#72-AC2.10 the refusal exits 1" rc_is 1
    check "#72-AC2.10 the refusal is the reason line plus the note (at most 2 lines)" err_lines_at_most 2
}

# ---- #72-AC3: path safety -----------------------------------------------------------------------------------------

test_ac3_symlinks() {
    new_repo
    mkdir -p "$work/outside$n"
    echo precious >"$work/outside$n/keep"
    mkdir -p "$wtd"
    ln -s "$work/outside$n" "$wtd/feat-l"
    w rm feat/l
    check "#72-AC3.1 a symlink to a directory outside refuses (exit 1)" rc_is 1
    check "#72-AC3.1 a symlink out: prints the resolved path" says "$work/outside$n"
    check "#72-AC3.1 a symlink out: prints the directory it must be under" says "$wtd"
    check "#72-AC3.1 a symlink out: deletes nothing there" eq "$(cat "$work/outside$n/keep")" precious
    check "#72-AC3.1 a symlink out: the link stays" test -L "$wtd/feat-l"
    local first
    first="$out|$err|$rc"
    w rm feat/l
    check "#72-AC3.7 the refusal repeats identically" eq "$out|$err|$rc" "$first"
    w rm --force feat/l
    check "#72-AC3.1 --force does not change it (exit 1)" rc_is 1
    check "#72-AC3.1 --force: still deletes nothing" eq "$(cat "$work/outside$n/keep")" precious

    new_repo
    mkdir -p "$wtd"
    ln -s "$root" "$wtd/feat-l"
    w rm feat/l
    check "#72-AC3.1 a symlink to the repository root refuses (exit 1)" rc_is 1
    check "#72-AC3.1 a symlink to the root: prints the resolved path" says "$root"
    check "#72-AC3.1 a symlink to the root: the repository is intact" test -d "$root/.git"
    check "#72-AC3.1 a symlink to the root: the files are intact" test -f "$root/file.txt"

    new_repo
    plain_wt feat/sib
    ln -s "$wt" "$wtd/feat-l"
    w rm feat/l
    check "#72-AC3.1 a symlink to another worktree's directory refuses (exit 1)" rc_is 1
    check "#72-AC3.1 a symlink to a sibling: the sibling stays registered" registered "$wt"
    check "#72-AC3.1 a symlink to a sibling: its files stay" test -f "$wt/file.txt"
    check "#72-AC3.1 a symlink to a sibling: the link stays" test -L "$wtd/feat-l"

    new_repo
    mkdir -p "$work/outside$n"
    echo precious >"$work/outside$n/keep"
    mkdir -p "$root/.claude"
    ln -s "$work/outside$n" "$root/.claude/worktrees"
    g branch feat/x
    w add feat/x
    check "#72-AC3 add refuses when .claude/worktrees is a symlink out (exit 1)" rc_is 1
    check "#72-AC3 add via a symlinked .claude/worktrees creates nothing outside" eq "$(ls -A "$work/outside$n")" keep
}

# a worktree registered at a path other than the one its branch name gives, reached through a symlinked .claude or
# .claude/worktrees: rm compares with the literal <root>/.claude/worktrees/, never a resolved one
test_ac3_rm_symlinked_parents() {
    local elsewhere

    new_repo
    g worktree add -q -b nested "$root/sub"
    mkdir -p "$root/.claude"
    ln -s .. "$root/.claude/worktrees"
    w rm nested
    check "#72-AC3.1 .claude/worktrees -> .. : rm refuses (exit 1)" rc_is 1
    check "#72-AC3.10 .claude/worktrees -> .. : the refusal names the symlinked directory and where it resolves" says "$root/.claude/worktrees resolves to $root"
    check "#72-AC3.1 .claude/worktrees -> .. : the worktree at <root>/sub stays registered" registered "$root/sub"
    check "#72-AC3.1 .claude/worktrees -> .. : its files stay" test -f "$root/sub/file.txt"
    w rm --force nested
    check "#72-AC3.1 .claude/worktrees -> .. , --force: still refuses (exit 1)" rc_is 1
    check "#72-AC3.1 .claude/worktrees -> .. , --force: still there" test -f "$root/sub/file.txt"

    new_repo
    elsewhere="$work/elsewhere$n"
    mkdir -p "$elsewhere/worktrees"
    g worktree add -q -b v "$elsewhere/worktrees/other"
    ln -s "$elsewhere" "$root/.claude"
    w rm v
    check "#72-AC3.1 .claude -> /elsewhere: rm refuses (exit 1)" rc_is 1
    check "#72-AC3.10 .claude -> /elsewhere: the refusal names the symlinked directory and where it resolves" says "$root/.claude resolves to $elsewhere"
    check "#72-AC3.1 .claude -> /elsewhere: the worktree stays registered" registered "$elsewhere/worktrees/other"
    check "#72-AC3.1 .claude -> /elsewhere: its files stay" test -f "$elsewhere/worktrees/other/file.txt"
    w rm --force v
    check "#72-AC3.1 .claude -> /elsewhere, --force: still refuses (exit 1)" rc_is 1
    check "#72-AC3.1 .claude -> /elsewhere, --force: still there" test -f "$elsewhere/worktrees/other/file.txt"

    new_repo
    elsewhere="$work/elsewhere$n"
    mkdir -p "$elsewhere" "$root/.claude"
    g worktree add -q -b v "$elsewhere/other"
    ln -s "$elsewhere" "$root/.claude/worktrees"
    w rm v
    check "#72-AC3.1 .claude/worktrees -> /elsewhere: rm refuses (exit 1)" rc_is 1
    check "#72-AC3.10 .claude/worktrees -> /elsewhere: the refusal names the symlinked directory and where it resolves" says "$root/.claude/worktrees resolves to $elsewhere"
    check "#72-AC3.1 .claude/worktrees -> /elsewhere: the worktree stays registered" registered "$elsewhere/other"
    check "#72-AC3.1 .claude/worktrees -> /elsewhere: its files stay" test -f "$elsewhere/other/file.txt"
    w rm --force v
    check "#72-AC3.1 .claude/worktrees -> /elsewhere, --force: still refuses (exit 1)" rc_is 1
    check "#72-AC3.1 .claude/worktrees -> /elsewhere, --force: still there" test -f "$elsewhere/other/file.txt"

    # feat/b is registered under another name (foo), and foo was replaced by a symlink to a sibling worktree
    new_repo
    plain_wt feat/v
    echo precious >"$wt/uncommitted.txt"
    g worktree add -q -b feat/b "$wtd/foo"
    rm -rf "$wtd/foo"
    ln -s "$wtd/feat-v" "$wtd/foo"
    w rm feat/b --force
    check "#72-AC3.1 a registered path that is a symlink to a sibling worktree: refuses (exit 1)" rc_is 1
    check "#72-AC3.10 that refusal prints the resolved path" says "$wtd/feat-v"
    check "#72-AC3.10 that refusal prints the directory it must be under" says "$wtd"
    check "#72-AC3.1 the sibling stays registered" registered "$wtd/feat-v"
    check "#72-AC3.1 the sibling's committed files stay" test -f "$wtd/feat-v/file.txt"
    check "#72-AC3.1 the sibling's uncommitted file stays" eq "$(cat "$wtd/feat-v/uncommitted.txt")" precious
    check "#72-AC3.1 the link stays" test -L "$wtd/foo"
}

test_ac3_outside_and_unregistered() {
    new_repo
    g worktree add -q -b hand "$work/hand$n"
    w rm hand
    check "#72-AC3.1 a worktree registered outside .claude/worktrees refuses (exit 1)" rc_is 1
    check "#72-AC3.1 outside: prints the path it resolved" says "$work/hand$n"
    check "#72-AC3.1 outside: prints the directory it must be under" says "$wtd"
    check "#72-AC3.1 outside: it stays registered" registered "$work/hand$n"
    check "#72-AC3.1 outside: its files stay" test -f "$work/hand$n/file.txt"
    w rm --force hand
    check "#72-AC3.1 outside, --force: still refuses (exit 1)" rc_is 1
    check "#72-AC3.1 outside, --force: still there" test -f "$work/hand$n/file.txt"

    new_repo
    mkdir -p "$wtd/feat-u"
    echo mine >"$wtd/feat-u/f"
    w rm feat/u
    check "#72-AC3.3 a directory under .claude/worktrees that git doesn't know refuses (exit 1)" rc_is 1
    check "#72-AC3.3 unregistered: says it is not a registered worktree" says "not a registered worktree"
    check "#72-AC3.3 unregistered: prints the resolved path" says "$wtd/feat-u"
    check "#72-AC3.3 unregistered: its content stays" eq "$(cat "$wtd/feat-u/f")" mine
    w rm --force feat/u
    check "#72-AC3.3 unregistered, --force: still refuses (exit 1)" rc_is 1
    check "#72-AC3.3 unregistered, --force: its content stays" eq "$(cat "$wtd/feat-u/f")" mine

    new_repo
    w rm main
    check "#72-AC3 the main copy's branch refuses (exit 1)" rc_is 1
    check "#72-AC3 the main copy: says it is the main working copy" says "main working copy"
    check "#72-AC3 the main copy: untouched" main_untouched
    w rm --force main
    check "#72-AC3 the main copy, --force: refuses (exit 1)" rc_is 1
    check "#72-AC3 the main copy, --force: untouched" main_untouched

    new_repo
    : >"$sd/realpath.log"
    plain_wt feat/rp
    w rm feat/rp
    check "#72-AC3.9 the removal never calls realpath (cd -P and pwd -P instead)" test ! -s "$sd/realpath.log"
    check "#72-AC3.9 the script has no realpath call" bash -c '! grep -q "realpath" "'"$script"'"'
}

# ---- #72-AC4: documentation, CI and lint --------------------------------------------------------------------------------

test_ac4_docs() {
    local ticket_flow="$tools/../.claude/skills/ticket-flow/SKILL.md" pr_review="$tools/../.claude/skills/pr-review/SKILL.md" wf="$tools/../Docs/workflow.md"
    local usage
    usage=$(bash "$script" 2>&1)
    check "#72-AC4 the usage shows add [--new] <branch>" grep -qF "add [--new] <branch>" <<<"$usage"
    check "#72-AC4 the usage shows rm <branch> [--force]" grep -qF "rm <branch> [--force]" <<<"$usage"
    check "#72-AC4 ticket-flow tells to add the worktree with tools/wt.sh add" grep -qF "tools/wt.sh add" "$ticket_flow"
    check "#72-AC4 ticket-flow tells to remove it with tools/wt.sh rm" grep -qF "tools/wt.sh rm" "$ticket_flow"
    check "#72-AC4 pr-review uses tools/wt.sh add for its scratch worktree" grep -qF "tools/wt.sh add" "$pr_review"
    check "#72-AC4 pr-review uses tools/wt.sh rm to remove it" grep -qF "tools/wt.sh rm" "$pr_review"
    check "#72-AC4 pr-review no longer uses git worktree add" bash -c '! grep -q "git .*worktree add" "'"$pr_review"'"'
    check "#72-AC4 pr-review no longer uses git worktree remove --force" bash -c '! grep -q "worktree remove" "'"$pr_review"'"'
    check "#72-AC4 workflow.md names tools/wt.sh add" grep -qF "tools/wt.sh add" "$wf"
    check "#72-AC4 workflow.md names tools/wt.sh rm" grep -qF "tools/wt.sh rm" "$wf"
    check "#72-AC4 workflow.md lists tools/tests/wt-tools.sh" grep -qF "tools/tests/wt-tools.sh" "$wf"
    check "#72-AC4 tools/tests/wt-tools.sh is listed in the gate job" grep -qF "tools/tests/wt-tools.sh" "$tools/../.github/workflows/build.yml"
}

test_lint() {
    if command -v shellcheck >/dev/null; then
        check "#72-AC4 shellcheck: script, test file and stubs" shellcheck -x "$script" "$tools/tests/wt-tools.sh" "$stubs/git" "$stubs/gh" "$stubs/realpath"
    else
        echo "note: shellcheck is not installed here; run it on the script, test file and stubs (CI image has it)"
    fi
}

all_tests=(test_ac1_add test_ac1_1_inputs test_ac1_2_boundaries test_ac1_3_state test_ac1_5_concurrency test_ac1_6_partial test_ac1_9_environment test_ac1_decoy_tags test_ac1_9_git_environment \
    test_ac1_10_observability test_ac1_8_permissions test_ac2_clean test_ac2_2_boundaries test_ac2_3_state test_ac2_1_inputs test_ac2_5_concurrency \
    test_ac2_6_partial test_ac2_7_idempotence test_ac2_9_environment test_ac2_10_observability test_ac3_symlinks test_ac3_rm_symlinked_parents test_ac3_outside_and_unregistered \
    test_ac4_docs test_lint)
# with arguments, only those test functions run (while iterating on one fix)
[ "$#" -eq 0 ] || all_tests=("$@")
for fn in "${all_tests[@]}"; do
    echo "== $fn"
    "$fn"
done

echo
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
