# Security policy

## Reporting a vulnerability

Please report security problems **privately** through GitHub's
[private vulnerability reporting](https://github.com/baturox/mac-cleaner/security/advisories/new)
("Report a vulnerability" on the Security tab). Do not open a public issue for them.

Include what you found, how to reproduce it and the Mac Cleaner version (`mac-cleaner --version`). You can
expect an acknowledgement within a few days. This is a volunteer project, so there is no guaranteed fix time,
but anything that can delete data it should not, or run something the user did not ask for, is treated as the
highest priority.

Supported versions: only the latest release.

## What counts

Mac Cleaner runs as you, is usually granted Full Disk Access, and deletes irreversibly. The interesting bugs
are the ones that make it delete the wrong thing or run the wrong thing:

- a path outside the home or temp areas being deleted, or a symlink being followed out of them,
- a protected folder, credential or configuration file being removed, or a hidden one being listed,
- a build folder being offered although git lists tracked files in it,
- a clone with uncommitted, unpushed or otherwise unique work being removed without an explicit override,
- anything that makes the app or CLI run code or commands the user did not ask for: through a repository on
  disk, a file name, a parsed JSON or plist file, or an environment variable,
- any statement in this file, the README or a tool description that is stronger than what the code does.

## Threat model

Treated as hostile input:

- **File names, symlinks and folder contents** anywhere under the home folder (an unpacked archive, a synced
  folder, a cloned repository) and in the world-writable temp areas (`/private/tmp`, `/private/var/tmp`), where
  other local accounts can create entries.
- **Git repositories on disk**, including their `.git/config`, `.gitattributes`, hooks, submodules, and the
  small files that say where a repository lives (`.git` as a file, `commondir`, `gitdir`).
- **Files the scanners parse**: simulator `device.plist`, Ollama manifests, editor `workspace.json`, tool
  version files, Docker's and `simctl`'s output.
- **Environment variables** of the process that starts the app or CLI, as far as listed under property 19.
- **Everything the updater receives**: the release description, the release notes, the checksum file, the downloaded archive and the app inside it, and the network path to GitHub (see "Updater").

Not defended against (see "Known limitations"): code that is already running as the same user.

## Safety properties

This is the checklist a review should go through. Each property names the code that implements it and the
tests that would notice if it broke. "Refused" always means: nothing is changed and the reason is reported.

**What may be deleted**

1. **Allowed area.** A path is deleted only if it lies in the home folder at least two levels down, at least
   two levels below the per-user temp root, directly inside `/private/tmp`, inside a `/private/tmp/claude-*`
   scratch folder, or is Bazel's per-user output root. (`Deleter.isAllowed`; `DeleterTests`.)
2. **Canonical paths only.** The path must be absolute, without `.` or `..`, and no folder on the way to it may
   be a symbolic link; otherwise it is refused rather than followed. (`Deleter.isAllowed`;
   `FileSafetyTests.testNonCanonicalPathsAreRefusedRatherThanRedirected`.)
3. **Permanent deletion works on descriptors.** The parent is opened from `/` one component at a time with
   `O_NOFOLLOW`; everything below is done with `openat`/`fstat`/`unlinkat` relative to open directory
   descriptors, and a path string is not resolved again while it runs. Symlinks are unlinked, never followed.
   A folder that is swapped for a link or for another folder between the look and the open is left alone and
   counted as a failure. The walk does not descend into another volume. (`Deleter.Walk`;
   `FileSafetyTests`: the race test, the deterministic mid-walk swap, the disk-image volume test.)
   **Exception, Trash mode:** the move to the Trash is done by the system with the item's path, as one piece.
   Before it, the same allow-rule and identity checks run and the tree is walked read-only by descriptor; a
   protected item, another volume, a foreign-owned folder or an unreadable folder inside it makes the move
   refuse. The move itself is not descriptor-based (see "Known limitations").
4. **Modes.** Permission changes needed to empty a read-only tree are made only on folders inside that tree
   and are undone on any folder that survives. A folder with no read permission cannot be opened, so it is
   made readable with `fchmodat(…, AT_SYMLINK_NOFOLLOW)` relative to its open parent, then opened and verified
   by device and inode. (`FileSafetyTests.testFailedRemovalLeavesFolderModesUnchanged` and neighbours.)
5. **Shared temp areas.** Below the temp roots only entries owned by the current user are listed or removed,
   every folder on the way to them must be owned by the user too, and a folder owned by someone else inside
   a tree the user owns is not entered. (`SafeGlob`, `Deleter`; `FileSafetyTests`,
   `ReviewFixTests.testForeignOwnedFolderInsideAUserOwnedTree…`.)
6. **Protected locations are never deleted.** Two kinds:
   - *Hidden subtrees*: a built-in list of credential, key and configuration locations (`doctor --json`
     prints it) plus the user's own protected folders. They are never listed, never offered, never walked
     into by a scan, and never deleted.
   - *The user's own top-level folders* (`~/Documents`, `~/Desktop`, `~/Downloads`, `~/Library`, `~/Pictures`,
     `~/Movies`, `~/Music`, `~/Applications`, `~/Public`): never deleted themselves. They are **not** hidden:
     scans look into them and their sizes are measured.

   Both are matched by case-folded, Unicode-normalized path and by file identity (device and inode), so another
   spelling or alias of a protected location is recognized, also when it turns up inside a tree that is being
   removed. A folder that *contains* a protected location is not deleted either. (`PathGuard`;
   `DeleterTests`, `FileSafetyTests.testProtectedPaths…`.)
7. **A protected path that cannot be honored is an error, not a no-op.** A protected path in the settings that
   is not absolute makes the settings file invalid; while one is configured the engine refuses every deleting
   operation. (`--protect` on the command line resolves a relative path against the current folder.)
   (`SettingsStore.load`, `LiveEngine.begin`; `ReviewFixTests.testProtectedPathThatIsNotAbsolute…`.)
8. **One settings file.** The app and the CLI read `~/Library/Application Support/MacCleaner/settings.json`.
   If it is unreadable or invalid, the CLI and the MCP server refuse every deleting command.
9. **Age checks fail closed.** A temp folder too large to check completely, or unreadable, counts as in use. A
   project's idle time is the newest change anywhere inside it except its build folders and `.git/objects`;
   a project with more than 100,000 entries, or one that cannot be read, counts as touched today.
   (`hasActivity`, `ProjectWalker.lastTouched`; `ProjectTests.testIdleDays…`.)

**What may be run**

10. **Where programs come from.** System tools (`git`, `xcrun`, `tmutil`, `du`, `diskutil`, `sandbox-exec`) are
    run from `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin` only. Third-party tools (`brew`, `docker`, `ollama`,
    `pnpm`, `uv`, `go`) are searched in those directories first, then Homebrew, then folders in the home
    directory, and a candidate is used only if it is a regular file owned by root or the user, not writable by
    others, in a directory with the same properties. Group write access is tolerated for the `admin` group
    only, because Homebrew's default prefix is set up that way and its members can use `sudo` anyway.
11. **Constructed environment for children.** Child processes get `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`,
    `LANG=C`, `LC_ALL=C` (git: plus the variables that switch configuration, prompts and pagers off). Nothing
    is inherited: no `DYLD_*`, `GIT_*`, `DOCKER_HOST`, proxy settings.
    (`ChildEnvironment`, `Git.environment`; `GitSecurityTests.testInheritedGitEnvironmentIsNotPassedOn`.)
12. **Exact commands only.** Commands are accepted only as exact argv shapes (`CommandPolicy` in
    `Sources/CleanerCore/Safety.swift`). Identifiers read from disk must match a strict pattern, and a
    simulator UDID must also equal the name of the folder its `device.plist` sits in.
13. **Docker means the local daemon.** Docker categories exist only when the selected endpoint is a local unix
    socket, and every Docker command passes that endpoint with `--host`.

**Git repositories**

A repository's local configuration can make ordinary read-only git commands run programs
(`core.fsmonitor`, `filter.<name>.clean`/`smudge`/`process`, `diff.<name>.textconv`, `core.hooksPath`,
`core.sshCommand`, `core.pager`, aliases, `include.path`, transport helpers in remote URLs, …).

14. **Layout is read exactly like git reads it, or the repository is untrusted.** Where a working copy keeps
    its git data is decided by small files (`.git` as a file, `<gitdir>/commondir`, `<gitdir>/gitdir`). They are
    parsed with git's own rules (only trailing CR and LF are stripped; a relative path is relative to the
    file's folder). The repository is untrusted when one of them has leading or trailing whitespace, a control
    character, invalid UTF-8, is a symlink, or does not lead to an existing directory. As a second opinion,
    after the audit git itself is asked (`rev-parse --git-common-dir --absolute-git-dir`, hardened) and any
    disagreement makes the repository untrusted. That command reads the configuration but starts nothing it
    names. (`GitLayout`, `Git.open`; `GitLayoutTests`, including the proof for `rev-parse`.)
15. **Configuration audit.** Before git is run in a working copy, the repository's own configuration files
    (`config` and `config.worktree` of the common directory, `config.worktree` of a linked worktree) are listed
    with `git config --file <f> --no-includes --list`, which parses and prints but executes nothing. Each key
    must be on an **allowlist** of settings that cannot name a program (`GitConfigPolicy` in
    `Sources/CleanerCore/Git.swift`). Sections are allowlisted key by key; a whole section is allowed only
    when none of its documented keys names a program (`branch`, `user`, `color`, `column`, `advice`). So
    `gc.auto` is fine and `gc.recentObjectsHook` is not. `core.fsmonitor` is accepted only as a boolean.
    Anything else, including every `filter.*` (so also Git LFS), `include.*`, `includeIf.*`, `alias.*`,
    `url.*`, `credential.*`, `core.hooksPath` and `core.ignoreStat`, makes the repository *untrusted*: git is
    not run in it, it is shown as "not inspected", it is never removed, and its build folders are not offered.
    What the audit does **not** read: files pulled in by `include.path` (not needed: the key itself makes the
    repository untrusted), the system and global configuration (switched off, see 16), `.gitattributes` and
    `.gitmodules` (they only select filters and URLs that the configuration would have to define).
16. **Hardened invocation.** `/usr/bin/git` only; no system or global configuration (`GIT_CONFIG_NOSYSTEM=1`,
    `GIT_CONFIG_GLOBAL=/dev/null`); no prompts; `--no-pager -c core.fsmonitor=false -c core.hooksPath=/dev/null
    -c core.pager=cat -c protocol.allow=never`; `GIT_NO_LAZY_FETCH=1`; explicit `--git-dir` and `--work-tree`,
    so git cannot discover a different (unaudited) repository in a parent folder; `--ignore-submodules=all`,
    with each submodule audited and inspected as a repository of its own.
    (`GitSecurityTests.testHardenedInvocationStops…`: each override against its own exploit.)
17. **Sandbox.** Read-only git runs under `sandbox-exec` with a profile that denies executing anything but git
    itself, all file writes and all network access. `git worktree prune` runs under the same profile without
    the write restriction. The sandbox is probed once per process; if it cannot be applied (for example
    because the process is itself sandboxed), git runs without it and 14 to 16 remain.
18. **Build folders and git.** A build folder that lies inside a git repository, whether the repository's root
    is at, below or **above** the folder the scan started in, is offered only when git, asked in that
    repository, lists no tracked file in it (and, for generic names such as `dist` or `build`, says it is
    ignored). If the repository is untrusted or git fails or times out, the folder is not offered. A folder in
    no repository at all is offered by name and marker file only. Limits: this is git's view at scan time; a
    file added to the index afterwards is noticed only by the next scan (the MCP server scans again right
    before deleting). (`ProjectWalker`, `GitArtifactFilter`; `ProjectTests`.)

**The process environment**

19. **Variables that are defended against.**
    - `HOME` and `CFFIXED_USER_HOME`: the home folder is taken from the user database entry of the real user
      id. If the home folder the process was given differs from it, scanning works on the real home and every
      deleting operation refuses. (`EngineEnvironment.live`; `ReviewFixTests`, `ProcessTests`.)
    - `TMPDIR`: the temp root is the system's per-user temp folder (`_CS_DARWIN_USER_TEMP_DIR`).
    - `DYLD_*`, `GIT_*`, `DOCKER_HOST`, proxy variables, `PATH`: not passed to any child (see 11).
    - Cache-location variables (`PLAYWRIGHT_BROWSERS_PATH`, `PUPPETEER_CACHE_DIR`, `UV_CACHE_DIR`,
      `COMPOSER_HOME`, `TF_PLUGIN_CACHE_DIR`, `CCACHE_DIR`, `HF_HOME`, `OLLAMA_MODELS`, `PYENV_ROOT`, `NVM_DIR`
      and the other location variables the scanners read): honored only when the folder's content has the
      tool's shape; only matching entries are offered, never as "safe".
    - `DOCKER_HOST` and `DOCKER_CONTEXT` do not choose the daemon: they are not passed on, the endpoint is the
      current context of Docker's own configuration, and only a local unix socket is accepted (see 13).

    Not defended against: variables that change the process before its own code runs (for example `DYLD_*`
    on a build without the hardened runtime, i.e. every ad-hoc signed build). Whoever sets those is running
    code as you (see "Same-user attackers").

**Clones and worktrees**

20. **Removable only when nothing exists only there.** Without an override a working copy is removed only
    when, right before the removal, it was inspected and has: nothing uncommitted; no tracked file on disk
    that is flagged skip-worktree or assume-unchanged (git status is silent about those, so they count as
    "cannot verify"); nothing unpushed to a *network* remote; no stash (a stash check that fails counts as a
    stash); no ignored files that are not known build output; no submodule that holds work, cannot be
    inspected, or is nested deeper than three levels; no linked worktrees depending on it; and no nested
    repository with unsaved work. Any git command that fails or times out counts against the copy.
    **Override:** in the app the user can acknowledge the loss of one specific copy; that copy is then removed
    with what it holds. The losses shown are read from disk when the confirmation opens, and a forced removal
    goes ahead only if a second inspection right before it finds exactly the same. The CLI and the MCP server
    never override. A copy with untrusted git configuration is refused even with an override.
    (`RepoInspector`, `removeClones`; `RepoTests`, `ReviewFixTests`.)
21. **Linked worktrees are removed like any other folder,** by the descriptor walk of property 3, not by git.
    Afterwards `git worktree prune` (hardened) runs in the main repository, unless that repository is
    protected or untrusted; then nothing is changed there and the result tells the user to run it.

**Records**

22. **The audit log.** Every deleting operation writes a "started" record (the items it is about to handle),
    fsynced, **before** it deletes anything, and a "finished" record with the outcome afterwards. Readers pair
    them; an operation without its second record is shown as "interrupted - outcome unknown" with its intended
    items. On Ctrl-C the CLI stops the deletion at the next entry and waits (bounded) for the outcome record.
    What this does not promise: if the log cannot be written, the app and the CLI still delete and say so in
    the result (`auditRecorded` is false); if the user turned the log off, nothing is recorded; a process that
    is killed leaves only the "started" record. The MCP server is stricter, see 27.
    (`LiveEngine.begin`/`finish`, `AuditStore`; `ReviewFixTests`, `AuditTests`.)
23. **The data folder** `~/Library/Application Support/MacCleaner` (settings, growth history, audit log) is
    created with mode 0700, or set to 0700 the next time any of the three files is written; the files are
    0600. It is on the built-in protected list, so the tool cannot delete its own log.

**Everything else**

24. "Safe" categories are caches and build output that the tools that made them create again when they are
    needed (at the cost of time and, often, a download). "Caution" categories are real data, or things nothing
    rebuilds (the Trash, backups, models, chat history, simulator devices, Time Machine local snapshots); they
    are never selected by `--safe`, by `--group` alone, or preselected in the app.
25. Everything is listed and confirmed before deletion; `--dry-run` shows the plan and changes nothing. Text
    printed by the CLI has control characters and escape sequences from file names and labels replaced. The
    mock engine and the `MACCLEANER_*` environment hooks used for screenshots exist in debug builds only. The
    app and CLI send no telemetry; the only network use is the update check and install (see "Updater"), plus
    whatever macOS itself asks Apple while Gatekeeper assesses a downloaded update.

## MCP server (`mac-cleaner mcp`)

**Threat model.** The caller is a language model that may be under prompt injection. File and folder names,
paths, branch names and tool output on the user's disk are attacker-controlled text that the server hands to
that model. The server therefore assumes that any model output (tool name, arguments, the decision to apply a
plan) can be adversarial, and that the model's judgment is not a security boundary.

**Properties** (continuing the list; tests in `Tests/CLITests/MCP*Tests.swift` and `ProcessTests.swift`)

26. **Off unless the user turned it on.** Without `--allow-clean` the deleting tools are not listed and cannot
    be called. A corrupt settings file, a turned-off audit log, or a relocated home folder disables them too.
27. **Nothing is deleted without a log entry.** Before an apply uses its plan, the server checks that the
    audit log can be appended to and refuses otherwise (the plan stays valid). The engine, when driven by the
    MCP server, does not start deleting if the "started" record could not be written. The result's
    `audit_logged` is what the engine reported, not a constant. An apply in which every item was skipped is
    recorded as an operation with the plan id and no items.
28. **No path to delete is ever accepted.** `apply_cleanup` takes only a `plan_id` and `confirm: true`. Plans
    are built server-side from the engine's own scan results. The one folder a caller names for a deleting
    tool is `project_root` of `plan_cleanup`: it must resolve (symlinks followed first) to a folder inside the
    home folder that is not a hidden location, and it only narrows where the project scan looks for build
    folders; it is never deleted itself.
29. **What a plan can contain.** Only: (a) path items of categories marked *safe*; (b) these fixed
    category-wide commands, when the category that carries them is *safe*: `brew cleanup -s --prune=all`,
    `pnpm store prune`, `go clean -modcache`, `uv cache prune`, `docker --host <local unix socket> builder
    prune -af`; (c) build folders of projects idle for at least the configured number of days (default 14, at
    least 1; the model cannot lower it). Never: a *caution* category, Time Machine snapshots, simulator devices
    or runtimes (nothing that runs `xcrun simctl delete …`), an item removed by its own tool command
    (`ollama rm …`), a clone or worktree, the Trash, an explorer path, a forced removal. Everything is scanned
    again right before deleting; what changed is skipped and reported.
30. **Limits.** A plan runs once (concurrent applies of one plan: exactly one runs), expires after 10 minutes,
    is capped at 10 GB by default, and at most 3 applies run per 10 minutes. One server process removes at
    most 30 GB by default; that ceiling counts what was actually removed.
31. **Hidden locations stay hidden.** The read tools refuse a hidden location (property 6) as their folder
    and leave hidden entries out of listings; nothing outside the home folder and the temp areas can be
    inspected; symlinks are resolved before these checks. The user's own top-level folders are listed and can
    be explored. **The size of a folder is measured as a whole, so it includes any protected folder inside
    it**; such entries are marked `size_includes_protected_data`.
32. **File-system text is inert.** Control characters, line breaks, direction overrides and zero-width
    characters are removed and lengths are capped; text travels only as quoted JSON string values, and the
    server instructions and each relevant tool description say it is data, not instructions.
33. **Protocol hygiene.** Nothing but protocol messages is written to stdout (logs go to stderr); a line
    longer than 1 MiB is rejected; no network connection is opened; no command outside property 12 is run.

**Residual risks (not fixed)**

- A user who approves a plan without reading it deletes what is in it. The plan is limited to rebuildable
  data, but rebuilding can cost time (and bandwidth).
- A "safe" cache category can still hold something a particular tool did not expect to lose; that is the
  same risk as the app's *safe* level.
- `growth_report` writes a snapshot to Mac Cleaner's own history file; it is the only write besides the audit
  log and plan state kept in memory.
- Plans and rate limits live in the server process. Restarting the server resets the session ceiling and the
  rate limit; whoever can restart it with different flags is the user, or a program already running as the user.
- The 2026-07-28 client `_meta` fields other than the protocol version are accepted but not required, and the
  server answers every request statelessly under that revision.

**The audit log** holds paths. It never leaves the machine and never contains file contents. A program
running as the same user can read, edit or delete it (see "Same-user attackers"): it is an aid for the user,
not tamper-proof evidence.

## Updater

The app can replace itself with a newer release (`Sources/CleanerCore/Updates/`). This is the one place where
Mac Cleaner downloads and runs code, so it is built to need no trust in the network.

**What is trusted.** Only constants compiled into the app: the repository (`baturox/mac-cleaner`), the Apple Team
ID (`35MD9KJ7ZQ`), the bundle identifier, the asset name pattern and the size caps. Nothing is read from the
network or from the download to decide what to accept. The release JSON only says which version is newest and
where its files are.

**Checks, in order** (all must pass; any failure discards the download and leaves the installed app untouched):

1. The running app must itself satisfy the Developer ID requirement (a development, ad-hoc or unsigned build
   never updates itself, so it cannot be tricked into replacing itself).
2. Strict semantic version comparison: the offered version must be strictly greater than the running one; drafts,
   prereleases and malformed tags are ignored.
3. Transport: HTTPS only, default system trust evaluation, no cookies or credentials, generic `User-Agent`.
   Requests start at `api.github.com` or `github.com`; redirects are followed only to GitHub's own hosts and its
   release-asset hosts (`objects.githubusercontent.com`, `release-assets.githubusercontent.com`,
   `github-releases.githubusercontent.com`), at most five, never from HTTPS to anything else. The asset URL must
   equal `https://github.com/baturox/mac-cleaner/releases/download/<tag>/MacCleaner-<version>.zip` exactly.
4. The download is capped (120 MB) while it streams and must match the size the release lists; the archive's
   declared expanded size is capped (400 MB); it must contain exactly one app bundle with the expected name.
5. SHA-256 equals the entry in the release's `SHA256SUMS`.
6. Signature: `SecStaticCodeCheckValidityWithErrors` with all-architectures, nested-code and strict validation,
   and symbolic links restricted to the bundle (`kSecCSRestrictSymlinks`, as `codesign --verify --strict` does),
   against `anchor apple generic and identifier "<bundle id>" and certificate leaf[subject.OU] = "<team>" and
   certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]`;
   then bundle identifier and `CFBundleShortVersionString` must match (id: ours; version: the advertised one).
7. Gatekeeper: `spctl --assess --type execute` must accept it and report `source=Notarized Developer ID`.

**No gap between checking and using.** The archive is unpacked into a private folder (`mkdtemp`, mode 0700,
a sibling of the installed app so the final step is a rename on one volume). The bundle is moved to `new.app`
there and verified **at that path**; the same directory is then swapped with the installed app in one atomic
`renamex_np(RENAME_SWAP)` (two renames with rollback where the volume lacks it). The signature is checked once
more right before the swap and again on the installed path right after it; a failure swaps the old app back.
Nothing is copied between verification and use, and nothing is launched before it passed.

**Where it works.** Only for an app in a folder the user can write to: not from a disk image, a read-only
volume, an App Translocation path, a symlink, a folder the user cannot change or an app bundle that belongs to
another user (moving a folder needs write access to the folder itself). Then it refuses and offers a
manual download. It never asks for administrator rights and has no privileged helper.

**Relaunch and rollback.** After the swap the old app sits in the private folder as a backup. A detached
`/bin/sh` helper is started with fixed positional arguments (nothing is interpolated into the script): it waits
for the old process to exit, opens the new app, and if the new app has not written its acknowledgement within
about a minute, moves the failed app aside, puts the backup back and opens it (if the backup cannot be moved
back, the new app is returned to its place: the installed path is never left empty). The new app deletes the backup
(and the record `pending-update.json`) a few seconds after it started. Only folders named `.MacCleaner-update-*`
that sit next to the app, are real directories (not links) and belong to the user are ever deleted. When a swap or
a way back fails half way (a rename refused by the file system), the staging folder may hold the only copy of the
previous app: it is then marked (`KEEP-previous-app-inside`), never deleted automatically, and the error names the
path of the previous app.

**Quarantine.** Files fetched by the app carry no quarantine flag and the updater never removes one from
anything. The new app is launched only after the checks above, including the Gatekeeper assessment.

**No deletion without a stop.** An update never installs or relaunches while a clean or delete runs (or while the
confirmation for one is open); it waits. Once the swap may start, new cleans are refused until the app quits.

**What is recorded.** Update attempts (from version, to version, result) go to `updates.jsonl` next to the audit
log, mode 0600, last 200 entries. No identifier is sent anywhere and nothing is collected.

**Residual risks (not fixed):**

- A process running as the same user can modify the staged bundle between verification and the swap, or the
  installed app at any time. The re-verification right before the swap and the verification of the installed path
  right after it narrow the first window; they cannot close it (the same attacker could simply edit the app).
- A compromise of the GitHub account or of the signing identity is not detected: the checksum file is published
  next to the download, so it protects against corruption and a tampering CDN, not against the publisher. The
  signature and notarization checks bind the release to the Developer ID key, not to a particular build.
- Revocation: Gatekeeper's assessment may consult Apple's revocation data; the Security framework check itself
  does not require network access, so a certificate revoked very recently may be accepted while offline.
- A downgrade or replay by an attacker who controls the network is refused (strictly newer only, TLS, host
  allowlist), but a user-visible "no update" can be forced by blocking GitHub (a denial of service, not a
  compromise).
- If the app is quit while an update is being downloaded, its private staging folder (a few MB) can remain; it is
  removed at a later launch once it is a day old.
- The rollback helper decides by a missing acknowledgement file. A new version that starts but takes longer than a
  minute to run its first lines would be rolled back although it works; the old version is then simply back.
- The release notes are untrusted text shown as plain text; only `https://github.com` links are clickable.

## Release process

- The release workflow has two jobs. The first has `contents: read` and no secrets: it builds, tests and
  produces the universal app. The second, `publish`, is the only one with `contents: write` and the only one
  that can read the signing and notarization secrets; it compiles and tests nothing, signs the built app,
  packages it and creates the release as a **draft**.
- The secrets belong in the GitHub Environment **`release`**, which the `publish` job references. **The
  maintainer must configure that environment** (Settings > Environments > release): deployment tags limited
  to `v*`, and a required reviewer. This is what decides which commits can be signed. The step in the
  workflow that checks "the tag is on `main`" is a convenience only: it is part of the tagged commit itself.
  These settings cannot be made from the repository's files; if they are missing, the environment protects
  nothing.
- Workflow actions are pinned to commit SHAs; checkouts do not keep credentials.

## Known limitations

These are real and not fixed. Please do not report them as new findings, but do tell us if you see a way to
close one.

- **Releases may not be notarized.** The release notes say which of three things a build is: signed with a
  Developer ID and notarized; signed with a Developer ID but not notarized; or ad-hoc signed (macOS cannot
  tell who built it). Unless they say "notarized", Gatekeeper has to be bypassed on first launch.
- **Checksums without provenance.** `SHA256SUMS` is published next to the downloads by the same workflow, so
  it detects a corrupted download, not a compromised release. There is no signed build attestation yet. The
  in-app updater adds the Developer ID signature and notarization checks on top (see "Updater").
- **Secrets on command lines in the release workflow.** `security` only accepts passwords as arguments. The
  certificate password (`security import -P`) and the temporary keychain's random password
  (`create-keychain`, `unlock-keychain`, `set-key-partition-list`) are visible in the process list of the
  single-use runner for the moment each command runs; the temporary keychain and key files are removed
  afterwards even if the job fails.
- **Same-user attackers.** A program already running as you can replace a user-owned helper (anything in
  Homebrew's prefix or in `~/.cargo/bin`, `~/.bun/bin`, an nvm directory), edit a repository's configuration
  or layout files between the audit and the git command, rewrite the settings file, or set `DYLD_*` for an
  unhardened build. Mac Cleaner would then run the replaced helper with its own privileges, including Full
  Disk Access if you granted it. The checks above keep *other accounts* and *passive data* from doing this;
  they cannot keep you from yourself. If that matters to you, do not grant Full Disk Access, or run only the
  read-only commands.
- **The ownership check on helpers is a snapshot.** It is made when the tool is looked up, not atomically
  with running it.
- **Trash mode moves by path.** The move is done by the system API with the item's path after the checks of
  property 3. Between the read-only walk and the move a same-user or same-folder race could put something
  else under that name; it would be moved to the Trash, from where it can be restored.
- **The audit is a snapshot too.** A repository's configuration is read, then git is run; the sandbox and the
  command-line overrides are what stands between a change in that window and a program being run.
- **`sandbox-exec` is a deprecated Apple tool.** It still works on current macOS and the code falls back
  safely without it, but the third layer of the git defense may disappear with a future macOS release.
- **"Backed up" trusts the local remote-tracking refs.** A commit counts as pushed when a ref under
  `refs/remotes/<network remote>/` contains it. Mac Cleaner does not contact the remote, so a remote branch
  that was deleted or force-pushed since the last fetch is not noticed.
- **Ignored-file detection is name based.** Ignored folders with a known build-output name (`node_modules`,
  `dist`, `build`, …) are assumed rebuildable even if you put something precious in them. The same holds for
  a folder with such a name that is in no git repository at all.
- **Sparse checkouts and index flags.** A tracked file that is on disk and flagged skip-worktree or
  assume-unchanged makes its clone "not backed up" even if it is unchanged: git offers no cheap way to verify
  it, so the tool does not guess.
- **A relocated home folder in an app sandbox.** The check of property 19 compares the account's home with the
  one the process reports. A sandboxed build would report its container and refuse every deletion; Mac
  Cleaner is not sandboxed, and is not meant to be.
