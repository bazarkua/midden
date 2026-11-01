#!/bin/bash
# Builds the synthetic benchmark tree (Benchmarks/maketree/maketree.c):
# about a million entries shaped like a developer's home folder, the same
# for the same seed. Put it outside your home folder, for example under
# $TMPDIR, and delete it with rm -rf when you're done.
#
# Usage: Benchmarks/make-tree.sh [--shape home|flat|deep] [--seed N] [--scale F] DIR
#   DIR must not exist yet. At the default scale the home tree has 998,622
#   entries and takes 4.0 GB on disk; the script checks for 8 GB free
#   (scaled) before it starts.
#   --shape flat makes one folder of a million entries, --shape deep 100
#   chains of 1,000 nested folders; both are much smaller on disk.

set -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
options=()
dir=
scale=1

while [ $# -gt 0 ]; do
    case $1 in
        --seed|--shape) options[${#options[@]}]=$1; options[${#options[@]}]=$2; shift 2 ;;
        --scale) scale=$2; options[${#options[@]}]=--scale; options[${#options[@]}]=$2; shift 2 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "make-tree.sh: unknown option $1" >&2; exit 2 ;;
        *) dir=$1; shift ;;
    esac
done
if [ -z "$dir" ]; then
    echo "usage: Benchmarks/make-tree.sh [--shape home|flat|deep] [--seed N] [--scale F] DIR" >&2
    exit 2
fi
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
echo "Done in $(($(date +%s) - start)) s." >&2
