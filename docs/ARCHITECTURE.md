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

On the test Mac (MacBook Pro, M4 Pro, 14 cores) a full scan of the home folder, 4.71 million items and 426 GB, takes about 20 seconds. `du -skx` over the same folder takes 102 seconds. Most of the walk's time goes to directory-listing system calls; a breakdown will come from the benchmark harness.

The system call itself is not the difference. Apple's `fts`, which `du` walks with, uses `getattrlistbulk` too: an interposed counter saw it called for every folder of a test tree on macOS 27. Midden's edge comes from listing many folders at once on a bounded pool of threads, and its report does more than add up sizes.

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

- `Scope`: is this subtree already claimed by a finding, is it inside a container (below), is it inside `~/Library`, is it inside a hidden top-level folder like `~/.vscode`. Nothing inside a claimed subtree is reported on its own, so sizes are never counted twice in the report.
- `ProjectFacts`: which marker files the parent has (`package.json`, `Cargo.toml`, `Podfile`, `Package.swift`, Chromium's `Preferences` and others, as bit flags) and the newest modification time among its entries. For a few folders it carries more: which DeviceSupport versions are the newest, and which VS Code extension versions VS Code would delete itself.

`target` is a Rust build folder only when a `Cargo.toml` sits next to it. `node_modules` inside `~/.vscode/extensions` is not a build folder at all, because deleting it breaks the extension. The scope rules exist for cases like that.

### The rule catalog

Known locations live in `Rules.swift` as a static array of values: a path pattern relative to home, a category, a safety level, a title, an explanation and an action. Adding a cache that Midden doesn't know yet is one new value and one row in the rule table test. The explanation sits next to the rule, so a reviewer sees what Midden will tell users in the same diff.

The first matching rule wins. A rule can require something of the folder itself, and when the folder doesn't show it, the next rule applies. A Homebrew downloads folder holding an `.incomplete` file is Review, and without one it's Safe. A folder directly in `~/Library/Caches` or `~/.cache` that has a Chromium `Local State` file is a browser profile, with a warning about sign-ins. The newest DeviceSupport version per platform is Review, and the older ones are Safe. These checks use only the listing in hand, or a small file the folder names (`pyvenv.cfg`, VS Code's `.obsolete`), so classifying still costs no extra walk.

### Unknown caches are Review

`~/Library/Caches` is where macOS asks apps to keep files they can recreate, but nothing enforces it. Poetry keeps every project's virtual environment there, renv a package library its projects link into, Playwright MCP signed-in browser profiles, llama.cpp downloaded models. So a folder in Caches is Review by default, and its explanation says why. Safe is earned per owner, each with a source for why the owner rebuilds the folder:

| Owner | Folder | Why it's rebuilt |
|---|---|---|
| pip | `Library/Caches/pip` | pip's cache directory on macOS, emptied by `pip cache purge` |
| Yarn 1 | `Library/Caches/Yarn` | `getCacheDir` in yarnpkg/yarn's `user-dirs.js`, emptied by `yarn cache clean` |
| Go | `Library/Caches/go-build` | `go help cache`: the build cache, emptied by `go clean -cache` |
| CocoaPods | `Library/Caches/CocoaPods` | `cache_root` in CocoaPods' `config.rb`, emptied by `pod cache clean --all` |
| Poetry | `Library/Caches/pypoetry/cache`, `artifacts` | `repository_cache_directory` and `artifacts_cache_directory` in Poetry's `config.py` |
| pnpm | `Library/Caches/pnpm/metadata*` and `v<number>/metadata*` | pnpm's store docs: `pnpm store prune` removes these metadata folders and keeps the other caches |
| Homebrew | `Library/Caches/Homebrew/downloads` | Packages `brew` downloads again when it needs them |
| Chrome, Brave, Edge, Vivaldi, Arc, Dia | `Library/Caches/<browser>` (`<browser>/User Data` for Arc and Dia) | `GetUserCacheDirectory` in Chromium's `chrome_paths_mac.mm` keeps a profile's disk cache here, apart from the profile |
| Slack, Claude, Obsidian, VS Code, Cursor, Antigravity | `Library/Application Support/<app>/{Cache,Code Cache,GPUCache}`, and `CachedData` for the VS Code family | Chromium's HTTP, script and shader caches, in a folder that still has Chromium's layout. VS Code deletes old `CachedData` itself (`codeCacheCleaner.ts`) |

Spotify's cache folder isn't on the list: most of it is a streaming cache, but it also holds an embedded browser profile, and no Spotify documentation says what the app rebuilds. Without a source it stays Review.

### Containers: a folder that holds something Midden keeps

A rule used to claim its whole subtree, so nothing below it was ever classified. `Library/Caches/*` matched `org.R-project.R` as one Safe cache, the scan never looked inside, and cleaning it deleted renv's package library, which every renv project links into.

Now a folder that a rule matches, and inside which another rule can match, is a container. The scanner keeps descending into it, but only rules apply there: no build folders, installers or worktrees. Folders no rule names stay part of the container. Its own finding is the remainder, its total minus the outermost findings inside it, so the findings inside partition it and nothing is counted twice. The same accounting covers a rule that reports a folder without claiming what's in it, such as Downloads, and file findings too: an installer and a project's `node_modules` in Downloads are left out of Downloads' size, and a file with several names counts once. A container is never removable as a whole. A rule written for one must be Info with a manual action, which a test checks over the whole catalog, and a wildcard that happens to match one (Google's folder in Caches, which holds Chrome's cache) becomes an Info finding that says why. The cleaner classifies the same way, refuses the container, anything inside it that no rule names, and everything above it, and shows the same remainder in its plan.

Containers today: R's cache folder (renv), Poetry's, pnpm's, Homebrew's, Playwright's (browsers and MCP profiles apart), the DeviceSupport folders, and VS Code's extensions folder.

### Three safety levels

| Level | Meaning | Selected by "Clean safe items" |
|---|---|---|
| Safe | The owning tool or app recreates it by itself. | Yes |
| Review | Deletable, but it costs something: a rebuild, a large download, or the folder was used in the last few days. | No |
| Info | Explained, never deleted on Midden's own judgment. Your own files, or data that must be removed inside the app that owns it. | No; your large files can be moved to the Trash by hand |

Large files, Downloads and iPhone backups are always Info. Midden has no way to know if you still need them, so it never picks them for you. When you do choose a large file or an installer, it goes to the Trash rather than being deleted: the one action in Midden you can undo without a backup. `CleanResult.movedToTrash` reports it, and such an item frees nothing until the Trash is emptied.

### Worktrees: proof before a verdict

A linked worktree is a directory whose `.git` is a file pointing into `<repo>/.git/worktrees/`. Midden runs these checks and shows each one to the user, with a fourteenth, no other repository inside, described below the table:

| Check | How | Why it matters |
|---|---|---|
| No uncommitted or untracked files | `git status --porcelain=v1 -z --untracked-files=all --ignore-submodules=none` with `GIT_OPTIONAL_LOCKS=0` | Removing it would lose that work. The env var keeps a read-only scan from rewriting git's index. Every option is explicit, so a user's `status.showUntrackedFiles=no` can't hide files. |
| No ignored files | the same call with `--ignored=matching` | `git worktree remove` deletes ignored files without asking, and a name proves nothing about them: an ignored folder is reported as one entry, and one named `build` or `.build` can hold a dependency checkout with local edits. Any ignored entry makes the worktree Review. A dependency tree or build output beside the project file its tool reads (`node_modules` with its install command from the lockfile, `Pods`, `.next`, `target`, Gradle's `build`) gets one sentence per kind, so worktrees holding only those read the same and the app can offer them together; anything else is listed by name. |
| No changes hidden from git | `git ls-files -s -v -z` | A tracked file marked assume-unchanged or skip-worktree can be edited without `git status` showing it, and `git worktree remove` deletes the edit. Midden can't check such files without changing the user's index, so it doesn't remove the worktree. Skip-worktree files absent from disk (a sparse checkout) are fine. |
| No submodules checked out | gitlinks (mode 160000) from the same listing with a `.git` in the worktree, and the worktree's own `modules` folder | Git refuses to remove a worktree with submodules unless forced, and forcing it deletes the worktree's copy of each submodule's repository, with commits that exist only there. Status then doesn't go into submodules, whose own configuration can define filters. |
| Nothing half done | `rebase-merge`, `rebase-apply`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `sequencer` or a bisect file in the worktree's git folder | Removal throws away the rest of a paused rebase or merge. Only "no such file" counts as absent. |
| Commits are on a branch | a checked-out branch, or for a detached HEAD `git for-each-ref --contains <commit>` | Branches survive worktree removal. A detached commit on no branch would not. |
| No commits only it remembers | the commits in the worktree's `logs/HEAD`, then `git --git-dir=<common dir> rev-list --single-worktree <them> --not --all --reflog <HEAD>`, and no refs in the worktree's own git folder | A commit made on a detached HEAD, after which the worktree switched to a branch, is kept only by the worktree's HEAD reflog. Removal deletes that reflog, and the next `git gc` can delete the commit. Run on the common git folder, `--single-worktree` leaves out every linked worktree's HEAD reflog while branch reflogs still count. |
| Its commits are in origin | `rev-list --count <HEAD> --not <base>`, where the base is the target of `refs/remotes/origin/HEAD` | Being on a branch only keeps the commits on this Mac. The base is never a guessed `main`. origin must not be a folder on this Mac (`insteadOf` rewrites applied), and this Mac must have updated the base within 30 days, by its reflog. Nothing is fetched, so a failure means Midden couldn't establish the work is merged, never that it isn't: squash and rebase merges leave no trace in history. The detail says whether the work was pushed to another branch of origin. |
| Git has its whole history | `rev-parse --is-shallow-repository`, a promisor remote or `extensions.partialClone`, `info/grafts` | The two checks above need history git has and shows as stored. |
| No files go through git filters | `git ls-files -- ':(attr:filter=<name>)'` for each filter the configuration gives a program | A filter changes what git stores, so a clean status doesn't prove the files on disk are what's committed. Git LFS gets its own wording: history holds only pointers. |
| Not locked | `<gitdir>/locked` | Someone asked git to keep it. |
| Not in use | one in-process listing of the user's processes per scan, and again when cleaning: working directory, executable and arguments (`sysctl` and `proc_pidinfo`) | A running shell, dev server or agent has its working directory inside, or a program working elsewhere runs from it or names a file in it (`tail -f <worktree>/log`). git's own file watcher doesn't count: the cleaner stops it. |
| Not used lately | timestamp of the last reflog entry | See below. |

A build folder or worktree is deleted whole, its ignored files included, so the walk that sizes it also looks for `.git`, `.hg`, `.svn` and `pyvenv.cfg` inside it, one name comparison per entry, and the cleaner's own walk looks again. Another repository makes it Info: a clone with commits that exist nowhere else can sit in `node_modules`, or in an ignored folder that `git status` reports as one entry. A package checkout SwiftPM or Xcode made, a Python environment, or a folder the walk couldn't read makes it Review at most. What SwiftPM's selective clean keeps doesn't count.

A failed blocking check (uncommitted, hidden changes, submodules, half done, on a branch, commits only it remembers, another repository inside, locked, in use) makes the worktree Info and tells the user what to do about it. Otherwise, if anything is ignored, the commits aren't in origin, the history or filters stop the check, or it was used recently, it is Review. Otherwise it is Safe.

Git runs without the variables that choose a repository (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and others) in its environment, and with settings given through `GIT_CONFIG_COUNT`, which outranks every config file. `status.showUntrackedFiles=all` matters for removal: `git worktree remove` checks cleanliness with its own `git status`, and under a user's `status.showUntrackedFiles=no` it removed a worktree holding an untracked file in a test. No git command Midden runs contacts another machine (`GIT_ALLOW_PROTOCOL` empty, which outranks a repository's `protocol.<name>.allow`, and `GIT_NO_LAZY_FETCH=1`), reads replacement objects, or collects garbage. And none runs a program from the repository's configuration: a clean filter is one, and `git status` runs it on a tracked file whose timestamp changed, so every filter the worktree's configuration names gets an empty command, for the audit and for the removal. The configuration is read in each worktree, because a conditional include can differ per worktree.

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

Some folders may be emptied only in part, so the public action stays `removeContents` and the rule carries an engine-internal contents policy. The cleaner takes the policy from the rule it matches when cleaning, never from the scan. For `~/Library/Logs`, only regular files with one link, on the home folder's disk and modified at least 7 days ago are deleted. Every folder stays with its inode, mode, owner and ACL, because macOS doesn't recreate some of them: after another cleaner removed `DiagnosticReports`, crash reports couldn't be saved. For a SwiftPM `.build`, everything goes except what `swift package clean` keeps: `repositories`, `checkouts`, `artifacts` and `workspace-state.json`. Both work through descriptors. The folder is opened from home one component at a time with `O_NOFOLLOW`, everything below relative to its parent, nothing on another device is entered, and each Logs file is checked again with `fstatat` right before `unlinkat`. They go at most 128 levels deep, one descriptor per level; a deeper folder, or one that fails to open (out of descriptors included), is left alone and the result says so. The result reports the bytes actually removed.

What a policy would delete is measured from the listings the scan's walk makes anyway, under its watchdog, thread admission and cancellation, so nothing is listed twice and cancelling still works while a folder in Logs blocks. The measure counts the folders the walk should list and those it did: one given up, failing to open or listed only partly makes it incomplete, and the finding then gets a failed "measured" check and isn't Safe. Before cleaning, the cleaner measures again with a walk of the same kind, under the walker's watchdog.

Some rules also need that no program uses the folder: pnpm's `dlx` packages, Playwright's browsers and profiles, Homebrew's downloads, browsers' offline site data, SwiftPM build products, old VS Code extensions, and Gradle's caches and distributions. For Gradle the check is wider: any process whose arguments name a Gradle main class (daemon, wrapper, launcher or worker), or that uses anything in `~/.gradle`, keeps them. After the scan and again when cleaning, Midden reads every process of the user in-process: working directory, executable path and arguments. A process that runs from the folder, works in it, or names it in an argument (`--user-data-dir=<profile>`, `curl --output <download>`, `sh <script in a cache>`) makes the finding Info with "Quit ... first". Relative arguments, and flag values after `=`, are read as paths from the process's working directory. A listing that couldn't read every process makes it Info too: a read that fails is tried twice more, a process that is exiting is skipped, and an argument record that is cut off or has an impossible count is unknown, not shorter. A passing check says what was observed: "No use found in process paths or arguments." A folder's age isn't used as evidence that nothing uses it. On the test Mac this reads 553 processes in about 0.02 s.

Commands run through a small `posix_spawn` and `poll` runner instead of `Process`. It reads stdout and stderr together, so a chatty command can't fill one pipe and deadlock, it kills a command that hangs, and it skips the `/usr/bin/git` stub on Macs without developer tools so no install dialog appears. A timed-out command is killed with its whole process group. One that still hasn't exited 2 seconds later, or whose exit status can't be read (except ECHILD, which means it isn't ours), keeps a slot from a budget of 32, reserved before every command starts, until a reaper on one serial queue has reaped it (on its exit notification and on rechecks that back off from 10 ms to 1 s, since the notification can come before the child can be reaped); while the budget is used up, commands wait for a slot up to their own deadline and then fail without starting.

The freed size of each item is measured from the item itself, before and after. Free space on the volume is reported too, but inside the sandbox `statfs` rounds it to steps of 409.6 MB, so it can't be the source of a "Freed" number.

## 4. Never hanging

A scan once ran for 11 minutes on the test Mac. Every walker thread was blocked inside `open()`, waiting for a macOS privacy prompt that nobody answered. One pending prompt can stop a scan forever, so the walker now has two defenses.

Without Full Disk Access, it skips folders that macOS protects. Some macOS refuses outright: Mail, Messages, Safari, Photos libraries. The list comes from measurement: on the test Mac `du` failed on 538 folders, and 329 of the 338 refused app containers belonged to Apple. Others macOS asks about with a permission dialog: Desktop, Documents, Downloads, iCloud Drive, the Music and TV libraries, and every other app's container. A scan that opened those would ask the user a question per folder, so it leaves them alone too. Skipped folders are counted as unreadable and listed in `ScanReport.skippedFolders`, so the report says exactly what it didn't see, and the app can ask once for Full Disk Access instead of a dozen times.

Whether Full Disk Access is granted is probed by listing `~/Library/Safari`, `~/Library/Mail` and `~/.Trash` in the account's real home (from the user database, not the sandbox container), whatever folder is being scanned. macOS refuses them without it, at once and without a prompt. Access counts as granted only when one of them lists and none is refused. On an account where none of them exists the probe proves nothing, and the scan treats that as no access: assuming access there would open Desktop, Documents and Downloads and raise the prompts this list exists to avoid.

Protected folders are recognized by where they are in that home, not relative to where a scan starts: `midden scan --home ~/Code/tree` scans that tree's own `Documents` folder like any other. A scan that starts inside a protected folder without Full Disk Access doesn't open it and reports it unreadable.

For everything else there is a watchdog. Each worker publishes the folder it is listing and bumps a heartbeat after every batch from `getattrlistbulk`, so a huge folder that is still being read keeps beating while a blocked `open()` does not. After 5 seconds without a beat, a supervisor claims the folder with a compare-and-swap, counts it as unreadable, completes its parent's countdown and starts a replacement worker. If the stuck call returns later, its result loses the same compare-and-swap and is dropped. The walk never waits for it.

A stuck thread can't be killed, so walker threads are bounded across every walk in the process: each takes a slot from a shared budget before it starts and gives it back only when it really exits, which for a stuck thread is when its call returns. With every slot held by stuck threads, a new walk doesn't start and reports its root unreadable. A folder whose listing is still stuck from an earlier scan is counted as stalled instead of being tried again, and the listing's record is settled under one lock, so a call that returns while being given up never stays registered. The Full Disk Access probe, which has its own deadline, can leave at most two threads behind.

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

`swift test` runs 282 tests against real file systems in temp folders, and never raises a permission prompt. Two slow stress tests (a 5,000-level chain, a folder of 200,000 entries) run only with `MIDDEN_STRESS=1`. Three tests that attach real disk images run only with `MIDDEN_MOUNT_TESTS=1`: macOS treats a mounted image as a removable volume, so the terminal needs access to removable volumes (Privacy & Security, Files and Folders), and without it macOS asks; by default the mount guard is covered with an injected mount table instead. Older revisions, from `b7963d5` up to the one before `6e6a9be` ("Run the disk-image mount tests only on request"), attach real disk images on every run, and `MIDDEN_MOUNT_TESTS` can't turn that off there: to test one of them unattended, for example while bisecting, skip those tests by name with `swift test --skip "refusesAFolderWithADiskMountedInside|refusesAMountAttachedThroughAnotherSpelling"`. The CLI test is skipped if the built `midden` binary is older than the sources. All the others pass, and eight cleaner race cases among them pass by recording known issues (see Known limits): they turn into failures once those races are closed. Every git command in the tests runs with the machine's git configuration switched off and git's automatic background maintenance disabled. Without that, a `git commit` in a test sometimes left `git maintenance` running in the worktree for a few milliseconds, and the cleaner correctly refused to remove a worktree a program was working in. A probe measured it: 12 of 80 commits left such a process behind with maintenance on, 0 of 80 with it off.

The tests cover:

- the directory reader against `lstat` for symlinks, sparse files, Unicode names and a directory large enough to need several bulk calls
- scanner totals against `du -sk`, hard links, symlinks
- a 64-row rule table and 19 build-folder cases, including the `~/.vscode` exclusion
- protected folders end to end: scan, plan and clean a fake home, and renv's library, Poetry's environments, pnpm's `dlx`, llama.cpp's models and Playwright MCP's profiles survive cleaning everything above them, while the findings inside a container partition its size
- the Review default for unknown caches and every known Safe owner, Electron caches only with the owner's Chromium layout (and Cookies, Login Data, IndexedDB and Local Storage kept), Homebrew's api and bootsnap kept
- Logs: old and recent, future-dated and zero-dated files, hard links, symlinks to folders outside home, a folder's inode, mode and ACL kept, unreadable folders and undeletable files, a listing that stops partway, files changed between listing and delete, symlinks swapped in at every stage, and a disk mounted inside after the last check
- "not in use" checks with real processes (a script run from a cache with its working directory elsewhere, a browser started on a profile, a download being written) and with an incomplete process listing
- DeviceSupport versions: numeric order, builds, ties, unreadable names, an incomplete listing and versions changing after the scan
- Gradle's caches kept while a Gradle daemon or build runs, and a library installed with `mvn install` kept when every Safe item is cleaned
- measuring Logs and `.build` within the scan's walk: each folder listed once, incomplete listings shown, a blocked listing cancelled promptly with no thread left behind, and the cleaner's measure giving up a stalled listing; deletion walks stopping at their depth limit and on a failed open
- SwiftPM `.build` cleaned like `swift package clean`, Python environments by `pyvenv.cfg` (also when named like a build folder), VS Code's obsolete-extension predicate, browsers' offline site data per profile, and the `hf cache` commands against a versioned help fixture
- worktree audits on real temporary git repositories: clean, dirty, detached commit, locked, in use by a real child process, bare repositories, worktrees outside home and a forged back-link
- the cases of a safety audit that decide whether a worktree can lose work: a commit only its HEAD reflog keeps (still reachable after the refused clean), refs of its own, commits reset away on its branch, work never pushed or pushed but not merged, no remote, an origin on this Mac written four ways, an unknown or stale origin/HEAD, a shallow clone, a bisect in progress, a filter program that neither the audit nor the removal runs, a required filter, and a fetch that git refuses
- every check failing closed: an incomplete process list, an unknown activity date, an unreadable home
- the watchdog with an injected reader that blocks forever, and one that is slow but alive
- the progress estimate with a fake clock: phases in order, a fraction that never goes backwards
- the space map: sizes add up, pruning rules, hard links counted once
- cleaner refusals for paths outside home, symlinks, `..`, unknown folders and manual actions, and real deletion in a fake home
- walk totals against `du -skx` and `find -x` on random trees from fixed seeds (sparse files, hard links, symlink loops, NFC and NFD names, names with newlines, 20,000 entries in one folder), paths longer than PATH_MAX, and walks while files, folders and permissions change
- the reader with injected failures: EINTR, ENOMEM, errors before and after a batch, entries with errors or missing attributes, malformed records, readdir errors
- the watchdog's bounds: stuck threads capped across repeated scans, late returns dropped, cancellation within a tick, no descriptors left open after failures
- git checks that the user's configuration and inherited environment can't fool, ignored files of the user's, dirty submodules, an index left untouched
- cleaner races at four stages of cleaning, and disks mounted inside a folder to clean: an injected mount table by default, real disk images on request

## Known limits

- Between the last check and the delete there is a window of a few system calls. Right before acting, the cleaner checks the path again (no symlink at or above it, the same kind of object, no disk mounted inside), which closed the long window during the size walk and the audit. `CleanerRaceTests` changes the file system at four stages of cleaning (before the path is opened, before it's classified, after validation, right before the delete) and checks that each change really happened. These still win, and are recorded as known issues:
  - at the last stage: an ancestor swapped for a symlink, the folder of `removeContents` swapped for one, the item replaced by a file, and the folder of an installer swapped before it's moved to the (test's stand-in) Trash;
  - after validation and at the last stage: the item replaced by another folder of the same name (nothing compares identity), and an ignored file appearing in a worktree after its audit (`git worktree remove` deletes it without asking).

  The remaining tested cases pass at every stage they're run at: a target or child swapped for a symlink, a file turned into a hard link, new work in a worktree.

  The fix for files Midden deletes itself is a delete through descriptors instead of paths. Open each component from home with `openat(O_NOFOLLOW | O_DIRECTORY)`, check device and inode with `fstat` against what validation recorded, and delete with `unlinkat` relative to the descriptors held, never by path again. A short-lived approval record would carry the identity, the rule, the action and the safety level the user approved from plan to clean, and the cleaner would refuse when any of them changed or the safety got worse. Git and simctl removals can't work that way: they stay delegated to their tools, which take a path, so the best Midden can do there is a last identity check right before the command, and a window remains between that check and the tool's own work.
- Paths longer than PATH_MAX (1024 bytes): the scan walks them, opening each one in pieces relative to the previous descriptor; that is tested to 5,000 levels. Splitting the path doesn't add symlink protection beyond what one `open()` had: only the last component of each piece is opened with `O_NOFOLLOW`. The cleaner doesn't support such paths: it checks and deletes by path, and nothing in it has been tested past PATH_MAX.
- The running-app check matches by bundle id or display name, so it can miss an app whose process name is different.
- Build folders don't check for a dev server running in the project yet, except SwiftPM's `.build`, which gets the "not in use" check.
- Build folders other than SwiftPM's `.build` are Review until each kind has evidence that nothing else is kept in it.
- "Its commits are in origin" is what git on this Mac recorded at the last fetch. A worktree whose branch was squash-merged stays Review. Only origin counts, and only the branch origin/HEAD names.
- The "not in use" check sees what a process names, runs from or works in. A program that holds a file open without naming it, or one that starts between the check and the delete, isn't seen.
- VS Code profiles are read from `extensions.json` in the extensions folder, in `User` and in `User/profiles/*`. The profiles folder layout comes from VS Code's source and wasn't seen on the test Mac, which has no extra profiles.
- The watchdog is tested with an injected blocking reader. A real privacy prompt could not be triggered on the test Mac.
