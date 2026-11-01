#!/bin/bash
# Times Midden's scan next to a C scanner, du and find on one or more
# folders, and checks that they did the same work.
#
# Before timing anything, every chosen tool runs on the frozen correctness
# fixture (Benchmarks/fixture.sh): it must report the fixture's exact item
# count and the same allocated bytes as du, and must report a folder it
# can't read as a failure. If any tool fails that check, nothing is timed.
#
# Then, per folder, every tool runs once unmeasured (a warm-up: its timing
# is kept as run 0, the first touch in this session, which isn't a cold
# cache), and then --runs rounds of repeat scans. Each round runs every tool
# once, in an order shuffled from --seed, so neither machine load nor a
# tool's place in the order favors one tool.
#
# A run is valid for comparing speed only when the tool exited 0, read
# every folder, reported its totals, and its totals equal those of the
# reference tool in the same round (the C scanner, else Midden's walker).
# Medians use valid runs only. Every run is kept in results.csv with its
# reason when it isn't valid.
#
# Usage: Benchmarks/run.sh [options] DIR...
#   --preset NAME   a focused experiment (default: all tools):
#                     walk       Midden's walker against the matched C walk,
#                                on N threads and on 1: implementation cost
#                     strategy   the C scanner's strategies: by path, openat,
#                                readdir + fstatat, on N threads and on 1
#                     baselines  Midden's walker and the C scanner against
#                                du (sizes) and find (names only, less work)
#                     product    the CLI end to end and the engine's stages:
#                                what a scan costs as a product
#   --tools LIST    comma-separated tools, instead of a preset
#   --runs N        measured rounds (default 7)
#   --seed N        seed for the order of each round (default 1)
#   --threads N     threads for the C scanner and midden-bench (default:
#                   Midden's own default, the core count clamped to 4...12;
#                   `midden scan` itself always uses its default)
#   --label NAME    name of the dataset in the report (one DIR only)
#   --out DIR       where results go (default Benchmarks/results/<time>);
#                   refused when it's inside a folder being measured
#   --wait-load X   before each measured run, wait up to 10 minutes for the
#                   1-minute load average to drop below X
#   --cold          `sudo purge` before every measured run, and no warm-up.
#                   A run whose purge failed is recorded as invalid.
#   --skip-check    don't run the fixture check (the report says so)
#
# Tools:
#   scan         midden scan --json, output to a file: the CLI end to end
#   engine       midden-bench scan: the whole engine, never encodes JSON
#   engine-json  midden-bench scan-json: the same, then encodes the report
#                as the CLI does and discards it
#   read         midden-bench read: the scan's reading phase (walk,
#                classification, space-map records)
#   classify     midden-bench classify: walk + classification
#   walk         midden-bench walk: Midden's walker alone, N threads
#   walk-1       the same on 1 thread
#   c            Benchmarks/cscan: getattrlistbulk, folders opened by path,
#                N threads (the same system calls as Midden's walker)
#   c-1          the same on 1 thread
#   c-openat     the C scanner opening each folder relative to its parent
#   c-readdir    the C scanner listing with readdir + fstatat, N threads
#   c-readdir-1  the same on 1 thread
#   du           /usr/bin/du -skx: an allocated-size utility
#   find         /usr/bin/find -x DIR -print0, counting NUL-separated
#                records: enumeration only, which is less work
#
# Writes results.md (per tool: valid/attempted runs, medians and spread of
# the valid runs, every run, invalid runs with reasons; totals; machine
# conditions), check.md (the fixture check), conditions.md (the command
# line, the commits measured, the machine, power and load at the start),
# results.csv (every run, with valid and reason) and raw/ (each tool's
# output, errors and rusage).
#
# User and system CPU come from /usr/bin/time -l and include children the
# tool waited for (git, for midden scan). Peak RSS is the largest maximum
# resident set size among the tool and the children it waited for (wait4
# keeps the maximum), not the combined peak of processes running at once.
# Peak footprint (CSV only) is the direct child's alone. The report also
# lists active system extensions: endpoint security software (such as
# CrowdStrike Falcon) sees every file open and process spawn, and can slow
# all the tools, so numbers from Macs with and without it don't compare.
# Needs only what macOS ships plus a Swift toolchain; bash 3.2 compatible.

set -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
# The command line as given, for the record, with ~ for the home folder.
# Arguments with characters the shell would read differently are quoted.
invocation=
for word in "$0" "$@"; do
    case $word in
        *[!A-Za-z0-9_./,=:+@%-]*|"") word="'$(echo "$word" | sed "s/'/'\\\\''/g")'" ;;
    esac
    invocation="$invocation${invocation:+ }$word"
done
invocation=$(echo "$invocation" | sed "s|$HOME|~|g")

all_tools="scan engine engine-json read classify walk walk-1 c c-1 c-openat c-readdir c-readdir-1 du find"
# Tools whose totals a round is checked against, in order of preference.
reference_tools="c c-1 c-openat c-readdir c-readdir-1 walk walk-1 read classify engine engine-json scan"

runs=7
seed=1
threads=
tools=$all_tools
preset=all
label=
out=
wait_load=
cold=0
check=1
dirs=()

die() {
    echo "run.sh: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case $1 in
        --runs) runs=$2; shift 2 ;;
        --seed) seed=$2; shift 2 ;;
        --threads) threads=$2; shift 2 ;;
        --preset)
            preset=$2
            case $2 in
                walk) tools="walk c walk-1 c-1" ;;
                strategy) tools="c c-openat c-readdir c-1 c-readdir-1" ;;
                baselines) tools="walk c du find" ;;
                product) tools="scan engine engine-json read classify walk" ;;
                all) tools=$all_tools ;;
                *) die "unknown preset $2 (walk, strategy, baselines, product, all)" ;;
            esac
            shift 2 ;;
        --tools) tools=$(echo "$2" | tr ',' ' '); preset=custom; shift 2 ;;
        --label) label=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --wait-load) wait_load=$2; shift 2 ;;
        --cold) cold=1; shift ;;
        --skip-check) check=0; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) dirs[${#dirs[@]}]=$1; shift ;;
    esac
done
[ ${#dirs[@]} -gt 0 ] || die "name at least one folder to scan (see --help)"
[ -z "$label" ] || [ ${#dirs[@]} -eq 1 ] || die "--label needs exactly one folder"
case $runs$seed in *[!0-9]*) die "--runs and --seed take whole numbers" ;; esac
tool_list=()
for tool in $tools; do
    case " $all_tools " in *" $tool "*) ;; *) die "unknown tool $tool" ;; esac
    tool_list[${#tool_list[@]}]=$tool
done

# The absolute physical path of $1, which may not exist yet.
resolve() {
    local path=$1 rest=
    case $path in /*) ;; *) path="$PWD/$path" ;; esac
    while [ ! -d "$path" ]; do
        rest="/$(basename "$path")$rest"
        path=$(dirname "$path")
    done
    echo "$(cd "$path" && pwd -P)$rest"
}

# Whether path $1 is folder $2 or inside it.
inside() {
    [ "$2" = / ] && return 0
    case "$1/" in "$2"/*) return 0 ;; esac
    return 1
}

[ -n "$out" ] || out="$here/results/$(date +%Y%m%d-%H%M%S)"
out_real=$(resolve "$out")
fixture_parent=$(resolve "${TMPDIR:-/tmp}")
roots=()
for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || die "$dir is not a folder"
    root=$(cd "$dir" && pwd -P)
    # Results written into a measured folder would change what is measured.
    inside "$out_real" "$root" && die "the output folder $out is inside $dir, which is measured; pass --out elsewhere"
    [ $check -eq 1 ] && inside "$fixture_parent" "$root" \
        && die "the fixture would be made in ${TMPDIR:-/tmp}, inside $dir; set TMPDIR elsewhere"
    roots[${#roots[@]}]=$root
done

ncpu=$(sysctl -n hw.ncpu)
if [ -z "$threads" ]; then
    threads=$ncpu
    [ "$threads" -lt 4 ] && threads=4
    [ "$threads" -gt 12 ] && threads=12
fi
mkdir -p "$out/raw" || die "can't create $out"
csv="$out/results.csv"
runs_csv="$out/raw/runs.csv"
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
# $3, the rusage to $4. Returns the tool's status.
run_tool() {
    local tool=$1 dir=$2 stdout=$3 rusage=$4
    case $tool in
        scan) timed "$rusage" "$midden" scan --json --home "$dir" >"$stdout" ;;
        engine) timed "$rusage" "$bench" scan "$dir" --threads "$threads" >"$stdout" ;;
        engine-json) timed "$rusage" "$bench" scan-json "$dir" --threads "$threads" >"$stdout" ;;
        read|classify|walk) timed "$rusage" "$bench" "$tool" "$dir" --threads "$threads" >"$stdout" ;;
        walk-1) timed "$rusage" "$bench" walk "$dir" --threads 1 >"$stdout" ;;
        c) timed "$rusage" "$cscan" --threads "$threads" "$dir" >"$stdout" ;;
        c-1) timed "$rusage" "$cscan" --threads 1 "$dir" >"$stdout" ;;
        c-openat) timed "$rusage" "$cscan" --threads "$threads" --openat "$dir" >"$stdout" ;;
        c-readdir) timed "$rusage" "$cscan" --threads "$threads" --readdir "$dir" >"$stdout" ;;
        c-readdir-1) timed "$rusage" "$cscan" --threads 1 --readdir "$dir" >"$stdout" ;;
        du) timed "$rusage" /usr/bin/du -skx "$dir" >"$stdout" ;;
        # NUL-separated, so a name with a newline is one record; pipefail
        # passes on find's failure instead of wc's success.
        find) timed "$rusage" /bin/bash -c \
            'set -o pipefail; /usr/bin/find -x "$1" -print0 | tr -cd "\\000" | wc -c' bash "$dir" >"$stdout" ;;
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
        du) echo "- $(awk 'NR == 1 { print $1 * 1024 }' "$file" | grep . || echo -)" \
            "$(grep -c . "$errors")" ;;
        # find also counts the root.
        find) echo "$(awk 'NR == 1 { print $1 - 1 }' "$file" | grep . || echo -) -" \
            "$(grep -c . "$errors")" ;;
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
        END { print (wall == "" ? "-" : wall), (user == "" ? "-" : user), (sys == "" ? "-" : sys),
            (rss == "" ? "-" : rss), (peak == "" ? "-" : peak),
            (instructions == "" ? "-" : instructions), (cycles == "" ? "-" : cycles) }' "$1" 2>/dev/null \
        || echo "- - - - - - -"
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

# Sets `order` to the tools in a new shuffled order (Fisher-Yates on bash's
# RANDOM, which --seed seeds).
shuffle() {
    order=("${tool_list[@]}")
    local i=$((${#order[@]} - 1)) j swap
    while [ $i -gt 0 ]; do
        j=$((RANDOM % (i + 1)))
        swap=${order[$i]}
        order[$i]=${order[$j]}
        order[$j]=$swap
        i=$((i - 1))
    done
}

# MARK: Machine conditions

conditions() {
    local commit engine harness extensions
    commit=$(cd "$repo" && git rev-parse --short HEAD 2>/dev/null)
    if [ -n "$(cd "$repo" && git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        commit="$commit (with uncommitted changes)"
    fi
    # The engine is everything in Sources but the benchmark's entry point;
    # the harness is Benchmarks/ and that entry point.
    engine=$(cd "$repo" && git log -1 --format='%h %s' -- Sources \
        ':(exclude)Sources/MiddenCore/Benchmark.swift' 2>/dev/null)
    harness=$(cd "$repo" && git log -1 --format='%h %s' -- Benchmarks \
        Sources/MiddenCore/Benchmark.swift 2>/dev/null)
    echo "- Command: \`$invocation\`"
    echo "- Built from commit $commit. Newest commit that changed the engine's sources:" \
        "$engine. Newest commit that changed the harness: $harness"
    echo "- Mac: $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string)," \
        "$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo ?) performance +" \
        "$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo ?) efficiency cores" \
        "($ncpu logical), $(($(sysctl -n hw.memsize) / 1073741824)) GiB memory"
    echo "- macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    # Endpoint security software inspects file and process events, and can
    # slow every tool's opens and spawns.
    extensions=$(systemextensionsctl list 2>/dev/null \
        | awk -F'\t' '/\[activated enabled\]/ { printf "%s%s (%s)", (n++ ? "; " : ""), $5, $4 }')
    echo "- Active system extensions: ${extensions:-none}"
    echo "- Power: $(pmset -g batt 2>/dev/null | head -1 | sed "s/^Now drawing from //; s/'//g")," \
        "low power mode $(pmset -g 2>/dev/null | awk '/lowpowermode|powermode/ { print $2; exit }')." \
        "Thermal: $(pmset -g therm 2>/dev/null | sed 's/^Note: //' | paste -sd ',' - | sed 's/,/, /g')"
    echo "- Load average at the start: $(uptime | sed 's/.*load averages*: //')." \
        "Vnode cache: $(sysctl -n kern.maxvnodes) vnodes"
    echo "- Swift: $(swift --version 2>&1 | grep -m1 -o 'Swift version [^ ]*'), swift build -c release." \
        "C: $(clang --version | head -1), clang $c_flags. du and find: /usr/bin/du, /usr/bin/find"
    echo "- getattrlistbulk buffer: 128 KB per thread, in Midden and in the C scanner"
    echo "- Threads: $threads for midden-bench and the C scanner; midden scan uses its default" \
        "(the core count clamped to 4...12)"
    if [ $cold -eq 1 ]; then
        echo "- Cache: each measured run after a successful \`sudo purge\`; no warm-up run"
    else
        echo "- Cache: repeat scans after one unmeasured warm-up run per tool. The warm-up's" \
            "timing is kept as run 0 (first touch in this session, not a cold cache), and" \
            "nothing here claims the whole tree stays cached"
    fi
    echo "- Experiment: $preset ($(echo "$tools" | tr ' ' ',')). $runs measured rounds, each in an" \
        "order shuffled from seed $seed. Fixture check: $([ $check -eq 1 ] && echo run || echo SKIPPED)"
    echo "- CPU times include children a tool waited for (git, for midden scan). Peak RSS is the" \
        "largest maximum resident set size among the tool and the children it waited for (wait4" \
        "maxima), not the combined peak of processes running at once"
}

{
    echo "# Machine conditions"
    echo
    echo "$(date '+%Y-%m-%d %H:%M %Z')"
    echo
    conditions
} >"$out/conditions.md"

# MARK: Fixture check

# Runs every chosen tool on the fixture, clean and with a locked folder.
# Clean: exit 0, no errors, the fixture's item count, du's bytes. Locked:
# the failure reported (exit status or error count), the readable items.
check_fixture() {
    local base clean locked expected expected_locked reference status counted
    local items bytes errors verdict failures=0
    base=$(mktemp -d "${TMPDIR:-/tmp}/midden-fixture.XXXXXX") || die "can't make the fixture folder"
    clean="$base/clean"
    locked="$base/locked"
    expected=$("$here/fixture.sh" "$clean") || die "can't build the fixture"
    expected_locked=$("$here/fixture.sh" --locked "$locked") || die "can't build the locked fixture"
    reference=$(/usr/bin/du -skx "$clean" | awk '{ print $1 * 1024 }')
    {
        echo "## Fixture check"
        echo
        echo "Fixture: $expected entries, $reference bytes allocated by du. Locked copy: a folder" \
            "nobody can list added, $expected_locked readable entries."
        echo
        echo "| Tool | Clean: exit, items, bytes, errors | Locked: exit, items, bytes, errors | Verdict |"
        echo "|---|---|---|---|"
    } >"$out/check.md"
    for tool in "${tool_list[@]}"; do
        verdict=pass
        run_tool "$tool" "$clean" "$out/raw/check-$tool.out" "$out/raw/check-$tool.time" \
            2>"$out/raw/check-$tool.err"
        status=$?
        set -- $(totals "$tool" "$out/raw/check-$tool.out" "$out/raw/check-$tool.err")
        items=$1 bytes=$2 errors=$3
        counted="$status, $items, $bytes, $errors"
        [ "$status" -eq 0 ] || verdict="fails: exit $status"
        [ "$errors" = - ] || [ "$errors" -eq 0 ] || verdict="fails: $errors errors"
        [ "$items" = - ] || [ "$items" -eq "$expected" ] || verdict="fails: items $items, not $expected"
        [ "$bytes" = - ] || [ "$bytes" -eq "$reference" ] || verdict="fails: bytes $bytes, not $reference"
        [ "$items$bytes" = -- ] && verdict="fails: no totals"

        run_tool "$tool" "$locked" "$out/raw/check-$tool-locked.out" "$out/raw/check-$tool-locked.time" \
            2>"$out/raw/check-$tool-locked.err"
        status=$?
        set -- $(totals "$tool" "$out/raw/check-$tool-locked.out" "$out/raw/check-$tool-locked.err")
        if [ "$status" -eq 0 ] && { [ "$3" = - ] || [ "$3" -eq 0 ]; }; then
            verdict="fails: the locked folder wasn't reported"
        fi
        [ "$1" = - ] || [ "$1" -eq "$expected_locked" ] || verdict="fails: locked items $1, not $expected_locked"
        [ "$2" = - ] || [ "$2" -eq "$reference" ] || verdict="fails: locked bytes $2, not $reference"
        echo "| $tool | $counted | $status, $1, $2, $3 | $verdict |" >>"$out/check.md"
        case $verdict in pass) ;; *) failures=$((failures + 1)) ;; esac
    done
    chmod -R u+rwx "$locked" 2>/dev/null
    rm -rf "$base"
    echo >>"$out/check.md"
    return $failures
}

if [ $check -eq 1 ]; then
    echo "Checking every tool on the fixture..." >&2
    check_fixture || {
        cat "$out/check.md" >&2
        die "a tool failed the fixture check; nothing was timed (see $out/check.md)"
    }
else
    printf '## Fixture check\n\nSkipped with --skip-check.\n\n' >"$out/check.md"
fi

# MARK: Measuring

echo "dataset,tool,run,position,wall_s,user_s,sys_s,max_rss_bytes,peak_footprint_bytes,instructions,cycles,items,bytes,errors,load1,status" >"$runs_csv"

# Records one run of `tool` as round $3, position $4.
measure() {
    local tool=$1 dir=$2 run=$3 position=$4 prefix stdout status counted fields load
    prefix="$out/raw/$tag-$tool.run$run"
    stdout="$prefix.out"
    [ "$tool" = scan ] && stdout="$prefix.json"
    load=$(load1)
    if [ $cold -eq 1 ] && [ "$run" -gt 0 ]; then
        if ! sudo purge; then
            echo "$key,$tool,$run,$position,-,-,-,-,-,-,-,-,-,-,$load,purge-failed" >>"$runs_csv"
            echo "  run $run/$runs $tool: purge failed, not run" >&2
            return
        fi
    fi
    run_tool "$tool" "$dir" "$stdout" "$prefix.time" 2>"$prefix.err"
    status=$?
    counted=$(totals "$tool" "$stdout" "$prefix.err")
    fields=$(rusage_fields "$prefix.time")
    echo "$key,$tool,$run,$position,$(echo "$fields" | tr ' ' ','),$(echo "$counted" | tr ' ' ','),$load,$status" \
        | tr -d '\r' >>"$runs_csv"
    echo "  run $run/$runs $tool: $(echo "$fields" | awk '{ print $1 }') s, exit $status (load $load)" >&2
}

{
    echo "# Midden benchmark"
    echo
    sed '1,2d' "$out/conditions.md"
    echo
    cat "$out/check.md"
} >"$md"

RANDOM=$seed
index=0
for dir in "${dirs[@]}"; do
    root=${roots[$index]}
    index=$((index + 1))
    name=${label:-$(display "$root")}
    key=$(echo "$name" | tr -d ',')  # The dataset column of the CSV: no commas.
    # Unique per folder, so two folders with the same name keep their files apart.
    tag="$(slug "$(basename "$root")")-$(printf '%s' "$root" | cksum | awk '{ print $1 }')"
    echo "== $name" >&2
    load_start=$(uptime | sed 's/.*load averages*: //')
    started=$(date '+%H:%M')
    schedule=

    if [ $cold -eq 0 ]; then
        position=1
        for tool in "${tool_list[@]}"; do
            measure "$tool" "$dir" 0 $position
            position=$((position + 1))
        done
    fi
    run=1
    while [ "$run" -le "$runs" ]; do
        wait_for_load
        shuffle
        schedule="$schedule- Round $run: ${order[*]}
"
        position=1
        for tool in "${order[@]}"; do
            wait_for_load
            measure "$tool" "$dir" $run $position
            position=$((position + 1))
        done
        run=$((run + 1))
    done
    load_end=$(uptime | sed 's/.*load averages*: //')

    # MARK: Validity

    # A run is valid for comparing speed when it exited 0, read everything,
    # reported totals, and matches the round's reference tool.
    awk -F, -v OFS=, -v refs="$reference_tools" '
        NR == 1 { print $0, "valid", "reason"; next }
        {
            n++
            for (i = 1; i <= NF; i++) f[n, i] = $i
            dataset = $1; tool = $2; run = $3; items = $12; bytes = $13; errors = $14; status = $16
            reason = ""
            if (run == 0) reason = "warm-up run: first touch in this session"
            else if (status == "purge-failed") reason = "purge failed"
            else {
                if (status != 0) reason = "exit status " status
                if (errors != "-" && errors > 0) reason = reason (reason == "" ? "" : " and ") "read errors: " errors
                if (items == "-" && bytes == "-") reason = reason (reason == "" ? "" : " and ") "no totals"
            }
            why[n] = reason
        }
        END {
            count = split(refs, preferred, " ")
            for (p = 1; p <= count; p++)
                for (r = 1; r <= n; r++)
                    if (f[r, 2] == preferred[p] && why[r] == "" && !((f[r, 1], f[r, 3]) in ref))
                        ref[f[r, 1], f[r, 3]] = r
            for (r = 1; r <= n; r++) {
                if (why[r] == "" && ((f[r, 1], f[r, 3]) in ref)) {
                    q = ref[f[r, 1], f[r, 3]]
                    if ((f[r, 12] != "-" && f[q, 12] != "-" && f[r, 12] != f[q, 12]) \
                        || (f[r, 13] != "-" && f[q, 13] != "-" && f[r, 13] != f[q, 13]))
                        why[r] = "totals differ from " f[q, 2] " in round " f[r, 3]
                }
                line = f[r, 1]
                for (i = 2; i <= 16; i++) line = line OFS f[r, i]
                print line, (why[r] == "" ? "yes" : "no"), why[r]
            }
        }' "$runs_csv" >"$csv"

    # MARK: Report for this folder

    {
        echo
        echo "## $name"
        echo
        echo "File system: $(filesystem "$root"). Measured from $started to $(date '+%H:%M')."
        echo "Load average (1, 5, 15 min): $load_start at the start, $load_end at the end."
        echo
        echo "| Tool | Valid / attempted | Wall, median | Wall, min–max | User CPU | System CPU | Peak RSS | Items/s, own count | Valid runs, in order (s) |"
        echo "|---|:-:|---:|---:|---:|---:|---:|---:|---|"
        for tool in "${tool_list[@]}"; do
            awk -F, -v name="$key" -v tool="$tool" '
                function median(values, n,    i, j, t) {
                    for (i = 2; i <= n; i++) for (j = i; j > 1 && values[j - 1] > values[j]; j--) {
                        t = values[j]; values[j] = values[j - 1]; values[j - 1] = t
                    }
                    return n % 2 ? values[(n + 1) / 2] : (values[n / 2] + values[n / 2 + 1]) / 2
                }
                $1 == name && $2 == tool && $3 > 0 {
                    tried++
                    if ($17 != "yes") next
                    n++; wall[n] = $5; user[n] = $6; sys[n] = $7; rss[n] = $8; items = $12
                    every = every (n > 1 ? ", " : "") $5
                    if (n == 1 || $5 < low) low = $5
                    if (n == 1 || $5 > high) high = $5
                }
                END {
                    if (tried == 0) exit
                    if (n == 0) { printf "| %s | 0 / %d | | | | | | | |\n", tool, tried; exit }
                    w = median(wall, n)
                    printf "| %s | %d / %d | %.2f s | %.2f–%.2f s | %.2f s | %.2f s | %.0f MB | %s | %s |\n",
                        tool, n, tried, w, low, high, median(user, n), median(sys, n), median(rss, n) / 1e6,
                        (items != "-" && w > 0) ? sprintf("%.0fk", items / w / 1000) : "n/a", every
                }' "$csv"
        done
        echo
        echo "Medians and ranges use valid runs only. Items/s divides each tool's own item count by" \
            "its median wall time; du reports no item count, and find does less work (no sizes)."
        echo
        echo "Order of each round (seed $seed):"
        echo
        printf '%s' "$schedule"
        invalid=$(awk -F, -v name="$key" '$1 == name && $3 > 0 && $17 == "no" {
                printf "- %s, round %s: %s\n", $2, $3, $18 }' "$csv")
        if [ -n "$invalid" ]; then
            echo
            echo "Invalid runs, left out of the medians:"
            echo
            echo "$invalid"
        fi
        echo
        echo "### Totals"
        echo
        echo "| Tool | Items | Bytes allocated | Errors, most in a run | Same in every valid run |"
        echo "|---|---:|---:|---:|:-:|"
        for tool in "${tool_list[@]}"; do
            awk -F, -v name="$key" -v tool="$tool" '
                $1 == name && $2 == tool && $3 > 0 {
                    if ($14 != "-" && $14 + 0 > most) most = $14 + 0
                    if ($14 != "-") reported = 1
                    if ($17 != "yes") next
                    if (!(seen++)) { items = $12; bytes = $13 }
                    if ($12 != items || $13 != bytes) varies = 1
                }
                END {
                    if (!seen) { printf "| %s | no valid run | | %s | |\n", tool, reported ? most + 0 : "-"; exit }
                    printf "| %s | %s | %s | %s | %s |\n", tool, items, bytes,
                        reported ? most + 0 : "-", varies ? "no" : "yes"
                }' "$csv"
        done
        echo
        echo "Item counts exclude the root folder (find counts it, so its count is reduced by one)." \
            "du -k prints 1024-byte units. Errors are folders a tool couldn't fully read: its own" \
            "count, the report's readErrors for midden scan, or stderr lines for du and find."
        json=$(cat "$out/raw/$tag-engine-json".run[1-9]*.out 2>/dev/null | tr ' ' '\n' | awk -F= '
            $1 == "json_seconds" { s[++n] = $2 } $1 == "json_bytes" { b = $2 }
            END { if (n) printf "%s s for %.1f MB (in-process, first measured run)", s[1], b / 1e6 }')
        [ -n "$json" ] && echo "JSON encoding inside engine-json: $json."
    } >>"$md"
done

echo >&2
echo "Results: $md" >&2
echo "Runs:    $csv" >&2
