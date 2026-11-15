# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-11-15

### Added

- An **Apps** screen (sidebar item after Repos, shortcut ⌘5; Explore and History move to ⌘6 and ⌘7) listing installed apps with bundle size, the data they keep in your Library, last opened (Spotlight), and running / App Store / Homebrew / system badges. Sortable, with filters (not opened in 90+ days, 1 GB+, text). The detail panel lists exact-match data by class (cache, settings, data), "possibly related" folders (never ticked) and shared group containers (never removed), with *Clear Caches…* and *Remove App…*. The scan runs at launch with the others and is part of the remembered last scan.
- *Remove App* moves the bundle to the Trash whatever the delete mode (leftovers follow it). It refuses a running app, Apple apps, Mac Cleaner itself, apps in protected folders, root-owned apps (remove them in Finder) and Homebrew apps (use `brew uninstall --cask`). Identity and bundle id are checked again right before the move. This is the only way anything in `/Applications` is ever moved; the general deleter still refuses it.
- `mac-cleaner apps` (list with `--json`, `--unused`, `--sort`; `apps <bundle-id>`, `--clear-caches`, `--remove [--with-data]`, `-n`, `-y`, `--trash`) and the read-only MCP tool `list_apps`. No MCP tool removes an app.
- Audit records of kind `removeApp` and `clearAppCaches`; the log stays readable by this version, older versions cannot decode these two records. The remembered scan file gained an optional `apps` part.

### Changed

- The app scans everything at launch: caches, Projects and Repos start together and share one folder walk, instead of Projects and Repos waiting until their screen is opened. A section you stopped is not restarted by itself, and nothing starts while a clean is running.
- The last finished scan is kept in `~/Library/Application Support/MacCleaner/last-scan.json` (readable by you only) and shown at once at launch, marked "Results from 12 minutes ago · refreshing…", until the fresh scan replaces it. Selections survive the swap for rows that are still there. It is display state only; deletions still re-check everything on disk. Copies on the Repos screen cannot be removed while their rows are remembered or incomplete. Snapshots older than 7 days, unreadable or of another format are ignored; lists are cut at 5,000 rows; *Clear history…* removes the file; the rows a clean removes are removed from it too.
- The Overview shows one status line for the whole scan ("Scanning: caches ✓ · projects… · repos 54 of 131").
- The Repos scan inspects the biggest copies first and shows each copy as soon as it is inspected. Every copy is still inspected from scratch on every scan; "fully backed up" is not remembered between scans.

## [0.1.4] - 2026-11-15

### Changed

- Deleting is faster: up to 4 threads share the work, across the selected items and inside big folders (their first and second level), so one huge `node_modules` is parallel too. Every thread uses the same descriptor-based, no-follow removal and the same checks as before. Moving to the Trash is still one rename per item, one after another.
- Nothing is measured before deleting any more. The `du` pass that walked every tree a second time for the audit record is gone; entries and allocated bytes (a file with several hard links once) are counted while removing and written to the result and to the audit record.
- Cleaning shows a progress bar with items done, entries removed, bytes freed, elapsed time and the item being deleted, instead of a bare "Please keep the app open". The CLI prints the same on stderr when it is a terminal.
- A clean or delete stops running scans and no scan starts until it ends. Afterwards the deleted rows are removed from the lists and the disk numbers refreshed, without scanning everything again; the rescan buttons do a full rescan.

### Added

- A Stop button on the cleaning overlay. Stopping takes about a second; what was already removed stays removed. Quitting the app during a clean asks, stops it and writes its outcome before quitting.
- Audit records of a stopped operation are marked `cancelled` and shown as "stopped" in History and `mac-cleaner history`, not as interrupted. Finished records have optional `entriesRemoved` and `bytesRemoved` fields (and `entriesRemoved` per item); the file stays readable by older versions.

## [0.1.3] - 2026-11-14

### Changed

- Projects and Repos scans are much lighter on the machine. They share one walk of the home folder (kept for about 10 minutes, dropped by any deletion, a rescan or a change of protected folders) instead of walking it twice, look at most 8 levels deep, and no longer enter package-like folders (`.app`, `.framework`, photo and music libraries, virtual machines, ...) or folders with more than 5,000 entries.
- The walk compares paths against a precomputed protected list instead of resolving every path, reads up to 4 folders at a time at low priority, and runs at most 3 `du` or `git` processes at once.
- Progress names the folder being searched, with running counts (`Searching Desktop/work/api… 1,240 folders, 37 found`).
- The app starts the Projects and Repos scans when their screens are first opened (or a rescan is pressed), not at launch.
- Measured sizes are remembered in `scan-cache.json` next to `settings.json` and reused while the build folder and its project are unchanged (7 days at most). The cache only holds numbers for display; the list of folders always comes from a real walk, and a project's idle time is always read from disk.
- The Repos screen remembers each working copy's total size for up to a day while the working copy folder and its git folder are unchanged, and measures the rest in batches.
- The idle check of a project stops as soon as it sees a change from the last day (the answer is already "today"), and only runs for projects that are listed.

## [0.1.2] - 2026-11-14

### Changed

- Release builds are now signed with a Developer ID and notarized by Apple, so macOS opens the app and the
  `mac-cleaner` command without a Gatekeeper warning.
- Mac Cleaner can be installed with Homebrew: `brew install --cask baturox/tap/mac-cleaner`.

## [0.1.0] - 2026-11-14

First public release.

### Added

- macOS app (macOS 14+, universal) with Overview, Cleanup, Projects, Repos and Explore screens.
- Real disk numbers: free space right now next to Finder's "available" (free plus purgeable).
- Grouped cleanup, each category marked safe or caution: System & apps, Package managers, Xcode & mobile,
  AI coding tools (Claude Code, Cursor, Windsurf, VS Code, Codex, Gemini CLI session data, orphaned workspace
  storage, old extension versions, Playwright browsers), AI models (Hugging Face, Ollama, LM Studio, picked
  per model with last-used dates), Language toolchains (old Node/Rust/Python versions, Android SDK pieces),
  Containers & VMs (Docker breakdown) and Personal data.
- Projects: stale build folders (`node_modules`, `target`, `.next`, `Pods`, `.venv`, ...) across all projects
  with idle time. A build folder inside a git repository is reported only when git lists no tracked file in it.
- Repos: every clone and worktree grouped by repository with "clean & pushed" status, so leftover agent
  worktrees can be removed safely.
- Explore: drill down by size.
- "What grew" since the last scan.
- Menu bar item with a low-space warning.
- Delete permanently or move to the Trash; protected folders; deletion limited to the home and temp areas.
- Command-line tool `mac-cleaner` with `scan`, `clean`, `projects`, `repos`, `explore`, `growth` and `doctor`;
  `--json` output with a versioned schema on every read command, `--no-color`, `--dry-run`, confirmation
  prompts, exit codes 0/1/2/130.
- Build and packaging scripts: universal app bundle, DMG, ZIP, CLI tarball, checksums, optional Developer ID
  signing and notarization; generated app icon; Homebrew cask template.
- GitHub Actions for CI and tagged releases.

- **History / audit log.** Unless turned off, every clean, delete and clone removal is recorded in
  `~/Library/Application Support/MacCleaner/audit.jsonl` (append-only JSON Lines, mode 0600 in a 0700 folder,
  `flock` + `fsync`, rotated at ~10 MB, corrupt lines skipped): a "started" record before anything is deleted
  and a "finished" record afterwards, so an interrupted operation is visible with the items it intended to
  remove. New *History* screen in the app (search, client and date filters,
  items with Reveal in Finder, JSON/CSV export, clear), "Freed so far" on the Overview, `mac-cleaner history`
  and `mac-cleaner history clear`, and a setting to turn recording off. New engine API: `auditLog`, `auditStats`,
  `clearAuditLog`, `AuditRecord`/`AuditItem`, `LiveEngine(client:appVersion:)` and
  `delete(urls:mode:purpose:progress:)`.
- **MCP server for AI agents.** `mac-cleaner mcp` (MCP 2026-07-28, with `initialize`-based negotiation down to
  2024-11-05): read-only tools for disk status, cleanup categories, build folders, repositories, folder sizes,
  growth and the audit history. With `--allow-clean` the user can opt in to a two-step `plan_cleanup` /
  `apply_cleanup` limited to safe categories (including five fixed package-manager cache-prune commands) and
  idle projects' build folders, with expiring single-use plans, size ceilings, a rate limit, and a refusal to
  delete when the audit log cannot be written. See the README and SECURITY.md.
- `mac-cleaner doctor` mentions the MCP command.

### Security

Hardening after a security review, before the first release. Details and the remaining limitations are in
[SECURITY.md](SECURITY.md).

- **Scanning no longer runs code from a repository's git configuration.** A repository's own `.git/config` is
  audited against an allowlist of harmless settings before git is run in it. A repository with any other
  setting (`core.fsmonitor`, content filters including Git LFS, `core.hooksPath`, aliases, includes, …) is
  shown as "untrusted git config - not inspected", is never removed, and its build folders are not offered.
  git is run as `/usr/bin/git` only, without global or system configuration, with monitors, hooks, pagers and
  transports switched off, with an explicit `--git-dir`, and under `sandbox-exec` where available.
- **Deletion cannot be redirected by symlinks or races.** Removal is done through directory descriptors and
  never follows or re-resolves a path; paths that reach their target through a symlink are refused; a folder
  swapped for a link during the walk is left alone. Permission changes are limited to folders inside the tree
  being removed and are undone on folders that survive.
- **Shared temp folders.** Only entries owned by the user are listed or removed there, never through a
  symlink. The idle check now treats "too big to check" and "unreadable" as in use, and the temp category
  judges age by the newest change at any depth and skips sockets and FIFOs.
- **Protected folders** are also matched by file identity and case-folded name (`~/Library/keychains` no
  longer gets past `~/Library/Keychains`).
- **The CLI now obeys the protected folders and retention set in the app** (shared
  `~/Library/Application Support/MacCleaner/settings.json`). New `--protect <path>` flag; `doctor` shows the
  list in force; with an unreadable settings file every deleting command refuses to run.
- **"Fully backed up" is stricter.** Unpushed now includes commits on a detached `HEAD` and on tags; a
  detached linked worktree needs its `HEAD` on a remote; a remote that is a local path or `file://` URL is
  not a backup; ignored files that are not build output (`.env`, local data) are counted and block removal
  (`ignoredFileCount`, shown as "N ignored-only"). In the app, an override now applies only to the copies it
  was given for, not to the whole batch.
- **Environment variables can no longer turn arbitrary folders into cleanup items.** A cache location from
  an environment variable is used only if its content has the tool's shape, only matching entries are
  offered, and never as "safe".
- **Helper programs** are resolved from system directories first (system tools from there only), must pass
  ownership and permission checks, and get a constructed environment instead of the inherited one.
- **Commands** are accepted only as exact argv shapes; simulator UDIDs, runtime identifiers and Ollama model
  names are validated before use. Docker categories appear only for a local daemon and name it explicitly.
- CLI output replaces control characters and escape sequences found in file names and labels.
- The mock engine and the `MACCLEANER_*` screenshot hooks are compiled out of release builds.
- Release workflow: actions pinned to commit SHAs; signing material is removed even when the job fails.
  `scripts/install-cli.sh`, when used as root or into a folder owned by another account, copies instead of
  linking and does not run the binary (for your own folders it links by default; `--copy` copies).

Fixes after a second, pre-release verification pass. Each has a regression test; SECURITY.md now carries a
numbered list of the safety properties with the tests behind them.

- **Git layout files are parsed exactly like git parses them.** A linked worktree whose `commondir` ended in
  a space made Mac Cleaner audit one configuration file while git read another. `.git` files, `commondir` and
  `gitdir` with surrounding whitespace, control characters, invalid UTF-8 or a target that is not a directory
  now make the repository untrusted, and git is asked to confirm the layout after the audit.
- **Git-tracked build folders are no longer offered when the scan starts inside a repository.**
  `mac-cleaner projects app/ios` (and the app's and MCP server's scan roots) now find the repository above the
  folder and check its tracked files.
- **"Fully backed up" no longer trusts files hidden from `git status`.** Tracked files on disk that are
  flagged skip-worktree or assume-unchanged count as "cannot verify" (`hiddenFromStatusCount`, shown as
  "N files hidden from git status"); `core.ignoreStat` is no longer on the allowlist. A stash check that fails,
  and submodules nested deeper than the engine follows, also count against a copy.
- **The audit log is written before the deletion,** not only after it (see *Added*). On Ctrl-C the CLI lets a
  running deletion stop and record its outcome. The MCP server checks that the log can be written before an
  apply, reports the real result (`audit_logged`), and records an apply in which everything was skipped.
- **`CFFIXED_USER_HOME` (and `HOME`) can no longer relocate the home folder.** It comes from the user
  database; if the process was given a different one, every deleting operation refuses. `TMPDIR` does not
  move the temp root.
- **Linked worktrees are removed by the engine's own descriptor walk,** not by `git worktree remove`; only
  `git worktree prune` runs afterwards, and not in a protected or untrusted main repository. The nested-
  repository check applies to worktrees too.
- **Git config allowlist is per key.** `gc.recentObjectsHook`, `pull.twohead`, `init.templateDir` and the
  rest of the previously whole-section entries that could name programs are no longer accepted.
- **Idle time** is the newest change anywhere in the project (bounded, failing closed), not just at its top
  level; a project edited in `src/deep/` is no longer "idle for months".
- **Protected paths that are not absolute** are rejected (settings file invalid, deleting refused) instead of
  being ignored. **Trash mode** looks through the tree for protected items, other volumes and foreign folders
  before moving it. The settings/history folder is 0700 whichever file is written first.
- **MCP read tools** list and accept `~/Documents`, `~/Library` and the other top-level folders (they were
  hidden by mistake); only credential locations and your protected folders are hidden. `project_root` must be
  inside the home folder. The session ceiling counts removed bytes. Simulator devices for removed runtimes and
  Time Machine local snapshots are now *caution* and can never be part of an agent's plan.
- **App:** before a forced clone removal is confirmed, and again right before it runs, the copy is inspected
  afresh; the sheet shows current losses (including nested repositories), and a copy that changed is kept.
- **Release workflow:** a build-and-test job without secrets and a publish job that alone can sign, behind
  the GitHub Environment `release` (the maintainer must restrict it to `v*` tags with a required reviewer);
  releases are created as drafts; CI builds must be universal or fail; release notes state exactly how the
  build was signed. `install-cli.sh` resolves `--from`, and as root never creates folders in, or installs
  into, a normal account's folders.

### Changed

- "Editor data of deleted projects" (contains editor chat history) and the Maven local repository are now
  *caution*. Poetry's virtual environments are a separate *caution* category; only its cache is *safe*.
- `.wrangler` is no longer treated as a build folder; `.terraform` only when git ignores it.
- `clean --group X` without `--safe`/`--all` selects only the safe categories of that group. The plan printed
  by `clean` lists the items of each category (first 8, then a count), also with `-y`.
- Cache folders reached through a symbolic link are no longer listed.
- The confirmation sheet states the total number of files and folders behind the rows it shows.

### Notes

- Release builds are ad-hoc signed and not notarized unless the maintainer configures signing secrets; the
  release notes say which of the three cases (notarized, signed only, ad-hoc) a build is.
- New and changed engine API: `CleanResult.auditRecorded`, `RepoClone.hiddenFromStatusCount`,
  `AuditRecord.phase`/`isUnfinished`, `AuditOutcome.pending`, `AuditStats.unfinishedOperations`,
  `CleanerEngine.auditLogProblem()` and `inspectClones(_:)`, `PathAccess.isHidden`/`containsHidden`,
  `EngineSettings.invalidProtectedPaths`, `AccountEnvironment`, `AuditActivity`.
