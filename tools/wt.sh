#!/usr/bin/env bash
# Creates and removes a ticket's git worktree under .claude/worktrees/ (.claude/skills/ticket-flow/SKILL.md, Docs/workflow.md
# "Branches"): a worktree always lands there, `rm` never discards work that isn't pushed or committed, and a repeat run is harmless.
#
# Usage: tools/wt.sh add [--new] <branch>
#        tools/wt.sh rm <branch> [--force]
# Exit codes: 0 done or nothing to do, 1 refused or failed (the last line says why), 2 usage (a bad branch name or arguments).
# Local git only: no network and no gh call (the unpushed check reads the remote-tracking refs present locally; run
# git fetch first for a current answer). Needs git 2.31 or newer and bash.
#
# add <branch>        .claude/worktrees/<branch with / replaced by -> on that branch (a local branch, or one that exists
#                     only as origin/<branch>, which becomes a local branch tracking it), and prints its absolute path.
#                     --new makes the branch from origin/main (no upstream) instead. A second run prints "already exists:
#                     <path>" and changes nothing. It works from the main copy or from inside any worktree: the repository
#                     root comes from git's common directory, so worktrees never nest.
# rm <branch>         removes that worktree only when it is clean: no uncommitted or untracked files (ignored files don't
#                     count), no commits outside every remote-tracking ref, not locked, not in detached HEAD, and not the
#                     caller's current directory. --force removes a dirty, unpushed or detached one; it never removes a
#                     locked one, the current directory, or anything the path rules below refuse. No worktree: "nothing to
#                     remove", exit 0.
#
# Path rules for rm: it removes only a registered worktree of this repository whose real path (symlinks resolved with
# cd -P and pwd -P) is inside <repo root>/.claude/worktrees/ and is not the main working copy; it never follows a symlink
# while deleting. A refusal prints the resolved path and the directory it must be under.
set -uo pipefail
export LC_ALL=C
unset CDPATH

name_of_script=wt.sh
usage() {
    echo "Usage: $name_of_script add [--new] <branch> | rm <branch> [--force]" >&2
    exit 2
}
# show <text>: the text with anything unprintable replaced, safe for one line of output
show() { printf '%s' "$1" | tr -c '[:print:]' '?'; }
refuse() { # one line on stderr, exit 1
    echo "$name_of_script: $*" >&2
    exit 1
}
bad_name() { # one line on stderr, exit 2
    echo "$name_of_script: [$(show "$1")] is not a valid branch name: $2" >&2
    exit 2
}
plural() { # <n> <singular>: "1 file", "3 files"
    if [ "$1" -eq 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi
}
phys() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# ---- arguments -------------------------------------------------------------------------------------------------------

[ "$#" -ge 1 ] || usage
cmd="$1"
shift
new=0
force=0
branch=""
npos=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --)
            shift
            while [ "$#" -gt 0 ]; do
                branch="$1"
                npos=$((npos + 1))
                shift
            done
            break
            ;;
        --new)
            [ "$cmd" = add ] || usage
            new=1
            ;;
        --force)
            [ "$cmd" = rm ] || usage
            force=1
            ;;
        -?*)
            # a leading dash: an option this command doesn't have, or a branch that could be read as one
            usage
            ;;
        *)
            branch="$1"
            npos=$((npos + 1))
            ;;
    esac
    shift
done
case "$cmd" in
    add | rm) ;;
    *) usage ;;
esac
[ "$npos" -eq 1 ] || usage

# valid_branch <name>: letters, digits and . _ / - only, starting with a letter, digit or _, no "..", "//", trailing "/", ".lock"
# ending, or component starting with "."; git's own rules (check-ref-format) apply on top
valid_branch() {
    local b="$1"
    [ -n "$b" ] || return 1
    [[ "$b" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || return 1
    [[ "$b" != *..* && "$b" != *//* && "$b" != */ && "$b" != *.lock && "$b" != */.* ]]
}
valid_branch "$branch" || bad_name "$branch" "use letters, digits and . _ / - (no spaces, \"..\", leading dash or dot, trailing slash)"
git check-ref-format "refs/heads/$branch" 2>/dev/null || bad_name "$branch" "git refuses it (git check-ref-format)"
name="${branch//\//-}"

# ---- the repository --------------------------------------------------------------------------------------------------

# git's own environment (GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, ... as set inside a hook) would point every git call at
# another repository or at the main copy instead of the worktree it is about
# shellcheck disable=SC2046 # the list of names is meant to split
unset $(git rev-parse --local-env-vars 2>/dev/null)

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || refuse "$(show "$branch"): not in a git repository"
common=$(phys "$common") || refuse "$(show "$branch"): cannot read the repository's git directory"
[ "${common##*/}" = .git ] || refuse "$(show "$branch"): the main working copy was not found (a bare repository has none)"
root="${common%/.git}"
[ -n "$root" ] || refuse "$(show "$branch"): the main working copy was not found"
wtroot="$root/.claude/worktrees"
path="$wtroot/$name"
note_remote="note: unpushed commits are judged by the remote-tracking refs present locally (nothing was fetched)"

gitr() { git -C "$root" "$@"; }

# the registered worktrees: WT_PATH, WT_BRANCH (full ref or empty), WT_DETACHED, WT_LOCKED, index 0 is the main working copy
WT_PATH=()
WT_BRANCH=()
WT_DETACHED=()
WT_LOCKED=()
load_worktrees() {
    local field i=-1
    WT_PATH=()
    WT_BRANCH=()
    WT_DETACHED=()
    WT_LOCKED=()
    while IFS= read -r -d '' field; do
        case "$field" in
            worktree\ *)
                i=$((i + 1))
                WT_PATH[i]="${field#worktree }"
                WT_BRANCH[i]=""
                WT_DETACHED[i]=0
                WT_LOCKED[i]=0
                ;;
            branch\ *) [ "$i" -ge 0 ] && WT_BRANCH[i]="${field#branch }" ;;
            detached) [ "$i" -ge 0 ] && WT_DETACHED[i]=1 ;;
            locked*) [ "$i" -ge 0 ] && WT_LOCKED[i]=1 ;;
        esac
    done < <(gitr worktree list --porcelain -z 2>/dev/null)
}
find_by_branch() { # sets IDX (-1 when none)
    local i
    IDX=-1
    for ((i = 0; i < ${#WT_PATH[@]}; i++)); do
        if [ "${WT_BRANCH[i]}" = "refs/heads/$1" ]; then
            IDX=$i
            return 0
        fi
    done
    return 1
}
find_by_path() {
    local i
    IDX=-1
    for ((i = 0; i < ${#WT_PATH[@]}; i++)); do
        if [ "${WT_PATH[i]}" = "$1" ]; then
            IDX=$i
            return 0
        fi
    done
    return 1
}
exists() { [ -e "$1" ] || [ -L "$1" ]; }

load_worktrees
[ "${#WT_PATH[@]}" -ge 1 ] || refuse "$(show "$branch"): cannot list the repository's worktrees"

# ---- add -------------------------------------------------------------------------------------------------------------

claimed=0
finished=0
made_parent=0
cleanup_add() {
    [ "$claimed" -eq 1 ] && [ "$finished" -eq 0 ] || return 0
    # only the directory this run made, and only while it is still a plain directory at its own path
    if [ -d "$path" ] && [ ! -L "$path" ] && [ "$(phys "$path")" = "$path" ]; then
        if find_by_path "$path" 2>/dev/null; then
            gitr worktree remove --force -- "$path" >/dev/null 2>&1
        fi
        [ ! -d "$path" ] || rm -rf -- "$path"
    fi
    if [ "$made_parent" -eq 1 ]; then rmdir "$wtroot" 2>/dev/null; fi
    return 0
}

# check_parents <shown>: the directory worktrees live in must really be inside the repository (add and rm both): no symlinked
# .claude or .claude/worktrees, so the literal <root>/.claude/worktrees/ is also the real one
check_parents() {
    local p real
    for p in "$root/.claude" "$wtroot"; do
        if exists "$p"; then
            real=$(phys "$p") || refuse "$1: $p cannot be resolved"
            [ "$real" = "$p" ] || refuse "$1: $p resolves to $real, which is not the directory it must be (a real directory under $root); nothing was changed"
        fi
    done
}

do_add() {
    local b="$branch" shown other
    shown=$(show "$b")
    [ "${#path}" -le 255 ] || refuse "$shown: the path would be ${#path} characters, over the limit of 255: $path"
    check_parents "$shown"

    if find_by_path "$path"; then
        if [ "${WT_BRANCH[IDX]}" = "refs/heads/$b" ]; then
            echo "already exists: $path"
            exit 0
        fi
        other="${WT_BRANCH[IDX]#refs/heads/}"
        refuse "$shown: $path is already the worktree of ${other:-a detached HEAD}"
    fi
    if find_by_branch "$b"; then
        other="${WT_PATH[IDX]}"
        [ "$IDX" -ne 0 ] || other="$other (the main working copy)"
        refuse "$shown: already checked out in $other"
    fi
    exists "$path" && refuse "$shown: $path already exists"

    local have_local=0 have_remote=0
    gitr show-ref --verify --quiet "refs/heads/$b" && have_local=1
    gitr show-ref --verify --quiet "refs/remotes/origin/$b" && have_remote=1
    local args
    if [ "$new" -eq 1 ]; then
        if [ "$have_local" -eq 1 ] || [ "$have_remote" -eq 1 ]; then refuse "$shown: the branch already exists, so --new cannot create it (drop --new to check it out)"; fi
        gitr show-ref --verify --quiet refs/remotes/origin/main || refuse "$shown: origin/main not found: run git fetch origin first"
        args=(worktree add --no-track -b "$b" -- "$path" refs/remotes/origin/main)
    elif [ "$have_local" -eq 1 ]; then
        # git reads a bare name as a tag before a branch, so a tag of the same name would be checked out in its place
        if gitr show-ref --verify --quiet "refs/tags/$b"; then refuse "$shown: a tag named $shown exists, so git cannot tell it from the branch; delete or rename the tag"; fi
        args=(worktree add -- "$path" "$b")
    elif [ "$have_remote" -eq 1 ]; then
        args=(worktree add --track -b "$b" -- "$path" "refs/remotes/origin/$b")
    else
        refuse "$shown: the branch does not exist (locally or as origin/$shown); use --new to create it from origin/main"
    fi

    [ -d "$wtroot" ] || made_parent=1
    mkdir -p -- "$wtroot" || refuse "$shown: cannot create $wtroot"
    if ! mkdir -- "$path" 2>/dev/null; then
        # another run claimed the path first: if it already registered it for this branch, that is the answer
        load_worktrees
        if find_by_path "$path" && [ "${WT_BRANCH[IDX]}" = "refs/heads/$b" ]; then
            echo "already exists: $path"
            exit 0
        fi
        refuse "$shown: $path already exists (another run may be creating it)"
    fi
    claimed=1
    local msg
    if ! msg=$(gitr "${args[@]}" 2>&1); then
        msg=$(show "$(printf '%s\n' "$msg" | tail -n 1)")
        refuse "$shown: git worktree add failed: $msg"
    fi
    finished=1
    printf '%s\n' "$path"
    exit 0
}

# ---- rm --------------------------------------------------------------------------------------------------------------

# settled <path>: waits a moment for a concurrent run's removal to finish; true when the worktree is gone for good
settled() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        load_worktrees
        if ! find_by_path "$1" && [ ! -e "$1" ] && [ ! -L "$1" ]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# lexnorm <absolute path>: the path with . and .. components collapsed lexically (the target may no longer exist)
lexnorm() {
    local part parts out=()
    IFS=/ read -ra parts <<<"$1"
    for part in "${parts[@]}"; do
        case "$part" in
            "" | .) ;;
            ..) [ "${#out[@]}" -eq 0 ] || unset 'out[${#out[@]}-1]' ;;
            *) out+=("$part") ;;
        esac
    done
    if [ "${#out[@]}" -eq 0 ]; then echo /; else printf '/%s' "${out[@]}"; echo; fi
}

# admin_of <path>: prints git's administrative directory of exactly this worktree, found by the gitdir file inside it (an
# absolute path, or one relative to that directory when worktree.useRelativePaths is on); false when there is none
admin_of() {
    local d g
    for d in "$common"/worktrees/*/; do
        d="${d%/}"
        if [ ! -d "$d" ] || [ -L "$d" ]; then continue; fi
        [ -f "$d/gitdir" ] || continue
        g=$(<"$d/gitdir")
        case "$g" in
            /*) ;;
            *) g="$d/$g" ;;
        esac
        if [ "$(lexnorm "$g")" = "$1/.git" ]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 1
}

# drop_registration <path>: removes the git bookkeeping of exactly this worktree (no git worktree prune, which would touch
# other entries too); true when it found and removed it
drop_registration() {
    local d
    d=$(admin_of "$1") || return 1
    rm -rf -- "$d"
}

# take_lock: one rm at a time per worktree name, so two runs never both pass the checks and both report a removal; the lock is
# a directory in git's own directory holding the owner's pid. A lock whose owner is gone is never taken over (two runs could
# both take it): it is refused by name, and whoever runs this removes it
lockdir="$common/wt-sh-rm.$name.lock"
holding=0
release_lock() {
    [ "$holding" -eq 1 ] && rm -rf -- "$lockdir"
    return 0
}
take_lock() {
    local i owner
    for i in $(seq 1 100); do
        if mkdir -- "$lockdir" 2>/dev/null; then
            holding=1
            echo "$$" >"$lockdir/pid"
            return 0
        fi
        owner=$(cat "$lockdir/pid" 2>/dev/null || true)
        # an owner that finished releases the lock before it exits, so only a lock that is still there, with the same owner, after
        # the owner is seen to be gone was left behind
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null && [ "$(cat "$lockdir/pid" 2>/dev/null || true)" = "$owner" ]; then
            refuse "$(show "$branch"): $lockdir was left by a run that is gone (or that you cannot signal); if no wt.sh run is active, remove it (rm -r) and run again"
        fi
        sleep 0.1
    done
    refuse "$(show "$branch"): another wt.sh run holds $lockdir"
}

do_rm() {
    local b="$branch" shown real cwd p problems n up msg
    shown=$(show "$b")
    check_parents "$shown"
    take_lock
    load_worktrees

    # a path that is, or passes through, a symlink is never ours to delete
    if exists "$path"; then
        real=$(phys "$path") || real="(it cannot be resolved)"
        if [ "$real" != "$path" ]; then
            refuse "$shown: $path resolves to $real, which is not a plain directory under $wtroot; nothing was deleted"
        fi
    fi

    if ! find_by_branch "$b"; then
        if ! find_by_path "$path"; then
            if exists "$path"; then
                refuse "$shown: $path is not a registered worktree of this repository (git no longer lists it; a removal that failed half way leaves such a directory: delete it by hand if you are sure), so it is not ours to delete (it must be under $wtroot)"
            fi
            echo "nothing to remove: $shown has no worktree"
            exit 0
        fi
    fi
    p="${WT_PATH[IDX]}"
    if [ "$IDX" -eq 0 ] || [ "$p" = "$root" ]; then
        refuse "$shown: $p is the main working copy, never removed"
    fi
    if [ ! -d "$p" ]; then
        if settled "$p"; then
            echo "nothing to remove: $shown has no worktree"
            exit 0
        fi
        msg=$(admin_of "$p") || msg="its entry under $common/worktrees"
        refuse "$shown: registered at $p but its directory is missing; delete git's entry for it ($msg) to clear it"
    fi
    real=$(phys "$p") || refuse "$shown: $p cannot be resolved"
    # the registered path itself must be a plain directory (no symlink in it) under the literal <root>/.claude/worktrees/
    if [ "$real" != "$p" ]; then
        refuse "$shown: $p resolves to $real, which is not a plain directory under $wtroot; nothing was deleted"
    fi
    case "$p" in
        "$wtroot"/?*) ;;
        *) refuse "$shown: $p is not inside $wtroot; nothing was deleted" ;;
    esac
    [ "$real" != "$root" ] || refuse "$shown: $real is the main working copy, never removed"

    cwd=$(pwd -P)
    case "$cwd/" in
        "$real"/*) refuse "$shown: $real is the current directory (or contains it); leave it first" ;;
    esac
    if [ "${WT_LOCKED[IDX]}" -eq 1 ]; then
        refuse "$shown: $real is locked (git worktree unlock first); not removed, even with --force"
    fi

    problems=""
    if [ "${WT_DETACHED[IDX]}" -eq 1 ]; then
        problems="detached HEAD"
    fi
    if ! n=$(git -C "$real" status --porcelain -z --no-renames --untracked-files=all 2>/dev/null | tr -cd '\0' | wc -c); then
        settled "$p" && { echo "nothing to remove: $shown has no worktree"; exit 0; }
        refuse "$shown: could not read the status of $real; not removed"
    fi
    n=$((n + 0))
    if [ "$n" -gt 0 ]; then
        problems="${problems:+$problems, }$(plural "$n" "uncommitted file")"
    fi
    if ! up=$(git -C "$real" rev-list --count HEAD --not --remotes 2>/dev/null); then
        settled "$p" && { echo "nothing to remove: $shown has no worktree"; exit 0; }
        refuse "$shown: could not count the unpushed commits of $real; not removed"
    fi
    up=$((up + 0))
    if [ "$up" -gt 0 ]; then
        problems="${problems:+$problems, }$(plural "$up" "unpushed commit")"
    fi
    if [ -n "$problems" ] && [ "$force" -eq 0 ]; then
        echo "$name_of_script: $shown: not removed ($real): $problems (--force removes it anyway)" >&2
        echo "$note_remote" >&2
        exit 1
    fi

    local rargs=(worktree remove)
    [ "$force" -eq 1 ] && rargs+=(--force)
    if msg=$(gitr "${rargs[@]}" -- "$real" 2>&1); then
        echo "removed: $real"
        echo "$note_remote"
        exit 0
    fi
    # git failed: another run may have removed it, or the deletion stopped half way
    if settled "$p"; then
        echo "nothing to remove: $shown has no worktree"
        exit 0
    fi
    msg=$(show "$(printf '%s\n' "$msg" | tail -n 1)")
    if find_by_path "$p"; then
        # still registered: with its directory gone the stale entry is cleared (only this one), otherwise it is left as it was
        if [ ! -e "$p" ]; then
            drop_registration "$p" && msg="$msg (the stale registration was cleared)"
        else
            msg="$msg (the worktree is still registered)"
        fi
        refuse "$shown: git worktree remove failed: $msg"
    fi
    # git dropped the registration but could not delete everything: finish it here (never through a symlink), or say what is left
    if [ -d "$real" ] && [ ! -L "$real" ] && [ "$(phys "$real")" = "$real" ]; then
        # find does not follow symlinks; every directory gets owner access first, so a read-only one does not stop the deletion
        find "$real" -type d -exec chmod u+rwx {} \; 2>/dev/null
        if rm -rf -- "$real" 2>/dev/null && [ ! -e "$real" ]; then
            echo "removed: $real"
            echo "$note_remote"
            exit 0
        fi
    fi
    if [ -e "$real" ]; then
        refuse "$shown: git worktree remove failed: $msg; git no longer lists the worktree, but $real still holds files: delete it by hand"
    fi
    refuse "$shown: git worktree remove failed: $msg"
}

case "$cmd" in
    add)
        trap cleanup_add EXIT
        trap 'exit 130' INT TERM
        do_add
        ;;
    rm)
        trap release_lock EXIT
        trap 'exit 130' INT TERM
        do_rm
        ;;
esac
