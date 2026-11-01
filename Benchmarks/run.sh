#!/bin/bash
# Times Midden's scan next to a C scanner, du and find on one or more
# folders, and checks that they agree on items, bytes and errors.
#
# Warm cache by default: every tool runs once unmeasured (which also fills
# the cache and records its totals), then --runs measured rounds. A round
# runs every tool once; each round starts one tool later than the last, so
# neither a change in machine load nor a tool's position in the order
# favors one tool.
#
# Usage: Benchmarks/run.sh [options] DIR...
#   --runs N        measured runs per tool (default 7)
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
#   scan         midden scan --json, output to /dev/null: the full pipeline
#   engine       midden-bench scan: the same scan without writing JSON (it
#                times encoding the JSON separately and prints that)
#   read         midden-bench read: the scan's reading phase only
#                (walk + classification + space map records)
#   classify     midden-bench classify: walk + classification
#   walk         midden-bench walk: Midden's walker alone, N threads
#   walk-1       the same on 1 thread
#   c            Benchmarks/cscan: getattrlistbulk, folders opened by path,
#                N threads (the same strategy as Midden's walker)
#   c-1          the same on 1 thread
#   c-openat     the C scanner opening each folder relative to its parent
#   c-readdir    the C scanner listing with readdir + fstatat, N threads
#   c-readdir-1  the same on 1 thread
#   du           du -skx
#   find         find -x DIR | wc -l
#
# Writes results.md (medians, spread, every run's time, the totals check,
# machine conditions), results.csv (every measured run) and raw/ (each
# tool's output, errors and rusage). User and system CPU come from
# /usr/bin/time -l, which includes children the tool waited for (git, for
# midden scan); peak RSS is that of the largest single process. The report
# also lists active system extensions: endpoint security software (such as
# CrowdStrike Falcon) sees every file open and process spawn, and can slow
# all the tools, so numbers from Macs with and without it don't compare.
# Needs only what macOS ships plus a Swift toolchain; bash 3.2 compatible.

set -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
all_tools="scan engine read classify walk walk-1 c c-1 c-openat c-readdir c-readdir-1 du find"

runs=7
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
tool_list=()
for tool in $tools; do
    case " $all_tools " in *" $tool "*) ;; *) die "unknown tool $tool" ;; esac
    tool_list[${#tool_list[@]}]=$tool
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

c_flags="-std=c11 -O3 -Wall -Wextra"
echo "Building midden, midden-bench and the C scanner..." >&2
(cd "$repo" && swift build -c release --product midden \
    && swift build -c release --product midden-bench) >"$out/raw/build.log" 2>&1 \
    || die "swift build failed; see $out/raw/build.log"
bin=$(cd "$repo" && swift build -c release --show-bin-path)
midden="$bin/midden"
bench="$bin/midden-bench"
cscan="$repo/.build/benchmarks/cscan"
mkdir -p "$(dirname "$cscan")"
clang $c_flags -o "$cscan" "$here/cscan/cscan.c" || die "clang failed"

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
        scan) timed "$rusage" "$midden" scan --json --home "$dir" >"$stdout" ;;
        engine) timed "$rusage" "$bench" scan "$dir" --threads "$threads" >"$stdout" ;;
        read|classify|walk) timed "$rusage" "$bench" "$tool" "$dir" --threads "$threads" >"$stdout" ;;
        walk-1) timed "$rusage" "$bench" walk "$dir" --threads 1 >"$stdout" ;;
        c) timed "$rusage" "$cscan" --threads "$threads" "$dir" >"$stdout" ;;
        c-1) timed "$rusage" "$cscan" --threads 1 "$dir" >"$stdout" ;;
        c-openat) timed "$rusage" "$cscan" --threads "$threads" --openat "$dir" >"$stdout" ;;
        c-readdir) timed "$rusage" "$cscan" --threads "$threads" --readdir "$dir" >"$stdout" ;;
        c-readdir-1) timed "$rusage" "$cscan" --threads 1 --readdir "$dir" >"$stdout" ;;
        du) timed "$rusage" du -skx "$dir" >"$stdout" ;;
        find) timed "$rusage" sh -c 'find -x "$1" | wc -l' sh "$dir" >"$stdout" ;;
    esac
}

# Runs a command under /usr/bin/time -l, writing the rusage to $1.
timed() {
    local rusage=$1
    shift
    /usr/bin/time -l -o "$rusage" "$@"
}

# Prints "items bytes errors" from a tool's output and its stderr; "-"
# where the tool doesn't say. du and find report errors as stderr lines.
totals() {
    local tool=$1 file=$2 errors=$3
    case $tool in
        scan)
            if [ -s "$file" ]; then
                echo "$(plutil -extract itemsScanned raw -o - "$file" 2>/dev/null || echo -)" \
                    "$(plutil -extract bytesScanned raw -o - "$file" 2>/dev/null || echo -)" \
                    "$(plutil -extract readErrors raw -o - "$file" 2>/dev/null || echo -)"
            else
                echo "- - -"
            fi ;;
        du) echo "- $(awk '{ print $1 * 1024; exit }' "$file") $(wc -l <"$errors" | tr -d ' ')" ;;
        # find also prints the root.
        find) echo "$(awk '{ print $1 - 1; exit }' "$file") - $(wc -l <"$errors" | tr -d ' ')" ;;
        *) tr ' ' '\n' <"$file" | awk -F= '$1 == "items" { i = $2 } $1 == "bytes" { b = $2 }
            $1 == "errors" { e = $2 }
            END { print (i == "" ? "-" : i), (b == "" ? "-" : b), (e == "" ? "-" : e) }' ;;
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
        END { print wall, user, sys, rss, (peak == "" ? "-" : peak),
            (instructions == "" ? "-" : instructions), (cycles == "" ? "-" : cycles) }' "$1"
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

# The file system holding a folder, as mount(8) describes it.
filesystem() {
    local device
    device=$(df "$1" | awk 'NR == 2 { print $1 }')
    mount | awk -v device="$device" '$1 == device { sub(/^[^(]*\(/, ""); sub(/\)$/, ""); print; exit }'
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
    # Endpoint security software inspects file and process events, and can
    # slow every tool's opens and spawns.
    local extensions
    extensions=$(systemextensionsctl list 2>/dev/null \
        | awk -F'\t' '/\[activated enabled\]/ { printf "%s%s (%s)", (n++ ? "; " : ""), $5, $4 }')
    echo "- Active system extensions: ${extensions:-none}"
    echo "- Swift: $(swift --version 2>&1 | grep -m1 -o 'Swift version [^ ]*'), swift build -c release." \
        "C: $(clang --version | head -1), clang $c_flags"
    echo "- Engine commit: $commit"
    echo "- getattrlistbulk buffer: 128 KB per thread, in Midden and in the C scanner"
    echo "- Threads: $threads for midden-bench and the C scanner; midden scan uses its default" \
        "(the core count clamped to 4...12)"
    echo "- Cache: $([ $cold -eq 1 ] && echo "cold (sudo purge before every measured run)" \
        || echo "warm (one unmeasured run of every tool first)")"
    echo "- Runs: $runs measured per tool. Round r starts at tool r, so the order rotates."
    echo "- CPU times include children a tool waited for (git, for midden scan);" \
        "peak RSS is the largest single process."
}

# MARK: Measuring

echo "dataset,tool,run,wall_s,user_s,sys_s,max_rss_bytes,peak_footprint_bytes,instructions,cycles,items,bytes,errors,load1,status" >"$csv"

{
    echo "# Midden benchmark"
    echo
    echo "$(date '+%Y-%m-%d %H:%M %Z')"
    echo
    conditions
} >"$md"

count=${#tool_list[@]}
for dir in "${dirs[@]}"; do
    name=${label:-$(display "$dir")}
    key=$(echo "$name" | tr -d ',')  # The dataset column of the CSV: no commas.
    tag=$(slug "$(basename "$dir")")
    echo "== $name" >&2
    load_start=$(uptime | sed 's/.*load averages*: //')
    started=$(date '+%H:%M')

    if [ $cold -eq 0 ]; then
        for tool in "${tool_list[@]}"; do
            echo "  warm-up: $tool" >&2
            run_tool "$tool" "$dir" "$out/raw/$tag-$tool.first.out" "$out/raw/$tag-$tool.first.time" \
                2>"$out/raw/$tag-$tool.first.err"
        done
    fi

    run=1
    while [ $run -le "$runs" ]; do
        k=0
        while [ $k -lt $count ]; do
            tool=${tool_list[$(((k + run - 1) % count))]}
            k=$((k + 1))
            wait_for_load
            [ $cold -eq 1 ] && sudo purge
            load=$(load1)
            prefix="$out/raw/$tag-$tool.run$run"
            stdout="$prefix.out"
            [ "$tool" = scan ] && stdout=/dev/null
            # Without a warm-up round, the first run's output is the totals.
            if [ $cold -eq 1 ] && [ $run -eq 1 ]; then
                stdout="$out/raw/$tag-$tool.first.out"
            fi
            run_tool "$tool" "$dir" "$stdout" "$prefix.time" 2>"$prefix.err"
            status=$?
            [ $cold -eq 1 ] && [ $run -eq 1 ] && cp "$prefix.err" "$out/raw/$tag-$tool.first.err" \
                && cp "$prefix.time" "$out/raw/$tag-$tool.first.time"
            if [ "$stdout" = /dev/null ]; then
                counted="- - -"
            else
                counted=$(totals "$tool" "$stdout" "$prefix.err")
            fi
            fields=$(rusage_fields "$prefix.time")
            echo "$key,$tool,$run,$(echo "$fields" | tr ' ' ','),$(echo "$counted" | tr ' ' ','),$load,$status" \
                | tr -d '\r' >>"$csv"
            echo "  run $run/$runs $tool: $(echo "$fields" | awk '{ print $1 }') s (load $load)" >&2
        done
        run=$((run + 1))
    done
    load_end=$(uptime | sed 's/.*load averages*: //')

    # MARK: Report for this folder

    # One item count for items per second: the C scanner's, else any tool's.
    reference=
    for tool in c c-1 c-openat c-readdir walk walk-1 find scan; do
        [ -e "$out/raw/$tag-$tool.first.out" ] || continue
        set -- $(totals "$tool" "$out/raw/$tag-$tool.first.out" "$out/raw/$tag-$tool.first.err")
        if [ "$1" != "-" ] && [ -n "$1" ]; then
            reference=$1
            break
        fi
    done

    {
        echo
        echo "## $name"
        echo
        echo "File system: $(filesystem "$dir"). Measured from $started to $(date '+%H:%M')."
        echo "Load average (1, 5, 15 min): $load_start at the start, $load_end at the end."
        echo
        echo "| Tool | Wall, median | Wall, min–max | User CPU | System CPU | Peak RSS | Items/s | Every run, in order (s) |"
        echo "|---|---:|---:|---:|---:|---:|---:|---|"
        for tool in "${tool_list[@]}"; do
            awk -F, -v name="$key" -v tool="$tool" -v items="$reference" '
                function median(values, n,    i, j, t) {
                    for (i = 2; i <= n; i++) for (j = i; j > 1 && values[j - 1] > values[j]; j--) {
                        t = values[j]; values[j] = values[j - 1]; values[j - 1] = t
                    }
                    return n % 2 ? values[(n + 1) / 2] : (values[n / 2] + values[n / 2 + 1]) / 2
                }
                $1 == name && $2 == tool {
                    n++; wall[n] = $4; user[n] = $5; sys[n] = $6; rss[n] = $7
                    every = every (n > 1 ? ", " : "") $4
                    if (n == 1 || $4 < low) low = $4
                    if (n == 1 || $4 > high) high = $4
                }
                END {
                    if (n == 0) exit
                    w = median(wall, n)
                    printf "| %s | %.2f s | %.2f–%.2f s | %.2f s | %.2f s | %.0f MB | %s | %s |\n",
                        tool, w, low, high, median(user, n), median(sys, n), median(rss, n) / 1e6,
                        (items != "" && w > 0) ? sprintf("%.0fk", items / w / 1000) : "–", every
                }' "$csv"
        done
        echo
        echo "Items/s divides one item count (${reference:-unknown}, from the C scanner when it ran)" \
            "by each tool's median wall time, so every tool is credited with the same work."
        echo
        echo "### Totals"
        echo
        # Totals from measured round 1, which runs every tool within minutes,
        # so a folder that changes (like a live home folder) changes less
        # between tools than over the warm-up. midden scan writes its JSON
        # to /dev/null when measured, so its totals come from its first run.
        round1() {
            local tool=$1
            set -- $(awk -F, -v name="$key" -v tool="$tool" \
                '$1 == name && $2 == tool && $3 == 1 { print $11, $12, $13; exit }' "$csv")
            if [ "$1" = "-" ] && [ "$2" = "-" ] && [ -e "$out/raw/$tag-$tool.first.out" ]; then
                totals "$tool" "$out/raw/$tag-$tool.first.out" "$out/raw/$tag-$tool.first.err"
            else
                echo "${1:--} ${2:--} ${3:--}"
            fi
        }
        # Whether a tool's items and bytes were the same in every measured run.
        steady() {
            awk -F, -v name="$key" -v tool="$1" '$1 == name && $2 == tool {
                    if ($11 != "-") items[$11]; if ($12 != "-") bytes[$12]; n++
                }
                END {
                    for (i in items) a++; for (b in bytes) c++
                    print (n == 0 || (a == 0 && c == 0)) ? "–" : (a <= 1 && c <= 1) ? "yes" : "no"
                }' "$csv"
        }
        base_items=-
        base_bytes=-
        for tool in c c-1 c-openat c-readdir c-readdir-1; do
            case " ${tool_list[*]} " in *" $tool "*) ;; *) continue ;; esac
            set -- $(round1 "$tool")
            base_items=$1
            base_bytes=$2
            break
        done
        echo "| Tool | Items | Items − C | Bytes allocated | Bytes − C | Errors | Same in every run |"
        echo "|---|---:|---:|---:|---:|---:|:-:|"
        for tool in "${tool_list[@]}"; do
            set -- $(round1 "$tool")
            note=
            [ "$tool" = du ] && note=" (KB × 1024)"
            [ "$tool" = find ] && note=" (lines − 1)"
            [ "$tool" = scan ] && note=" (first run)"
            echo "$tool$note $1 $2 $3 $base_items $base_bytes $(steady "$tool")" | awk '{
                n = NF; tool = $1; for (i = 2; i <= n - 6; i++) tool = tool " " $i
                items = $(n - 5); bytes = $(n - 4); errors = $(n - 3); bi = $(n - 2); bb = $(n - 1)
                di = (items == "-" || bi == "-") ? "" : items - bi
                db = (bytes == "-" || bb == "-") ? "" : bytes - bb
                printf "| %s | %s | %s | %s | %s | %s | %s |\n", tool, items, di, bytes, db, errors, $n
            }'
        done
        echo
        echo "Totals come from measured round 1 (midden scan: its first run). Item counts exclude" \
            "the root folder; find prints it, so its line count is reduced by one. du -k prints" \
            "1024-byte units. Errors are folders a tool couldn't read: its own count, or stderr" \
            "lines for du and find. \"Same in every run\" says whether a tool's totals changed" \
            "between its measured runs, which happens when the folder itself changes."
        if [ -e "$out/raw/$tag-engine.first.out" ]; then
            json=$(tr ' ' '\n' <"$out/raw/$tag-engine.first.out" | awk -F= '
                $1 == "json_seconds" { s = $2 } $1 == "json_bytes" { b = $2 }
                END { if (s != "") printf "%s s for %.1f MB", s, b / 1e6 }')
            [ -n "$json" ] && echo "Encoding the report as JSON (engine, first run): $json."
        fi
    } >>"$md"
done

echo >&2
echo "Results: $md" >&2
echo "Runs:    $csv" >&2
