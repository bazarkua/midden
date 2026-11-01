#!/bin/bash
# Shows that fts(3), which du and find use, lists folders with
# getattrlistbulk(2) too, so that call alone isn't what makes Midden faster
# than du. It walks DIR with fts the way `du -x` does, under a library that
# counts getattrlistbulk calls, and prints the count next to the number of
# folders.
#
# /usr/bin/du itself can't be probed: macOS drops DYLD_INSERT_LIBRARIES for
# system binaries (the script shows that too). Benchmarks/fts-probe/ftswalk.c
# calls fts with du's flags instead.
#
# Usage: Benchmarks/fts-probe.sh DIR

set -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
dir=$1
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "usage: Benchmarks/fts-probe.sh DIR" >&2
    exit 2
fi

bin="$repo/.build/benchmarks"
mkdir -p "$bin"
clang -dynamiclib -O2 -Wall -Wextra -o "$bin/count-getattrlistbulk.dylib" "$here/fts-probe/count.c" || exit 1
clang -O2 -Wall -Wextra -o "$bin/ftswalk" "$here/fts-probe/ftswalk.c" || exit 1

echo "fts, walked as du -x does:"
DYLD_INSERT_LIBRARIES="$bin/count-getattrlistbulk.dylib" "$bin/ftswalk" "$dir" 2>&1 | sed 's/^/  /'
echo "/usr/bin/du -skx with the same library (no count means macOS dropped it):"
DYLD_INSERT_LIBRARIES="$bin/count-getattrlistbulk.dylib" /usr/bin/du -skx "$dir" 2>&1 | sed 's/^/  /'
