# How Midden works

Midden answers one question for every large folder in your home directory: can this go, and what does it cost if it goes? Finding big folders is easy. The hard part is being right about "safe", and being able to show why. Every design choice below follows from that.

## The problem

On the Mac that started this project, the disk was 97% full with 34 GiB free. A manual cleanup brought it to 322 GiB free. The biggest single source was 117 old git worktrees in one repository, 191 GiB in total, made by Claude Code for parallel tasks and never removed. Each one was a full checkout with its own `node_modules`.

Tools that only show sizes would point at that folder. They can't say that none of those 117 worktrees had uncommitted changes and every commit was on a branch, so removing them lost nothing. That check is what the user actually needs, and it is different for every kind of folder.

So the engine has three jobs:

1. Measure every folder correctly and fast.
2. Classify what it finds, with reasons a person can check.
3. Delete only what still qualifies at the moment of deletion.

## 1. Measuring: one parallel pass

### Reading directories in bulk

The cost of a disk scan is system calls, not CPU. The classic approach is `readdir` plus one `lstat` per entry, which is two million calls for a million files.

`DirectoryReader` uses `getattrlistbulk(2)` instead. One call returns a batch of entries with everything the scanner needs: name, type, device, inode, link count, allocated size and modification time. The reader keeps one 128 KB buffer per thread and parses each record by its returned attribute set, because file-only attributes are missing for directories. If a file system doesn't support the call, it falls back to `readdir` plus `fstatat` for that directory only.

On the test Mac (MacBook Pro, M4 Pro, 14 cores) a full scan of the home folder, 4.71 million items and 426 GB, takes about 20 seconds. `du -skx` over the same folder takes 102 seconds. The scan uses 2.3 s of user time and 136 s of system time across threads, so almost all of the work is the kernel reading metadata.

### Walking on a fixed thread pool

Listing a directory blocks. Swift's cooperative thread pool assumes its threads never block, so the walker runs on its own pool of threads instead of one `Task` per directory.

Threads share a stack of directories to visit. Each thread keeps one subdirectory for itself and continues depth first, so it touches the shared lock less often.

A thread sweep over `~/Work` (2.56 million items) picked the pool size:

| Threads | Run 1 | Run 2 |
|---|---|---|
| 1 | 39.3 s | 39.6 s |
| 4 | 11.7 s | 11.2 s |
| 8 | 8.4 s | 9.5 s |
| 12 | 8.7 s | 8.8 s |
| 16 | 9.4 s | 9.5 s |
| 24 | 10.2 s | 10.2 s |

Past 8 to 12 threads the SSD and the kernel are the limit, and more threads only add contention. The default is the core count, clamped between 4 and 12.

### Sizes in a single pass

Every folder needs its total size, but a folder's size is only known after all its subfolders are done. A second pass would double the work.

Instead, each directory node counts its unfinished work: one for its own listing plus one per subdirectory. When a thread brings a node's count to zero, it adds the node's total to its parent and decrements the parent's count. Sizes flow up the tree as soon as each subtree is complete, with atomic counters and no global lock.

### Counting what is really on disk

The numbers must match what the user sees elsewhere, or nothing else Midden says will be trusted.

- **Allocated size, not file length.** Docker's disk image on the test Mac is a sparse file: 1 TB long, 6.1 GB on disk. Midden reports 6.1 GB.
- **Hard links count once.** A folder of release archives had files hard-linked between `1.0.0/` and `latest/`. A set of `(device, inode)` pairs, split across 64 locks, keeps them from being counted twice.
- **No symlinks, no other volumes.** The walker never follows a link and never enters a directory on a different device.
- **No downloads.** Each walker thread turns off materialization of dataless files, so scanning iCloud Drive never downloads anything. `~/Library/CloudStorage` is skipped.

Result: for stable folders the scan matches `du -sk` to the kilobyte (`~/School` 14,188,084 KB, `~/.android` 13,936,164 KB). Over the whole home folder the totals differ by 4,936 KB out of 426 GB. Other programs were writing files between the two runs, which is the likely cause.

## 2. Classifying: rules as data

### Decide on entry, with what is already in hand

A directory is classified when the walker enters it, using only its path, its own listing and a few facts its parent passed down. That costs no extra system calls.

Two small values flow down the tree:

- `Scope`: is this subtree already claimed by a finding, is it inside `~/Library`, is it inside a hidden top-level folder like `~/.vscode`. Nothing inside a claimed subtree is reported on its own, so sizes are never counted twice in the report.
- `ProjectFacts`: which marker files the parent has (`package.json`, `Cargo.toml`, `Podfile` and others, as bit flags) and the newest modification time among its entries.

`target` is a Rust build folder only when a `Cargo.toml` sits next to it. `node_modules` inside `~/.vscode/extensions` is not a build folder at all, because deleting it breaks the extension. The scope rules exist for cases like that.

### The rule catalog

Known locations live in `Rules.swift` as a static array of values: a path pattern relative to home, a category, a safety level, a title, an explanation and an action. Adding a cache that Midden doesn't know yet is one new value and one row in the rule table test. The explanation sits next to the rule, so a reviewer sees what Midden will tell users in the same diff.

### Three safety levels

| Level | Meaning | Selected by "Clean safe items" |
|---|---|---|
| Safe | The owning tool or app recreates it by itself. | Yes |
| Review | Deletable, but it costs something: a rebuild, a large download, or the folder was used in the last few days. | No |
| Info | Explained, never deleted by Midden. Your own files, or data that must be removed inside the app that owns it. | Not deletable |

Large files, Downloads and iPhone backups are always Info. Midden has no way to know if you still need them, so it says so and stops there.

### Worktrees: proof before a verdict

A linked worktree is a directory whose `.git` is a file pointing into `<repo>/.git/worktrees/`. Midden runs five checks and shows each one to the user:

| Check | How | Why it matters |
|---|---|---|
| No uncommitted or untracked files | `git status --porcelain` with `GIT_OPTIONAL_LOCKS=0` | Removing it would lose that work. The env var keeps a read-only scan from rewriting git's index. |
| HEAD is on a branch | `git for-each-ref --contains HEAD` | Branches survive worktree removal. A detached commit on no branch would not. |
| Not locked | `<gitdir>/locked` | Someone asked git to keep it. |
| Not in use | one `lsof -a -d cwd` per scan | A running shell, dev server or agent has its working directory inside. |
| Not used lately | timestamp of the last reflog entry | See below. |

A failed blocking check makes the worktree Info and tells the user what to do about it. Clean but recently used means Review. Otherwise it is Safe.

The last-activity check shows why decisions need evidence. The first idea was the mtime of `logs/HEAD`. On the test Mac six worktrees had that mtime equal to the second, while the last entry inside one of them was six days older. Something had rewritten those files in bulk. The commit date is no better, because a worktree made yesterday from an old branch has an old commit date. The time written on the last reflog line is the moment of the last checkout or commit, so that is what Midden uses, with the mtime only as a fallback.

## 3. Deleting: trust nothing from the scan

A scan can be an hour old when the user presses Clean. In that hour a worktree can get new changes, a cache folder can become a symlink, a project can start a dev server.

So the cleaner takes only ids and works out everything again from zero:

1. The id must be a canonical absolute path inside home: no `.` or `..`, no doubled slashes, not a symlink, and `realpath(id) == id`, which catches a symlink anywhere above it.
2. It walks from home down to the item through the same `Classifier` the scanner uses. The cleaner can't approve anything the scanner wouldn't report today.
3. Worktrees are audited again. Simulators are queried again.
4. If the owning app is running, it refuses and says which app to quit.
5. When a tool has its own removal command, Midden uses it. Worktrees go through `git worktree remove` without `--force`, so git refuses a dirty worktree even if every check above missed something. Simulators go through `xcrun simctl delete`.

Commands run through a small `posix_spawn` and `poll` runner instead of `Process`. It reads stdout and stderr together, so a chatty command can't fill one pipe and deadlock, it kills a command that hangs, and it skips the `/usr/bin/git` stub on Macs without developer tools so no install dialog appears.

## Why Swift only

Rust was the first plan, and C++ came up too. Neither makes the scan faster: the speed comes from `getattrlistbulk` and the thread pool, and both are the same call in any language. What a second language adds is a foreign function boundary, a second toolchain and a second binary to sign. C++ also adds memory-safety risk to a program that deletes files. Swift with strict concurrency checking gives memory and data-race safety, direct access to Darwin APIs, and one package for the engine, the CLI and any Mac front end.

There are no third-party dependencies, including for argument parsing.

## Testing

`swift test` runs 45 tests (91 cases with parameters) against real file systems in temp folders:

- the directory reader against `lstat` for symlinks, sparse files, Unicode names and a directory large enough to need several bulk calls
- scanner totals against `du -sk`, hard links, symlinks
- a 29-row rule table and 19 build-folder cases, including the `~/.vscode` exclusion
- worktree audits on real temporary git repositories: clean, dirty, detached commit, locked, in use by a real child process, bare repositories
- cleaner refusals for paths outside home, symlinks, `..`, unknown folders and manual actions, and real deletion in a fake home

## Known limits

- Between the last check and the delete there is a small window. Nothing locks the folder in between.
- The running-app check matches by bundle id or display name, so it can miss an app whose process name is different.
- Build folders don't check for a dev server running in the project yet.
- The engine needs access to the real home folder, so an app built on it can't be sandboxed.
