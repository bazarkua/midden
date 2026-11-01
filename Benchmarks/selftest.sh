#!/bin/bash
# Tests parts of the benchmark harness that a benchmark run can't show.
#
# 1. validate.awk fails closed: rows missing a required field, failed runs
#    and mismatched totals don't pass; a run with no reference in its round
#    is "unverified"; ordinary rows and du's and find's documented
#    exceptions pass.
# 2. make-tree.sh --repos isolates git: with GIT_DIR, GIT_WORK_TREE,
#    GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY, config and template variables
#    all pointing at a sentinel repository, generating repositories leaves
#    the sentinel unchanged, runs none of its hooks, and every generated
#    repository and worktree resolves inside the generated tree.
#
# Usage: Benchmarks/selftest.sh

set -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
failures=0
pass() { echo "  pass: $*"; }
fail() { echo "  FAIL: $*"; failures=$((failures + 1)); }

# MARK: 1. Validation

echo "validate.awk"
header="dataset,tool,run,position,wall_s,user_s,sys_s,max_rss_bytes,peak_footprint_bytes,instructions,cycles,items,bytes,errors,load1,status,findings,json_bytes"
# Each case: the expected verdict, then a row. Round 1 has a C reference.
# Round 2's only scanner fails, so nothing there can be verified. Round 3's
# C run has totals but no timing, so Midden's walker is the reference.
cases="yes|t,c,1,1,4.30,0.21,32.1,5000000,-,-,-,100,4096,0,5.0,0,-,-
yes|t,walk,1,2,4.33,0.65,28.7,35000000,-,-,-,100,4096,0,5.0,0,-,-
yes|t,du,1,3,25.4,0.34,18.2,41000000,-,-,-,-,4096,0,5.0,0,-,-
yes|t,find,1,4,31.4,0.54,17.7,24000000,-,-,-,100,-,0,5.0,0,-,-
yes|t,scan,1,5,3.87,0.74,28.9,49000000,5000000,123,456,100,4096,0,5.0,0,7,3236
no|t,c-openat,1,6,-,-,-,-,-,-,-,100,4096,0,5.0,0,-,-
no|t,walk-1,1,7,19.9,0.34,9.8,34000000,-,-,-,100,-,0,5.0,0,-,-
no|t,read,1,8,3.68,0.69,28.6,39000000,-,-,-,100,4096,-,5.0,0,-,-
no|t,classify,1,9,4.56,0.70,28.7,37000000,-,-,-,100,4096,0,5.0,-,-,-
no|t,c-1,1,10,18.9,0.11,9.1,3000000,-,-,-,101,4096,0,5.0,0,-,-
no|t,c-readdir,1,11,7.66,0.59,42.7,5000000,-,-,-,100,4096,1,5.0,1,-,-
no|t,du,1,12,25.4,0.34,18.2,41000000,-,-,-,-,-,0,5.0,0,-,-
no|t,find,1,13,31.4,0.54,17.7,24000000,-,-,-,-,-,0,5.0,0,-,-
no|t,c,0,1,4.30,0.21,32.1,5000000,-,-,-,100,4096,0,5.0,0,-,-
no|t,c,2,1,4.30,0.21,32.1,5000000,-,-,-,100,4096,3,5.0,1,-,-
unverified|t,find,2,2,31.4,0.54,17.7,24000000,-,-,-,100,-,0,5.0,0,-,-
unverified|t,du,2,3,25.4,0.34,18.2,41000000,-,-,-,-,4096,0,5.0,0,-,-
no|t,c,3,1,-,-,-,-,-,-,-,100,4096,0,5.0,0,-,-
yes|t,walk,3,2,4.33,0.65,28.7,35000000,-,-,-,100,4096,0,5.0,0,-,-
yes|t,find,3,3,31.4,0.54,17.7,24000000,-,-,-,100,-,0,5.0,0,-,-"
csv=$( { echo "$header"; echo "$cases" | cut -d'|' -f2-; } )
verdicts=$(echo "$csv" | awk -v refs="c c-1 c-openat c-readdir c-readdir-1 walk walk-1 read classify engine engine-json scan" \
    -f "$here/validate.awk" | tail -n +2)
line=1
while IFS='|' read -r expected row; do
    got=$(echo "$verdicts" | sed -n "${line}p")
    verdict=$(echo "$got" | awk -F, '{ print $19 }')
    reason=$(echo "$got" | awk -F, '{ print $20 }')
    what=$(echo "$row" | awk -F, '{ print $2 " round " $3 }')
    if [ "$verdict" = "$expected" ]; then
        pass "$what: $verdict${reason:+ ($reason)}"
    else
        fail "$what: expected $expected, got $verdict ($reason)"
    fi
    line=$((line + 1))
done <<EOF
$cases
EOF

# MARK: 2. Git isolation

echo "make-tree.sh --repos with every git variable pointing elsewhere"
git=$(command -v git) || { echo "  skipped: no git"; exit $failures; }
work=$(mktemp -d "${TMPDIR:-/tmp}/midden-selftest.XXXXXX") || exit 1
work=$(cd "$work" && pwd -P)
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
sentinel="$work/sentinel"
marker="$work/hook-ran"
clean_git() { env -i PATH=/usr/bin:/bin HOME="$work" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_AUTHOR_NAME=s GIT_AUTHOR_EMAIL=s@example.invalid GIT_COMMITTER_NAME=s \
    GIT_COMMITTER_EMAIL=s@example.invalid "$git" -c init.defaultBranch=main "$@"; }
clean_git init -q "$sentinel" || exit 1
echo sentinel >"$sentinel/file"
clean_git -C "$sentinel" add -A && clean_git -C "$sentinel" commit -q -m sentinel || exit 1
# Hooks and a template that would leave a mark if git ever used them.
mkdir -p "$work/hooks" "$work/template/hooks" "$work/config"
for hook in "$work/hooks/post-commit" "$work/hooks/pre-commit" "$work/template/hooks/post-commit" \
    "$work/template/hooks/pre-commit"; do
    printf '#!/bin/sh\necho "%s" >>"%s"\n' "$hook" "$marker" >"$hook"
    chmod +x "$hook"
done
printf '[core]\n\thooksPath = %s\n[user]\n\tname = sentinel\n' "$work/hooks" >"$work/config/gitconfig"
snapshot() { (cd "$sentinel" && /usr/bin/find . -type f -exec shasum {} + | sort); }
before=$(snapshot)

GIT_DIR="$sentinel/.git" GIT_WORK_TREE="$sentinel" GIT_INDEX_FILE="$sentinel/.git/index" \
    GIT_OBJECT_DIRECTORY="$sentinel/.git/objects" GIT_COMMON_DIR="$sentinel/.git" \
    GIT_CONFIG_GLOBAL="$work/config/gitconfig" GIT_CONFIG_SYSTEM="$work/config/gitconfig" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$work/hooks" \
    GIT_TEMPLATE_DIR="$work/template" GIT_CEILING_DIRECTORIES=/ \
    "$here/make-tree.sh" --scale 0.001 --repos 2 "$work/tree" >/dev/null 2>"$work/make-tree.log" \
    && pass "make-tree.sh succeeded" \
    || fail "make-tree.sh failed: $(tail -1 "$work/make-tree.log")"
# Checked either way: a failed run may still have written to the sentinel.

[ "$(snapshot)" = "$before" ] && pass "the sentinel repository is unchanged" \
    || fail "the sentinel repository changed"
[ -e "$marker" ] && fail "a sentinel hook ran: $(cat "$marker")" || pass "no sentinel hook or template ran"
count=0
for checkout in "$work"/tree/Work/repos/project-* "$work"/tree/Work/repos/project-*/.claude/worktrees/*; do
    [ -e "$checkout/.git" ] || continue
    count=$((count + 1))
    resolved=$(clean_git -C "$checkout" rev-parse --path-format=absolute --git-common-dir --show-toplevel) \
        || { fail "$checkout doesn't resolve"; continue; }
    outside=$(echo "$resolved" | awk -v root="$work/tree/" 'index($0, root) != 1')
    [ -z "$outside" ] && pass "${checkout#"$work/"} resolves inside the tree" \
        || fail "${checkout#"$work/"} resolves outside the tree: $outside"
done
[ $count -eq 8 ] && pass "8 checkouts made (2 repositories, 3 worktrees each)" \
    || fail "expected 8 checkouts, found $count"

echo
[ $failures -eq 0 ] && echo "All checks passed." || echo "$failures checks failed."
exit $failures
