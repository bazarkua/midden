#!/bin/bash
# Builds the frozen correctness fixture: a small tree with the cases every
# benchmark tool must agree on before its speed means anything. run.sh
# checks all its tools on it before timing them.
#
#   files of 0, 1, 4096, 4097 and 100,000 bytes; a 1 GiB sparse file that
#   allocates one block; a file with three hard links; symlinks to a file, a
#   folder, nothing, / and themselves; a FIFO; names with a newline, a tab,
#   spaces, quotes, a backslash, a leading dash or dot, non-ASCII letters,
#   and 255 bytes; nested and empty folders; a folder of 3,000 entries,
#   which takes several getattrlistbulk calls.
#
# With --locked it adds a folder nobody can list, holding two entries: every
# tool must report that it couldn't read it.
#
# Usage: Benchmarks/fixture.sh [--locked] DIR
#   DIR must not exist. Prints the number of entries made, the root not
#   included: the item count every tool must report. With --locked, it's
#   the count of what can be read.

set -o pipefail

locked=0
if [ "$1" = "--locked" ]; then
    locked=1
    shift
fi
dir=$1
if [ -z "$dir" ] || [ -e "$dir" ]; then
    echo "usage: Benchmarks/fixture.sh [--locked] DIR (DIR must not exist)" >&2
    exit 2
fi

made=0
fail() {
    echo "fixture.sh: $*" >&2
    exit 1
}
# Each helper makes one entry and counts it.
file() {
    # macOS head refuses a count of 0.
    if [ "$2" -eq 0 ]; then : >"$dir/$1"; else head -c "$2" /dev/zero >"$dir/$1"; fi \
        || fail "can't write $1"
    made=$((made + 1))
}
folder() { mkdir "$dir/$1" || fail "can't make $1"; made=$((made + 1)); }
link() { ln "$dir/$1" "$dir/$2" || fail "can't link $2"; made=$((made + 1)); }
symlink() { ln -s "$1" "$dir/$2" || fail "can't make symlink $2"; made=$((made + 1)); }

mkdir "$dir" || fail "can't make $dir"

file empty 0
file one-byte 1
file one-block 4096
file one-block-and-a-byte 4097
file hundred-kb 100000

# 1 GiB long, one 4 KB block written at the end.
dd if=/dev/zero of="$dir/sparse" bs=4096 count=1 seek=262143 2>/dev/null || fail "can't write sparse"
made=$((made + 1))

folder links
file links/original 100000
link links/original links/second
folder links/other
link links/original links/other/third

symlink one-byte symlink-to-file
symlink links symlink-to-folder
symlink does-not-exist symlink-to-nothing
symlink / symlink-to-root
symlink loop loop

mkfifo "$dir/fifo" || fail "can't make fifo"
made=$((made + 1))

folder names
file "names/with space" 10
file "names/new
line" 10
file "names/tab	here" 10
file "names/quote'" 10
file 'names/double"quote' 10
file 'names/back\slash' 10
file "names/-leading-dash" 10
file "names/.hidden" 10
file "names/ünïcødé" 10
file "names/$(printf 'n%.0s' $(seq 1 255))" 10

folder a
folder a/b
folder a/b/c
folder a/b/c/d
folder a/b/c/d/e
file a/b/c/d/e/deep 5000
folder empty-folder

folder many
(cd "$dir/many" && seq -f 'f%04g' 1 3000 | xargs touch) || fail "can't fill many"
made=$((made + 3000))

if [ $locked -eq 1 ]; then
    folder locked
    file locked/inside-1 10
    file locked/inside-2 10
    chmod 000 "$dir/locked" || fail "can't lock"
    # What can't be listed isn't counted by anyone.
    made=$((made - 2))
fi

echo "$made"
