#!/bin/bash
# Builds the synthetic benchmark tree (Benchmarks/maketree/maketree.c):
# about a million entries shaped like a developer's home folder, the same
# for the same seed, timestamps included. Put it outside your home folder,
# for example under $TMPDIR, and delete it with rm -rf when you're done.
#
# Usage: Benchmarks/make-tree.sh [--shape home|flat|deep] [--seed N] [--scale F] [--repos N] DIR
#   DIR must not exist yet. At the default scale the home tree has 998,622
#   entries and takes 4.0 GB on disk; the script checks for 8 GB free
#   (scaled) before it starts.
#   --shape flat makes one folder of a million entries, --shape deep 100
#   chains of 1,000 nested folders; both are much smaller on disk.
#   --repos N adds N real git repositories under Work/repos, each with
#   three worktrees where Claude Code puts them: one clean on a branch, one
#   with an uncommitted change, one with a commit on no branch. A full
#   scan then runs real worktree audits. Commit and reflog dates and file
#   times are fixed (2025-12-01 12:00 UTC), and git runs without the
#   machine's configuration, so the audits give the same verdicts on any
#   later day. Off by default, so the walk benchmarks keep their tree.

set -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
options=()
dir=
scale=1
repos=0

while [ $# -gt 0 ]; do
    case $1 in
        --seed|--shape) options[${#options[@]}]=$1; options[${#options[@]}]=$2; shift 2 ;;
        --scale) scale=$2; options[${#options[@]}]=--scale; options[${#options[@]}]=$2; shift 2 ;;
        --repos) repos=$2; shift 2 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "make-tree.sh: unknown option $1" >&2; exit 2 ;;
        *) dir=$1; shift ;;
    esac
done
usage="usage: Benchmarks/make-tree.sh [--shape home|flat|deep] [--seed N] [--scale F] [--repos N] DIR"
if [ -z "$dir" ]; then
    echo "$usage" >&2
    exit 2
fi
case $repos in *[!0-9]*|"") echo "$usage" >&2; exit 2 ;; esac
if [ -e "$dir" ]; then
    echo "make-tree.sh: $dir exists already; pick a new folder" >&2
    exit 1
fi
parent=$(dirname "$dir")
mkdir -p "$parent" || exit 1

free_kb=$(df -k "$parent" | awk 'NR == 2 { print $4 }')
needed_kb=$(awk -v scale="$scale" 'BEGIN { n = 8000000 * scale; printf "%d", (n < 200000 ? 200000 : n) }')
for number in "$free_kb" "$needed_kb"; do
    case $number in
        *[!0-9]*|"") echo "make-tree.sh: can't tell the free space next to $dir" >&2; exit 1 ;;
    esac
done
if [ "$free_kb" -lt "$needed_kb" ]; then
    echo "make-tree.sh: $((free_kb / 1000000)) GB free next to $dir, need $((needed_kb / 1000000)) GB" >&2
    exit 1
fi

maketree="$repo/.build/benchmarks/maketree"
mkdir -p "$(dirname "$maketree")"
clang -std=c11 -O2 -Wall -Wextra -o "$maketree" "$here/maketree/maketree.c" || exit 1

echo "Making the tree in $dir ($((free_kb / 1000000)) GB free)..." >&2
start=$(date +%s)
"$maketree" "${options[@]}" "$dir" || exit 1

# MARK: Real repositories

# git without the machine's or the user's configuration, without
# background maintenance, and with fixed names and dates.
fixed="2025-12-01T12:00:00Z"
git_fixed() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        GIT_AUTHOR_NAME=bench GIT_AUTHOR_EMAIL=bench@example.invalid GIT_AUTHOR_DATE=$fixed \
        GIT_COMMITTER_NAME=bench GIT_COMMITTER_EMAIL=bench@example.invalid GIT_COMMITTER_DATE=$fixed \
        git -c maintenance.auto=false -c gc.auto=0 -c core.fsmonitor=false -c init.defaultBranch=main "$@"
}

if [ "$repos" -gt 0 ]; then
    command -v git >/dev/null || { echo "make-tree.sh: --repos needs git" >&2; exit 1; }
    # Adding Work/repos changes Work's time, which maketree fixed: keep it.
    work_time=$(TZ=UTC date -r "$(stat -f %m "$dir/Work")" +%Y%m%d%H%M.%S) || exit 1
    mkdir -p "$dir/Work/repos" || exit 1
    k=1
    while [ $k -le "$repos" ]; do
        r="$dir/Work/repos/project-$k"
        worktrees="$r/.claude/worktrees"
        git_fixed init -q "$r" || exit 1
        mkdir -p "$r/src"
        printf 'Project %s\n' $k >"$r/README.md"
        printf 'line %s\n' 1 2 3 >"$r/src/main.txt"
        git_fixed -C "$r" add -A && git_fixed -C "$r" commit -q -m "Start project $k" || exit 1
        # Clean, on its own branch.
        git_fixed -C "$r" worktree add -q -b "agent-$k-clean" "$worktrees/agent-$k-clean" || exit 1
        # An uncommitted change.
        git_fixed -C "$r" worktree add -q -b "agent-$k-dirty" "$worktrees/agent-$k-dirty" || exit 1
        printf 'more\n' >>"$worktrees/agent-$k-dirty/README.md"
        # A commit on no branch.
        git_fixed -C "$r" worktree add -q --detach "$worktrees/agent-$k-detached" || exit 1
        printf 'new\n' >"$worktrees/agent-$k-detached/notes.txt"
        git_fixed -C "$worktrees/agent-$k-detached" add -A \
            && git_fixed -C "$worktrees/agent-$k-detached" commit -q -m "Work on no branch" || exit 1
        k=$((k + 1))
    done
    # File times, like the rest of the tree, don't depend on today.
    TZ=UTC /usr/bin/find "$dir/Work/repos" -exec touch -h -t 202512011200.00 {} + || exit 1
    TZ=UTC touch -h -t "$work_time" "$dir/Work" || exit 1
    echo "Added $repos repositories with 3 worktrees each under Work/repos." >&2
fi
echo "Done in $(($(date +%s) - start)) s." >&2
