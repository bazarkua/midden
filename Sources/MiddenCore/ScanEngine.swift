import Foundation
import Synchronization

/// The whole scan as blocking code: one parallel walk, then the worktree
/// audits and the simulator query, then the report.
struct ScanEngine {
    var options: ScanOptions
    /// Builds the space map; replaceable in tests.
    var buildSpaceMap: @Sendable (
        _ records: [SpaceRecord], _ root: String, _ findings: [Finding], _ aliases: [String: [String]]
    ) -> SpaceNode? = { records, root, findings, aliases in
        SpaceMap.build(records, root: root, findings: findings, aliases: aliases, floor: WalkDefaults.mapFloor)
    }

    func run(
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancellation: CancellationFlag
    ) throws -> ScanReport {
        let started = Date()
        let startedMonotonic = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let home: String
        do {
            home = try System.canonicalPath(options.home.path)
        } catch {
            throw MiddenError.unreadable(path: options.home.path, code: error.code.rawValue)
        }
        let disk = System.diskSpace(home)
        let estimator = ProgressEstimator(
            expectedBytes: options.expectedBytes ?? max(disk.total - disk.free, 1),
            expectedItems: options.expectedItems ?? System.usedInodes(home),
            report: progress)
        estimator.begin(.preparing, detail: "Checking access")

        // Without Full Disk Access, protected folders are skipped rather than
        // opened: opening some of them waits on a permission prompt. The probe
        // itself gets a deadline for the same reason.
        // Access is a property of this process, probed on the account's real
        // home, whatever folder is scanned; and protected folders are
        // recognized by where they are in that home.
        let accountHome = options.privacyHome ?? System.accountHome()
        let fullDiskAccess = options.fullDiskAccess
            ?? FullDiskAccess.isGranted(home: URL(fileURLWithPath: accountHome))
        // Starting inside a protected folder would open it, and wait on the
        // prompt the skipping exists to avoid.
        if !fullDiskAccess, PrivacyProtected.covers(home, accountHome: accountHome) {
            throw MiddenError.unreadable(path: home, code: EPERM)
        }
        let delegate = ScanDelegate(skipProtected: !fullDiskAccess, accountHome: accountHome)
        let walk: WalkResult<DirectoryMatch>
        do {
            estimator.begin(.reading)
            walk = try Walker(
                root: home, delegate: delegate,
                threadCount: options.threadCount ?? WalkDefaults.threadCount,
                mapFloor: WalkDefaults.mapFloor,
                threads: options.walkerThreads ?? .process,
                lister: options.lister ?? { path, reader throws(POSIXError) in try reader.listing(atPath: path) }
            ).run(cancellation: cancellation) { estimator.reading($0) }
        } catch {
            throw MiddenError.unreadable(path: home, code: error.code.rawValue)
        }
        // Taken out of the delegate, which a stuck walker thread may keep.
        let collected = delegate.takeCollected()
        if cancellation.isCancelled { throw MiddenError.cancelled }
        // An empty report would read as "nothing to clean".
        if let rootError = walk.rootError {
            throw MiddenError.unreadable(path: home, code: rootError.code.rawValue)
        }

        let now = Date()
        let minimum = options.minimumBytes
        var findings: [Finding] = []
        /// Findings whose rule asks for a "not in use" check, by index.
        var inUseChecks: [(index: Int, by: Rule.InUseBy)] = []
        var worktrees: [(match: WorktreeMatch, bytes: Int64, breakdown: [Slice])] = []
        // `worktrees` holds the ones inside home, sized by the walk.
        let devicesFolder = Simulators.devicesFolder(home: home)
        var simulatorSizes: [String: Int64] = [:]

        // Findings inside a container cover part of it; its own finding is
        // the rest. So for a rule that reports a folder without claiming
        // what's in it (Downloads): the installers, large files, build
        // folders and worktrees inside are left out of its size. A file
        // with several names counts once, as its finding does.
        var files: [Containers.Sized] = []
        var seen: Set<UInt64> = []
        for hit in collected.files.sorted(by: { $0.path < $1.path }) {
            if hit.entry.linkCount > 1, !seen.insert(hit.entry.inode).inserted { continue }
            files.append(Containers.Sized(path: hit.path, total: hit.entry.allocatedSize, isContainer: false))
        }
        let remainders = Containers.remainders(walk.marked.compactMap { directory -> Containers.Sized? in
            guard let match = directory.mark else { return nil }
            var isContainer = false
            if case .rule(let rule) = match { isContainer = rule.isContainer || !rule.rule.claimsSubtree }
            return Containers.Sized(
                path: directory.path, total: directory.total, isContainer: isContainer,
                children: isContainer ? directory.children : [])
        } + files)
        for directory in walk.marked {
            guard let match = directory.mark else { continue }
            let remainder = remainders[directory.path]
            var total = remainder?.bytes ?? directory.total
            var children = remainder?.children ?? directory.children
            // A finding that deletes only some of its contents shows only
            // those, as measured during the walk.
            var measure: ContentsMeasure?
            if match.contentsPolicy != nil {
                let measured = collected.contents[directory.path] ?? .unknown
                total = measured.bytes
                children = measured.children
                measure = measured
            }
            if directory.path == devicesFolder {
                for child in directory.children where child.isDirectory {
                    simulatorSizes[child.name] = child.bytes
                }
            }
            guard total >= minimum else { continue }
            let breakdown = Findings.breakdown(total: total, children: children)
            switch match {
            case .rule(let rule):
                if rule.rule.checkInUse { inUseChecks.append((findings.count, rule.rule.inUseBy)) }
                var finding = Findings.rule(rule, path: directory.path, bytes: total, breakdown: breakdown)
                if let measure { finding = Findings.measured(finding, measure) }
                findings.append(finding)
            case .buildFolder(let build):
                if build.kind.checkInUse { inUseChecks.append((findings.count, .folder)) }
                var finding = Findings.buildFolder(
                    build, path: directory.path, bytes: total, breakdown: breakdown, now: now,
                    idleWindow: options.projectIdleWindow)
                if let measure { finding = Findings.measured(finding, measure) }
                findings.append(finding)
            case .worktree(let worktree):
                worktrees.append((worktree, total, breakdown))
            }
        }

        if !inUseChecks.isEmpty {
            let usage = options.processUsage?() ?? ProcessUsage.current()
            for (index, scope) in inUseChecks { findings[index] = Findings.checkingUse(findings[index], usage, by: scope) }
        }

        // Worktrees outside home, found through the repositories inside it.
        // One counted pass checks every worktree: those outside home are
        // sized first with the same walker (and dropped if too small), then
        // each is audited. Several run at once, so each walker gets 2 threads.
        let external = ExternalWorktrees.discover(gitDirectories: collected.gitDirectories, home: home)
        // Those outside home first: sizing them is the slow part, and
        // starting it early keeps the tail of the phase short.
        let candidates =
            external.worktrees.map { WorktreeCandidate(match: $0, size: nil) }
            + worktrees.map { WorktreeCandidate(match: $0.match, size: ($0.bytes, $0.breakdown)) }
        if !candidates.isEmpty {
            estimator.begin(.worktrees, detail: "Checking worktrees", total: candidates.count)
            let auditor = WorktreeAuditor(
                processes: .current(), now: now, activeWindow: options.worktreeActiveWindow)
            let finished = Atomic<Int>(0)
            let checked = Background.map(candidates) { candidate -> Finding? in
                estimator.started(candidate.match.path)
                defer {
                    estimator.step(finished.add(1, ordering: .relaxed).newValue, path: candidate.match.path)
                }
                if cancellation.isCancelled { return nil }
                var size = candidate.size
                if size == nil {
                    guard let sized = try? Walker(
                        root: candidate.match.path, delegate: SizeOnly(), threadCount: 2
                    ).run(cancellation: cancellation), sized.totalBytes >= minimum
                    else { return nil }
                    size = (sized.totalBytes, Findings.breakdown(
                        total: sized.totalBytes, children: sized.root?.children ?? []))
                }
                guard let (bytes, breakdown) = size else { return nil }
                return Findings.worktree(
                    candidate.match, audit: auditor.audit(candidate.match), home: home, bytes: bytes,
                    breakdown: breakdown)
            }
            if cancellation.isCancelled { throw MiddenError.cancelled }
            findings += checked.compactMap { $0 }
        }

        // One finding per file: hard links to the same file are reported once,
        // under the first of their paths.
        var linked: [UInt64: [ScanDelegate.FileHit]] = [:]
        for hit in collected.files where hit.entry.allocatedSize >= minimum {
            if hit.entry.linkCount > 1 {
                linked[hit.entry.inode, default: []].append(hit)
            } else {
                findings.append(Findings.file(hit.match, path: hit.path, entry: hit.entry))
            }
        }
        var aliases: [String: [String]] = [:]
        for hits in linked.values {
            let names = hits.sorted { $0.path < $1.path }
            findings.append(Findings.file(
                names[0].match, path: names[0].path, entry: names[0].entry,
                otherNames: names.dropFirst().map(\.path)))
            aliases[names[0].path] = names.dropFirst().map(\.path)
        }

        if !simulatorSizes.isEmpty {
            estimator.begin(.simulators, detail: "Checking simulators")
        }
        if !simulatorSizes.isEmpty, let devices = Simulators.unavailable(home: home) {
            for device in devices {
                guard let bytes = simulatorSizes[device.udid], bytes >= minimum else { continue }
                findings.append(Findings.simulator(device, path: devicesFolder + "/" + device.udid, bytes: bytes))
            }
        }

        estimator.begin(.finishing, detail: "Building the report")
        findings.sort { ($0.bytes, $1.id) > ($1.bytes, $0.id) }
        let topFolders = (walk.root?.children ?? [])
            .filter(\.isDirectory)
            .sorted { $0.bytes > $1.bytes }
            .map { FolderUsage(path: home + "/" + $0.name, name: $0.name, bytes: $0.bytes) }
        let spaceMap = buildSpaceMap(walk.spaceRecords, home, findings, aliases)

        // Measured last, so everything above counts, and on a monotonic
        // clock, which a wall-clock change can't move.
        let duration = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - startedMonotonic) / 1e9
        return ScanReport(
            home: home, startedAt: started, duration: duration,
            itemsScanned: walk.items, bytesScanned: walk.totalBytes,
            disk: disk, findings: findings, topFolders: topFolders,
            unreadableCount: walk.unreadable,
            needsFullDiskAccess: !fullDiskAccess,
            spaceMap: spaceMap,
            skippedWithoutFullDiskAccess: walk.skipped,
            readErrors: walk.readErrors,
            skippedFolders: collected.skippedFolders)
    }
}

enum WalkDefaults {
    /// Smallest file or folder the walk remembers for the space map. In a
    /// 430 GB home with 5.2M items, 57,108 items are at least 1 MB, 6,011 at
    /// least 20 MB and 2,702 at least 50 MB. 20 MB is 0.05% of a 40 GB home,
    /// so in any bigger home the map's own threshold (0.05% of the root) is
    /// higher and the floor hides nothing it would show, while the walk keeps
    /// only a few thousand records. Measured cost: 27.08 s median scan time
    /// with the map against 26.81 s without (+1%, within run-to-run noise).
    static let mapFloor: Int64 = 20_000_000

    /// A folder listing that makes no progress for this long is given up,
    /// e.g. open() waiting on a privacy prompt. A large folder keeps making
    /// progress batch by batch, so this only catches calls that are stuck.
    static let stallTimeout: TimeInterval = 5

    /// Listing is mostly kernel time. Walking ~/Work (2.6M items) on a
    /// 14-core M-series Mac took 39 s on 1 thread, 11 s on 4, 8.4–9.5 s on
    /// 8 and 12, and got slower again on 16 and 24.
    static var threadCount: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount, 4), 12)
    }
}

/// A worktree to check: sized by the walk, or (outside home) not yet.
private struct WorktreeCandidate: Sendable {
    var match: WorktreeMatch
    var size: (bytes: Int64, breakdown: [Slice])?
}
