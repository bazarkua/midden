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
| Info | Explained, never deleted on Midden's own judgment. Your own files, or data that must be removed inside the app that owns it. | No; your large files can be moved to the Trash by hand |

Large files, Downloads and iPhone backups are always Info. Midden has no way to know if you still need them, so it never picks them for you. When you do choose a large file or an installer, it goes to the Trash rather than being deleted: the one action in Midden you can undo without a backup. `CleanResult.movedToTrash` reports it, and such an item frees nothing until the Trash is emptied.

### Worktrees: proof before a verdict

A linked worktree is a directory whose `.git` is a file pointing into `<repo>/.git/worktrees/`. Midden runs six checks and shows each one to the user:

| Check | How | Why it matters |
|---|---|---|
| No uncommitted or untracked files | `git status --porcelain=v1 -z --untracked-files=all --ignore-submodules=none` with `GIT_OPTIONAL_LOCKS=0` | Removing it would lose that work. The env var keeps a read-only scan from rewriting git's index. Every option is explicit, so a user's `status.showUntrackedFiles=no` can't hide files. |
| No ignored files of your own | the same call with `--ignored=matching` | `git worktree remove` deletes ignored files without asking. Build output and caches are made again; anything else, such as a `.env` or a local database, makes the worktree Review. |
| HEAD is on a branch | `git for-each-ref --contains HEAD` | Branches survive worktree removal. A detached commit on no branch would not. |
| Not locked | `<gitdir>/locked` | Someone asked git to keep it. |
| Not in use | one in-process listing of the user's processes and their working directories (`sysctl` and `proc_pidinfo`) per scan | A running shell, dev server or agent has its working directory inside. |
| Not used lately | timestamp of the last reflog entry | See below. |

A failed blocking check makes the worktree Info and tells the user what to do about it. Clean but recently used, or holding ignored files of the user's, means Review. Otherwise it is Safe.

Git runs without the variables that choose a repository (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and others) in its environment, and with `status.showUntrackedFiles=all` set through `GIT_CONFIG_COUNT`, which outranks every config file. The second one matters for removal: `git worktree remove` checks cleanliness with its own `git status`, and under a user's `status.showUntrackedFiles=no` it removed a worktree holding an untracked file in a test.

### A check that can't run never passes

The first version found working directories with `lsof`. Inside the App Sandbox `lsof` exits with an error, and the engine read its empty output as "no process uses this folder". In a sandboxed test build the check reported "not in use" while a test process had its working directory inside the worktree, and the cleaner approved it.

Two changes came out of that. Process information is now read in-process, which works inside the sandbox and reads all 550 of the user's processes on the test Mac in 8 ms. And every check fails closed: if the process list is incomplete, or the last-activity date is unknown, the check fails with the reason ("Couldn't check running programs") instead of passing silently.

### Worktrees outside home

Coding agents also put worktrees in temporary folders such as `/private/tmp`. Midden reads each repository's `.git/worktrees/*/gitdir` records to find them. A path outside home is accepted only if the link can be proven again from both ends: the folder's `.git` file points into a repository inside home, and that repository's record points back to this exact folder. A forged `.git` file fails the second half.

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

The freed size of each item is measured from the item itself, before and after. Free space on the volume is reported too, but inside the sandbox `statfs` rounds it to steps of 409.6 MB, so it can't be the source of a "Freed" number.

## 4. Never hanging

A scan once ran for 11 minutes on the test Mac. Every walker thread was blocked inside `open()`, waiting for a macOS privacy prompt that nobody answered. One pending prompt can stop a scan forever, so the walker now has two defenses.

Without Full Disk Access, it skips folders that macOS protects. Some macOS refuses outright: Mail, Messages, Safari, Photos libraries. The list comes from measurement: on the test Mac `du` failed on 538 folders, and 329 of the 338 refused app containers belonged to Apple. Others macOS asks about with a permission dialog: Desktop, Documents, Downloads, iCloud Drive, the Music and TV libraries, and every other app's container. A scan that opened those would ask the user a question per folder, so it leaves them alone too. Skipped folders are counted as unreadable and listed in `ScanReport.skippedFolders`, so the report says exactly what it didn't see, and the app can ask once for Full Disk Access instead of a dozen times.

Whether Full Disk Access is granted is probed by listing `~/Library/Safari`, `~/Library/Mail` and `~/.Trash`, which macOS refuses without it, at once and without a prompt. Access counts as granted only when one of them lists and none is refused. On an account where none of them exists the probe proves nothing, and the scan treats that as no access: assuming access there would open Desktop, Documents and Downloads and raise the prompts this list exists to avoid.

For everything else there is a watchdog. Each worker publishes the folder it is listing and bumps a heartbeat after every batch from `getattrlistbulk`, so a huge folder that is still being read keeps beating while a blocked `open()` does not. After 5 seconds without a beat, a supervisor claims the folder with a compare-and-swap, counts it as unreadable, completes its parent's countdown and starts a replacement worker. If the stuck call returns later, its result loses the same compare-and-swap and is dropped. The walk never waits for it.

## 5. Honest progress

A progress bar is only honest if it knows the total, and a scan doesn't know the total until it ends. The estimate works like this:

- Reading folders is 85% of the bar, auditing worktrees 12%, simulators 1% and building the report 2%.
- The reading share follows items seen over the expected items, because items arrive at a steady pace. Bytes seen over the expected bytes can only raise it, and only by 5% of the reading share per second, so one huge file is caught up over a few seconds instead of in one leap. The expected totals come from the previous scan. On a first scan they are the volume's used inodes and used bytes, which are upper bounds, so the bar jumps forward at the end of reading instead of stalling at 99%.
- The worktree phase reports its count as data (`completed` of `total`), and the total stays fixed for the phase.
- The fraction is a running maximum capped at 0.99, so it never goes backwards and never claims to be done early.

One idea that measurement rejected: blending in the ratio of folders finished to folders found, which should approach 1 as the walk ends. In practice a depth-first walk finishes folders almost as fast as it finds them, so the ratio stayed between 0.96 and 0.999 for the whole scan and would have pushed the bar to 99% in the first second.

Time left needs its own care. A single 30 GB file moves the byte ratio from 6% to 35% in one step, so an estimate paced by the bar said "3.5 s left" five seconds into a 27-second scan. Time left is paced by items instead, and the published value is the median of the last 9 raw estimates, allowed to grow by at most 10% (or 1 second) per second but to fall freely. Before this, one real scan showed 78, 10, 199, 19 and 35 seconds in a row. After it, the same Mac counted down steadily from 18 seconds, and the largest single increase was 0.4 seconds. The bar itself now rises by at most 6% in any second of reading, down from a 19% jump.

The worktree phase is harder, because worktrees outside home take far longer to size than the rest. A percentile of finished items' durations said under 2 seconds while 7 to 9 remained, since the quick ones finish first. The phase's own throughput, time spent divided by items done, fits the measured traces better, and the estimate never drops below half of what the slowest running item has taken so far. It is still off by up to 2x on this Mac, which is the honest limit of a count-based estimate for items this uneven.

## 6. The space map

The app draws a treemap of the home folder. The walker already computes every folder's size in one pass, so it also keeps every file and folder of at least 20 MB as it completes, and the tree is built and pruned after the walk: children below 0.05% of the total merge into one "Other" node, with at most 40 children per node and 10 levels.

The floor is measured, not guessed. On the 430 GB test home, 57,108 items were 1 MB or larger, 6,011 were 20 MB or larger, and 2,702 were 50 MB or larger. 20 MB is 0.05% of a 40 GB home, so for any larger home the floor hides nothing the map could draw. The map added about 1% to scan time (27.08 s against 26.81 s, median of 3 runs each) and has 1,473 nodes.

## 7. Inside the App Store sandbox

The Mac App Store requires the App Sandbox. A sandboxed test build showed what breaks:

- `/usr/bin/git` and `xcrun` refuse to run ("cannot be used within an App Sandbox"). Called by its real path inside Xcode or the Command Line Tools, git works on folders the user granted. The engine resolves that path, and without developer tools worktrees become Info with an explanation.
- `xcrun simctl` reported all 12 healthy simulators as unavailable. Trusting that would delete working simulators, so simulator cleanup is off in the sandbox.
- `lsof` is denied, which led to the in-process process listing above.

The engine detects the sandbox by itself, so one engine serves both the App Store edition and the direct download.

## Why Swift only

Rust was the first plan, and C++ came up too. Neither makes the scan faster: the speed comes from `getattrlistbulk` and the thread pool, and both are the same call in any language. What a second language adds is a foreign function boundary, a second toolchain and a second binary to sign. C++ also adds memory-safety risk to a program that deletes files. Swift with strict concurrency checking gives memory and data-race safety, direct access to Darwin APIs, and one package for the engine, the CLI and any Mac front end.

There are no third-party dependencies, including for argument parsing.

## Testing

`swift test` runs 87 tests against real file systems in temp folders. Every git command in the tests runs with the machine's git configuration switched off and git's automatic background maintenance disabled. Without that, a `git commit` in a test sometimes left `git maintenance` running in the worktree for a few milliseconds, and the cleaner correctly refused to remove a worktree a program was working in. A probe measured it: 12 of 80 commits left such a process behind with maintenance on, 0 of 80 with it off.

The tests cover:

- the directory reader against `lstat` for symlinks, sparse files, Unicode names and a directory large enough to need several bulk calls
- scanner totals against `du -sk`, hard links, symlinks
- a 29-row rule table and 19 build-folder cases, including the `~/.vscode` exclusion
- worktree audits on real temporary git repositories: clean, dirty, detached commit, locked, in use by a real child process, bare repositories, worktrees outside home and a forged back-link
- every check failing closed: an incomplete process list, an unknown activity date, an unreadable home
- the watchdog with an injected reader that blocks forever, and one that is slow but alive
- the progress estimate with a fake clock: phases in order, a fraction that never goes backwards
- the space map: sizes add up, pruning rules, hard links counted once
- cleaner refusals for paths outside home, symlinks, `..`, unknown folders and manual actions, and real deletion in a fake home

## Known limits

- Between the last check and the delete there is a small window. Nothing locks the folder in between.
- The running-app check matches by bundle id or display name, so it can miss an app whose process name is different.
- Build folders don't check for a dev server running in the project yet.
- The watchdog is tested with an injected blocking reader. A real privacy prompt could not be triggered on the test Mac.
