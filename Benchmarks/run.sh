#!/bin/bash
# Times Midden's scan next to a C scanner, du and find on one or more
# folders, and checks that they agree on items and bytes.
#
# Warm cache by default: every tool runs once unmeasured (which also fills
# the cache and records its totals), then --runs measured rounds. A round
# runs every tool once, always in the same order, so a change in machine
# load hits all tools alike instead of one tool's runs.
#
# Usage: Benchmarks/run.sh [options] DIR...
#   --runs N        measured runs per tool (default 5)
#   --threads N     threads for the C scanner and midden-bench (default:
#                   Midden's own default, the core count clamped to 4...12;
#                   `midden scan` itself always uses its default)
#   --tools LIST    comma-separated subset of the tools below (default: all)
#   --label NAME    name of the dataset in the report (one DIR only)
#   --out DIR       where results go (default Benchmarks/results/<time>)
#   --wait-load X   before each measured run, wait up to 10 minutes for the
#                   1-minute load average to drop below X
#   --cold          cold cache: `sudo purge` before every measured run and
#                   no warm-up round. Asks for your password once.
#
# Tools:
#   scan        midden scan --json, output to /dev/null: the full pipeline
#   engine      midden-bench scan: the same scan without JSON output
#   read        midden-bench read: the scan's reading phase only
#               (walk + classification + space map records)
#   classify    midden-bench classify: walk + classification
#   walk        midden-bench walk: Midden's walker alone, N threads
#   walk-1      the same on 1 thread
#   c           Benchmarks/cscan, N threads, folders opened by full path
#   c-1         the same on 1 thread
#   c-openat    the C scanner opening each folder relative to its parent
#   du          du -skx
#   find        find -x DIR | wc -l
#
# Writes results.md (medians, ranges, the totals check, machine
# conditions), results.csv (every measured run) and raw/ (tool output).
# Needs only what macOS ships plus a Swift toolchain; bash 3.2 compatible.

set -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
all_tools="scan engine read classify walk walk-1 c c-1 c-openat du find"

runs=5
threads=
tools=$all_tools
label=
out=
wait_load=
cold=0
dirs=()

die() {
    echo "run.sh: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case $1 in
        --runs) runs=$2; shift 2 ;;
        --threads) threads=$2; shift 2 ;;
        --tools) tools=$(echo "$2" | tr ',' ' '); shift 2 ;;
        --label) label=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --wait-load) wait_load=$2; shift 2 ;;
        --cold) cold=1; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) dirs[${#dirs[@]}]=$1; shift ;;
    esac
done
[ ${#dirs[@]} -gt 0 ] || die "name at least one folder to scan (see --help)"
[ -z "$label" ] || [ ${#dirs[@]} -eq 1 ] || die "--label needs exactly one folder"
for tool in $tools; do
    case " $all_tools " in *" $tool "*) ;; *) die "unknown tool $tool" ;; esac
done
for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || die "$dir is not a folder"
done

ncpu=$(sysctl -n hw.ncpu)
if [ -z "$threads" ]; then
    threads=$ncpu
    [ "$threads" -lt 4 ] && threads=4
    [ "$threads" -gt 12 ] && threads=12
fi
[ -n "$out" ] || out="$here/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out/raw" || die "can't create $out"
csv="$out/results.csv"
md="$out/results.md"

# MARK: Build

echo "Building midden, midden-bench and the C scanner..." >&2
(cd "$repo" && swift build -c release --product midden \
    && swift build -c release --product midden-bench) >"$out/raw/build.log" 2>&1 \
    || die "swift build failed; see $out/raw/build.log"
bin=$(cd "$repo" && swift build -c release --show-bin-path)
midden="$bin/midden"
bench="$bin/midden-bench"
cscan="$repo/.build/benchmarks/cscan"
mkdir -p "$(dirname "$cscan")"
clang -std=c11 -O3 -Wall -Wextra -o "$cscan" "$here/cscan/cscan.c" || die "clang failed"

if [ $cold -eq 1 ]; then
    echo "Cold cache runs call sudo purge before every measured run." >&2
    sudo -v || die "sudo is needed for --cold"
fi

# MARK: Running one tool

# Runs `tool` on `dir` under /usr/bin/time -l. The tool's stdout goes to
# $3 (a file, or /dev/null), the rusage to $4. Returns the tool's status.
run_tool() {
    local tool=$1 dir=$2 stdout=$3 rusage=$4
    case $tool in
        scan) /usr/bin/time -l -o "$rusage" "$midden" scan --json --home "$dir" >"$stdout" ;;
        engine) /usr/bin/time -l -o "$rusage" "$bench" scan "$dir" --threads "$threads" >"$stdout" ;;
        read|classify|walk) /usr/bin/time -l -o "$rusage" "$bench" "$tool" "$dir" --threads "$threads" >"$stdout" ;;
        walk-1) /usr/bin/time -l -o "$rusage" "$bench" walk "$dir" --threads 1 >"$stdout" ;;
        c) /usr/bin/time -l -o "$rusage" "$cscan" --threads "$threads" "$dir" >"$stdout" ;;
        c-1) /usr/bin/time -l -o "$rusage" "$cscan" --threads 1 "$dir" >"$stdout" ;;
        c-openat) /usr/bin/time -l -o "$rusage" "$cscan" --threads "$threads" --openat "$dir" >"$stdout" ;;
        du) /usr/bin/time -l -o "$rusage" du -skx "$dir" >"$stdout" ;;
        find) /usr/bin/time -l -o "$rusage" sh -c 'find -x "$1" | wc -l' sh "$dir" >"$stdout" ;;
    esac
}

# Prints "items bytes" from a tool's output; "-" where it doesn't say.
totals() {
    local tool=$1 file=$2
    case $tool in
        scan)
            if [ -s "$file" ]; then
                echo "$(plutil -extract itemsScanned raw -o - "$file" 2>/dev/null || echo -)" \
                    "$(plutil -extract bytesScanned raw -o - "$file" 2>/dev/null || echo -)"
            else
                echo "- -"
            fi ;;
        du) awk '{ print "-", $1 * 1024; exit }' "$file" ;;
        find) awk '{ print $1 - 1, "-"; exit }' "$file" ;;  # find also prints the root.
        *) tr ' ' '\n' <"$file" | awk -F= '$1 == "items" { i = $2 } $1 == "bytes" { b = $2 }
            END { print (i == "" ? "-" : i), (b == "" ? "-" : b) }' ;;
    esac
}

# Prints "wall user sys maxrss footprint instructions cycles" from
# /usr/bin/time -l (the last two only where macOS reports them).
rusage_fields() {
    awk '/ real / { wall = $1; user = $3; sys = $5 }
        /maximum resident set size/ { rss = $1 }
        /peak memory footprint/ { peak = $1 }
        /instructions retired/ { instructions = $1 }
        /cycles elapsed/ { cycles = $1 }
        END { print wall, user, sys, rss, peak, (instructions == "" ? "-" : instructions),
            (cycles == "" ? "-" : cycles) }' "$1"
}

load1() {
    sysctl -n vm.loadavg | awk '{ print $2 }'
}

wait_for_load() {
    [ -n "$wait_load" ] || return 0
    local waited=0
    while awk -v load="$(load1)" -v limit="$wait_load" 'BEGIN { exit !(load >= limit) }'; do
        if [ $waited -ge 600 ]; then
            echo "  load $(load1) still above $wait_load after 10 minutes; running anyway" >&2
            return 0
        fi
        [ $waited -eq 0 ] && echo "  waiting for load $(load1) to drop below $wait_load..." >&2
        sleep 10
        waited=$((waited + 10))
    done
}

# Folder names in the report: ~ for the home folder.
display() {
    case $1 in
        "$HOME"/*) echo "~${1#"$HOME"}" ;;
        *) echo "$1" ;;
    esac
}

slug() {
    echo "$1" | tr -c 'A-Za-z0-9\n' '-'
}

# MARK: Machine conditions

conditions() {
    local commit
    commit=$(cd "$repo" && git rev-parse --short HEAD 2>/dev/null)
    if [ -n "$(cd "$repo" && git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        commit="$commit (with uncommitted changes)"
    fi
    echo "- Mac: $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string)," \
        "$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo ?) performance +" \
        "$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo ?) efficiency cores" \
        "($ncpu logical), $(($(sysctl -n hw.memsize) / 1073741824)) GiB memory"
    echo "- macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "- $(swift --version 2>&1 | grep -m1 -o 'Swift version [^ ]*'), $(clang --version | head -1)"
    echo "- Engine commit: $commit"
    echo "- Cache: $([ $cold -eq 1 ] && echo "cold (sudo purge before every measured run)" \
        || echo "warm (one unmeasured run of every tool first)")"
    echo "- Runs: $runs measured per tool, interleaved round by round; threads: $threads" \
        "(midden scan uses its default)"
}

# MARK: Measuring

echo "dataset,tool,run,wall_s,user_s,sys_s,max_rss_bytes,peak_footprint_bytes,instructions,cycles,items,bytes,load1,status" >"$csv"

{
    echo "# Midden benchmark"
    echo
    echo "$(date '+%Y-%m-%d %H:%M %Z')"
    echo
    conditions
} >"$md"

for dir in "${dirs[@]}"; do
    name=${label:-$(display "$dir")}
    tag=$(slug "$(basename "$dir")")
    echo "== $name" >&2
    load_start=$(uptime | sed 's/.*load averages*: //')

    if [ $cold -eq 0 ]; then
        for tool in $tools; do
            echo "  warm-up: $tool" >&2
            run_tool "$tool" "$dir" "$out/raw/$tag-$tool.out" "$out/raw/$tag-$tool.warm.time" \
                2>"$out/raw/$tag-$tool.err"
        done
    fi

    run=1
    while [ $run -le "$runs" ]; do
        for tool in $tools; do
            wait_for_load
            [ $cold -eq 1 ] && sudo purge
            load=$(load1)
            stdout="$out/raw/$tag-$tool.run$run.out"
            [ "$tool" = scan ] && stdout=/dev/null
            # In a cold run the first output is the only one, so keep it.
            [ "$tool" = scan ] && [ $cold -eq 1 ] && [ $run -eq 1 ] && stdout="$out/raw/$tag-$tool.out"
            rusage="$out/raw/$tag-$tool.run$run.time"
            run_tool "$tool" "$dir" "$stdout" "$rusage" 2>>"$out/raw/$tag-$tool.err"
            status=$?
            if [ "$stdout" = /dev/null ]; then
                counted="- -"
            else
                counted=$(totals "$tool" "$stdout")
                [ $run -eq 1 ] && [ ! -e "$out/raw/$tag-$tool.out" ] && cp "$stdout" "$out/raw/$tag-$tool.out"
            fi
            fields=$(rusage_fields "$rusage")
            echo "$name,$tool,$run,$(echo "$fields" | tr ' ' ','),$(echo "$counted" | tr ' ' ','),$load,$status" \
                | tr -d '\r' >>"$csv"
            echo "  run $run/$runs $tool: $(echo "$fields" | awk '{ print $1 }') s (load $load)" >&2
        done
        run=$((run + 1))
    done
    load_end=$(uptime | sed 's/.*load averages*: //')

    # MARK: Report for this folder

    # Reference item count for items per second: the C scanner, else any tool.
    reference=
    for tool in c c-openat c-1 walk walk-1 find scan; do
        [ -e "$out/raw/$tag-$tool.out" ] || continue
        set -- $(totals "$tool" "$out/raw/$tag-$tool.out")
        if [ "$1" != "-" ] && [ -n "$1" ]; then
            reference=$1
            break
        fi
    done

    {
        echo
        echo "## $name"
        echo
        echo "Load average (1, 5, 15 min): $load_start at the start, $load_end at the end."
        echo
        echo "| Tool | Wall, median | Wall, min–max | User CPU | System CPU | Peak RSS | Items/s |"
        echo "|---|---:|---:|---:|---:|---:|---:|"
        for tool in $tools; do
            awk -F, -v name="$name" -v tool="$tool" -v items="$reference" '
                function median(values, n,    i, j, t) {
                    for (i = 2; i <= n; i++) for (j = i; j > 1 && values[j - 1] > values[j]; j--) {
                        t = values[j]; values[j] = values[j - 1]; values[j - 1] = t
                    }
                    return n % 2 ? values[(n + 1) / 2] : (values[n / 2] + values[n / 2 + 1]) / 2
                }
                $1 == name && $2 == tool {
                    n++; wall[n] = $4; user[n] = $5; sys[n] = $6; rss[n] = $7
                    if (n == 1 || $4 < low) low = $4
                    if (n == 1 || $4 > high) high = $4
                }
                END {
                    if (n == 0) exit
                    w = median(wall, n)
                    printf "| %s | %.2f s | %.2f–%.2f s | %.2f s | %.2f s | %.0f MB | %s |\n",
                        tool, w, low, high, median(user, n), median(sys, n), median(rss, n) / 1e6,
                        (items != "" && w > 0) ? sprintf("%.0fk", items / w / 1000) : "–"
                }' "$csv"
        done
        echo
        echo "Items/s divides one item count (${reference:-unknown}, from the C scanner when it ran)" \
            "by each tool's median wall time, so the tools are compared on the same work."
        echo
        echo "### Totals"
        echo
        # Differences against the C scanner's first run, when it ran.
        base_items=-
        base_bytes=-
        for tool in c c-openat c-1; do
            if [ -e "$out/raw/$tag-$tool.out" ]; then
                set -- $(totals "$tool" "$out/raw/$tag-$tool.out")
                base_items=$1
                base_bytes=$2
                break
            fi
        done
        echo "| Tool | Items | Items − C | Bytes allocated | Bytes − C |"
        echo "|---|---:|---:|---:|---:|"
        for tool in $tools; do
            [ -e "$out/raw/$tag-$tool.out" ] || continue
            set -- $(totals "$tool" "$out/raw/$tag-$tool.out")
            note=
            [ "$tool" = du ] && note=" (KB × 1024)"
            [ "$tool" = find ] && note=" (lines − 1)"
            echo "$tool$note $1 $2 $base_items $base_bytes" | awk '{
                n = NF; tool = $1; for (i = 2; i <= n - 4; i++) tool = tool " " $i
                items = $(n - 3); bytes = $(n - 2); bi = $(n - 1); bb = $n
                di = (items == "-" || bi == "-") ? "" : items - bi
                db = (bytes == "-" || bb == "-") ? "" : bytes - bb
                printf "| %s | %s | %s | %s | %s |\n", tool, items, di, bytes, db
            }'
        done
        echo
        echo "Totals come from each tool's first run. Item counts exclude the root folder;" \
            "find prints it, so its line count is reduced by one. du -k prints 1024-byte units."
    } >>"$md"
done

echo >&2
echo "Results: $md" >&2
echo "Runs:    $csv" >&2
