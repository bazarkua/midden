// midden-bench: times one stage of Midden's scan on its own, so a benchmark
// can show where a scan spends its time. Benchmarks/run.sh drives it.
//
//   midden-bench walk PATH        the walker alone, like a plain disk-usage scan
//   midden-bench classify PATH    the walk plus classifying every folder
//   midden-bench read PATH        the scan's reading phase (classify + space map)
//   midden-bench scan PATH        the whole scan; never encodes JSON
//   midden-bench scan-json PATH   the whole scan, then encodes the report as
//                                 `midden scan --json` does and discards it:
//                                 compared with `scan` at the process level,
//                                 it measures what encoding adds
//
// Prints one line: items, allocated bytes, folders that couldn't be read,
// and the seconds the stage took inside the process (scan-json adds the
// encoding's seconds and size). Exits with 1 when any folder couldn't be
// fully read, so a partial walk isn't taken for the same work.

import Foundation
import MiddenCore

let usage = """
    usage: midden-bench walk|classify|read|scan|scan-json PATH [--threads N]
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var threads: Int?
if let index = arguments.firstIndex(of: "--threads") {
    guard index + 1 < arguments.count, let count = Int(arguments[index + 1]), count > 0 else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
    threads = count
    arguments.removeSubrange(index...(index + 1))
}
let encodes = arguments.first == "scan-json"
guard arguments.count == 2, let stage = encodes ? .scan : Benchmark.Stage(rawValue: arguments[0]) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
let root = (arguments[1] as NSString).expandingTildeInPath

do {
    let outcome = try await Benchmark.run(stage, root: root, threads: threads)
    var line =
        "items=\(outcome.items) bytes=\(outcome.bytes) errors=\(outcome.readErrors)"
        + " threads=\(threads ?? Benchmark.defaultThreads) stage=\(arguments[0])"
        + " seconds=\(String(format: "%.3f", outcome.seconds))"
    if encodes, let report = outcome.report {
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(report)
        let seconds = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e9
        line += " json_seconds=\(String(format: "%.3f", seconds)) json_bytes=\(json.count)"
    }
    print(line)
    exit(outcome.readErrors > 0 ? 1 : 0)
} catch {
    FileHandle.standardError.write(Data("midden-bench: \(error)\n".utf8))
    exit(1)
}
