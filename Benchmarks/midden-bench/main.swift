// midden-bench: times one stage of Midden's scan on its own, so a benchmark
// can show where a scan spends its time. Benchmarks/run.sh drives it.
//
//   midden-bench walk PATH        the walker alone, like a plain disk-usage scan
//   midden-bench classify PATH    the walk plus classifying every folder
//   midden-bench read PATH        the scan's reading phase (classify + space map)
//   midden-bench scan PATH        the whole scan, without JSON output
//
// Prints one line: items, allocated bytes, folders that couldn't be read,
// and the seconds the stage took inside the process.

import Foundation
import MiddenCore

let usage = """
    usage: midden-bench walk|classify|read|scan PATH [--threads N]
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
guard arguments.count == 2, let stage = Benchmark.Stage(rawValue: arguments[0]) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
let root = (arguments[1] as NSString).expandingTildeInPath

do {
    let outcome = try await Benchmark.run(stage, root: root, threads: threads)
    print(
        "items=\(outcome.items) bytes=\(outcome.bytes) errors=\(outcome.readErrors)"
            + " threads=\(threads ?? Benchmark.defaultThreads) stage=\(stage.rawValue)"
            + " seconds=\(String(format: "%.3f", outcome.seconds))")
} catch {
    FileHandle.standardError.write(Data("midden-bench: \(error)\n".utf8))
    exit(1)
}
