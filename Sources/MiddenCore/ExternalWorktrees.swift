import Foundation

/// Linked worktrees that live outside the home folder but belong to a
/// repository inside it. AI coding tools often put them in /private/tmp.
///
/// Midden only reports or removes one when it can prove the link both ways
/// from the file system, so a folder outside home can't pass for a worktree
/// by containing a forged `.git` file.
enum ExternalWorktrees {
    struct Discovery {
        var worktrees: [WorktreeMatch] = []
        /// Registered worktrees whose folder no longer exists
        /// (`git worktree prune` removes these records).
        var prunable = 0
    }

    struct Unproven: Error {
        var reason: String
    }

    /// Reads the list of linked worktrees of each repository
    /// (`<repository>/.git/worktrees/*/gitdir`) and returns the ones outside
    /// `home` that `verify` accepts.
    static func discover(gitDirectories: [String], home: String) -> Discovery {
        var discovery = Discovery()
        let reader = DirectoryReader(bufferSize: 16 * 1024)
        for gitDirectory in Set(gitDirectories).sorted() {
            let admin = gitDirectory + "/worktrees"
            guard let entries = try? reader.entries(atPath: admin) else { continue }
            for entry in entries where entry.kind == .directory {
                guard let target = gitdirLine(admin + "/" + entry.name + "/gitdir", relativeTo: admin + "/" + entry.name),
                    target.hasSuffix("/.git")
                else { continue }
                let registered = String(target.dropLast("/.git".count))
                if registered == home || registered.hasPrefix(home + "/") { continue }  // The walk sees it.
                var info = stat()
                if lstat(registered, &info) != 0 {
                    if errno == ENOENT { discovery.prunable += 1 }
                    continue
                }
                guard let path = try? System.canonicalPath(registered) else { continue }
                if case .success(let match) = verify(path, home: home) {
                    discovery.worktrees.append(match)
                }
            }
        }
        return discovery
    }

    /// Proves from scratch that `path`, outside `home`, is a linked worktree
    /// of a repository inside `home`:
    /// - `path` is canonical (no symlinks, `.` or `..`) and doesn't contain home;
    /// - its `.git` is a file pointing to `<repository>/.git/worktrees/<name>`;
    /// - that repository is inside home;
    /// - the repository's `worktrees/<name>/gitdir` points back to `path`.
    static func verify(_ path: String, home: String) -> Result<WorktreeMatch, Unproven> {
        func fail(_ reason: String) -> Result<WorktreeMatch, Unproven> {
            .failure(Unproven(reason: reason))
        }
        guard path.hasPrefix("/"), (try? System.canonicalPath(path)) == path else {
            return fail("Its path isn't canonical.")
        }
        guard path != "/", path != home, !home.hasPrefix(path + "/") else {
            return fail("It contains your home folder.")
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            return fail("It isn't a folder.")
        }
        guard lstat(path + "/.git", &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            let gitDir = gitdirLine(path + "/.git", relativeTo: path)
        else {
            return fail("It isn't a linked git worktree.")
        }
        let admin = (gitDir as NSString).deletingLastPathComponent
        let repositoryGitDir = (admin as NSString).deletingLastPathComponent
        guard (admin as NSString).lastPathComponent == "worktrees",
            (repositoryGitDir as NSString).lastPathComponent == ".git"
        else {
            return fail("Its .git file doesn't point into a repository's .git/worktrees folder.")
        }
        guard (try? System.canonicalPath(gitDir)) == gitDir else {
            return fail("Its repository's worktree record is missing or behind a symlink.")
        }
        guard repositoryGitDir.hasPrefix(home + "/") else {
            return fail("Its repository isn't inside your home folder.")
        }
        guard let backLink = gitdirLine(gitDir + "/gitdir", relativeTo: gitDir), backLink.hasSuffix("/.git")
        else {
            return fail("The repository has no record of this worktree.")
        }
        let listed = String(backLink.dropLast("/.git".count))
        guard listed == path || (try? System.canonicalPath(listed)) == path else {
            return fail("The repository lists a different folder for this worktree.")
        }
        return .success(WorktreeMatch(path: path, gitDir: gitDir))
    }

    /// The path in a `.git` file (`gitdir: <path>`) or a worktree record's
    /// `gitdir` file (`<path>`), made absolute and without `.`/`..`.
    static func gitdirLine(_ file: String, relativeTo base: String) -> String? {
        guard let text = Classifier.readSmallFile(file),
            var line = text.split(whereSeparator: \.isNewline).first.map(String.init)
        else { return nil }
        if line.hasPrefix("gitdir:") { line = String(line.dropFirst("gitdir:".count)) }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return Classifier.normalize(line.hasPrefix("/") ? line : base + "/" + line)
    }
}
