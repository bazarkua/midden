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
        let home: String
        do {
            home = try System.canonicalPath(options.home.path)
        } catch {
            throw MiddenError.unreadable(path: options.home.path, code: error.code.rawValue)
        }
        // Without Full Disk Access, protected folders are skipped rather than
        // opened: opening some of them waits on a permission prompt. The probe
        // itself gets a deadline for the same reason.
        let fullDiskAccess = options.fullDiskAccess ?? FullDiskAccess.isGranted(home: URL(fileURLWithPath: home))
        let delegate = ScanDelegate(skipProtected: !fullDiskAccess)
        let walk: WalkResult<DirectoryMatch>
        do {
            walk = try Walker(
                root: home, delegate: delegate,
                threadCount: options.threadCount ?? WalkDefaults.threadCount
            ).run(cancellation: cancellation, progress: progress)
        } catch {
            throw MiddenError.unreadable(path: home, code: error.code.rawValue)
        }
        if cancellation.isCancelled { throw MiddenError.cancelled }
        // An empty report would read as "nothing to clean".
        if let rootError = walk.rootError {
            throw MiddenError.unreadable(path: home, code: rootError.code.rawValue)
        }

        let now = Date()
        let minimum = options.minimumBytes
        var findings: [Finding] = []
        var worktrees: [(match: WorktreeMatch, bytes: Int64, breakdown: [Slice])] = []
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
                worktrees.append((worktree, total, breakdown))
            }
        }

        // Worktrees outside home, found through the repositories inside it,
        // sized with the same walker.
        let external = ExternalWorktrees.discover(gitDirectories: delegate.gitDirectories, home: home)
        for worktree in external.worktrees {
            if cancellation.isCancelled { throw MiddenError.cancelled }
            guard let sized = try? Walker(root: worktree.path, delegate: SizeOnly())
                .run(cancellation: cancellation)
            else { continue }
            guard sized.totalBytes >= minimum else { continue }
            worktrees.append((
                worktree, sized.totalBytes,
                Findings.breakdown(total: sized.totalBytes, children: sized.root?.children ?? [])))
        }

        if !worktrees.isEmpty {
            let auditor = WorktreeAuditor(
                processes: .current(), now: now, activeWindow: options.worktreeActiveWindow)
            let audits = Background.map(worktrees.map(\.match)) { auditor.audit($0) }
            for (worktree, audit) in zip(worktrees, audits) {
                findings.append(Findings.worktree(
                    worktree.match, audit: audit, home: home, bytes: worktree.bytes,
                    breakdown: worktree.breakdown))
            }
        }

        // One finding per file: hard links to the same file are reported once,
        // under the first of their paths.
        var linked: [UInt64: [ScanDelegate.FileHit]] = [:]
        for hit in delegate.files where hit.entry.allocatedSize >= minimum {
            if hit.entry.linkCount > 1 {
                linked[hit.entry.inode, default: []].append(hit)
            } else {
                findings.append(Findings.file(hit.match, path: hit.path, entry: hit.entry))
            }
        }
        for hits in linked.values {
            let names = hits.sorted { $0.path < $1.path }
            findings.append(Findings.file(
                names[0].match, path: names[0].path, entry: names[0].entry,
                otherNames: names.dropFirst().map(\.path)))
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
            needsFullDiskAccess: !fullDiskAccess)
    }
}

enum WalkDefaults {
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
