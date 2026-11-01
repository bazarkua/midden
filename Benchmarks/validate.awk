# Decides which benchmark runs count for comparing speed. Reads run.sh's
# raw rows and prints them with two more columns: valid and reason.
#
#   yes         every required field is there and numeric, the tool exited
#               0 and read every folder, and its totals equal those of the
#               round's reference run
#   unverified  the same, but the round has no reference run with the
#               totals to compare with: a standalone timing, left out of
#               comparisons
#   no          anything else, with the reason
#
# Missing evidence never passes. Required for every tool: wall, user and
# system time, peak RSS and the exit status. Also items, bytes and errors
# for the scanners; bytes and errors for du (no item count); items and
# errors for find (no sizes). Footprint, instructions, cycles, findings
# and JSON size may be unavailable.
#
# Columns: 1 dataset, 2 tool, 3 run, 4 position, 5 wall_s, 6 user_s,
# 7 sys_s, 8 max_rss_bytes, 9 peak_footprint_bytes, 10 instructions,
# 11 cycles, 12 items, 13 bytes, 14 errors, 15 load1, 16 status,
# 17 findings, 18 json_bytes.
#
# Usage: awk -F, -v refs="c c-1 ..." -f validate.awk runs.csv
#   refs: tools that can be a round's reference, in order of preference.

BEGIN { FS = OFS = "," }

function numeric(value) { return value ~ /^[0-9]+(\.[0-9]+)?$/ }

# The totals a tool must report.
function needs_items(tool) { return tool != "du" }
function needs_bytes(tool) { return tool != "find" }

function add(reason, more) { return reason (reason == "" ? "" : " and ") more }

NR == 1 { print $0, "valid", "reason"; next }

{
    n++
    columns = NF
    for (i = 1; i <= NF; i++) field[n, i] = $i
    tool = $2; run = $3; status = $16
    reason = ""
    if (run !~ /^[0-9]+$/) reason = "no round number"
    else if (run == 0) reason = "warm-up run: first touch in this session"
    else if (status == "purge-failed") reason = "purge failed"
    else {
        if (!numeric(status)) reason = add(reason, "no exit status")
        else if (status != 0) reason = add(reason, "exit status " status)
        if (!numeric($5) || !numeric($6) || !numeric($7)) reason = add(reason, "timing missing")
        if (!numeric($8)) reason = add(reason, "peak RSS missing")
        if (needs_items(tool) && !numeric($12)) reason = add(reason, "item count missing")
        if (needs_bytes(tool) && !numeric($13)) reason = add(reason, "byte total missing")
        if (!numeric($14)) reason = add(reason, "error count missing")
        else if ($14 > 0) reason = add(reason, "read errors: " $14)
    }
    why[n] = reason
}

END {
    count = split(refs, preferred, " ")
    # A round's reference: the first preferred tool whose run in that round
    # passed and has both totals.
    for (p = 1; p <= count; p++)
        for (r = 1; r <= n; r++)
            if (field[r, 2] == preferred[p] && why[r] == "" && numeric(field[r, 12]) \
                && numeric(field[r, 13]) && !((field[r, 1], field[r, 3]) in reference))
                reference[field[r, 1], field[r, 3]] = r
    for (r = 1; r <= n; r++) {
        verdict = "no"
        if (why[r] == "") {
            if ((field[r, 1], field[r, 3]) in reference) {
                q = reference[field[r, 1], field[r, 3]]
                verdict = "yes"
                if (needs_items(field[r, 2]) && field[r, 12] != field[q, 12]) verdict = "no"
                if (needs_bytes(field[r, 2]) && field[r, 13] != field[q, 13]) verdict = "no"
                if (verdict == "no") why[r] = "totals differ from " field[q, 2] " in round " field[r, 3]
            } else {
                verdict = "unverified"
                why[r] = "unverified against a reference: none in round " field[r, 3]
            }
        }
        line = field[r, 1]
        for (i = 2; i <= columns; i++) line = line OFS field[r, i]
        print line, verdict, why[r]
    }
}
