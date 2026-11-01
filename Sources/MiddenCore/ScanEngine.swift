import Foundation

/// The whole scan as blocking code: one parallel walk, then the worktree
/// audits and the simulator query, then the report.
struct ScanEngine {
    var options: ScanOptions

    func run(
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancellation: CancellationFlag
    ) throws -> ScanReport {
        let started = Date()
        let home = try System.canonicalPath(options.home.path)
        let delegate = ScanDelegate()
        let walk = try Walker(
            root: home, delegate: delegate,
            threadCount: options.threadCount ?? WalkDefaults.threadCount
        ).run(cancellation: cancellation, progress: progress)
        if cancellation.isCancelled { throw MiddenError.cancelled }

        let now = Date()
        let minimum = options.minimumBytes
        var findings: [Finding] = []
        var worktrees: [(match: WorktreeMatch, directory: SizedDirectory<DirectoryMatch>)] = []
        let devicesFolder = Simulators.devicesFolder(home: home)
        var simulatorSizes: [String: Int64] = [:]

        for directory in walk.marked {
            guard let match = directory.mark else { continue }
            let total = directory.total
            if directory.path == devicesFolder {
                for child in directory.children where child.isDirectory {
                    simulatorSizes[child.name] = child.bytes
                }
            }
            guard total >= minimum else { continue }
            let breakdown = Findings.breakdown(total: total, children: directory.children)
            switch match {
            case .rule(let rule):
                findings.append(Findings.rule(rule, path: directory.path, bytes: total, breakdown: breakdown))
            case .buildFolder(let build):
                findings.append(Findings.buildFolder(
                    build, path: directory.path, bytes: total, breakdown: breakdown, now: now,
                    idleWindow: options.projectIdleWindow))
            case .worktree(let worktree):
                worktrees.append((worktree, directory))
            }
        }

        if !worktrees.isEmpty {
            let auditor = WorktreeAuditor(
                processes: .current(), now: now, activeWindow: options.worktreeActiveWindow)
            let audits = Background.map(worktrees.map(\.match)) { auditor.audit($0) }
            for (worktree, audit) in zip(worktrees, audits) {
                let total = worktree.directory.total
                findings.append(Findings.worktree(
                    worktree.match, audit: audit, bytes: total,
                    breakdown: Findings.breakdown(total: total, children: worktree.directory.children)))
            }
        }

        for hit in delegate.files where hit.entry.allocatedSize >= minimum {
            findings.append(Findings.file(hit.match, path: hit.path, entry: hit.entry))
        }

        if !simulatorSizes.isEmpty, let devices = Simulators.unavailable(home: home) {
            for device in devices {
                guard let bytes = simulatorSizes[device.udid], bytes >= minimum else { continue }
                findings.append(Findings.simulator(device, path: devicesFolder + "/" + device.udid, bytes: bytes))
            }
        }

        findings.sort { ($0.bytes, $1.id) > ($1.bytes, $0.id) }
        let topFolders = (walk.root?.children ?? [])
            .filter(\.isDirectory)
            .sorted { $0.bytes > $1.bytes }
            .map { FolderUsage(path: home + "/" + $0.name, name: $0.name, bytes: $0.bytes) }

        return ScanReport(
            home: home, startedAt: started, duration: Date().timeIntervalSince(started),
            itemsScanned: walk.items, bytesScanned: walk.totalBytes,
            disk: System.diskSpace(home), findings: findings, topFolders: topFolders,
            unreadableCount: walk.unreadable,
            needsFullDiskAccess: System.needsFullDiskAccess(home: home))
    }
}

enum WalkDefaults {
    /// Listing is I/O-bound on an SSD; past a dozen threads the gains stop.
    static var threadCount: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount, 4), 12)
    }
}
