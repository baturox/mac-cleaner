# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

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
  with idle time. Build folders containing git-tracked files are never reported.
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

- **History / audit log.** Every clean, delete and clone removal is recorded in
  `~/Library/Application Support/MacCleaner/audit.jsonl` (append-only JSON Lines, mode 0600, `flock` + `fsync`,
  rotated at ~10 MB, corrupt lines skipped). New *History* screen in the app (search, client and date filters,
  items with Reveal in Finder, JSON/CSV export, clear), "Freed so far" on the Overview, `mac-cleaner history`
  and `mac-cleaner history clear`, and a setting to turn recording off. New engine API: `auditLog`, `auditStats`,
  `clearAuditLog`, `AuditRecord`/`AuditItem`, `LiveEngine(client:appVersion:)` and
  `delete(urls:mode:purpose:progress:)`.
- **MCP server for AI agents.** `mac-cleaner mcp` (MCP 2026-07-28, with `initialize`-based negotiation down to
  2024-11-05): read-only tools for disk status, cleanup categories, build folders, repositories, folder sizes,
  growth and the audit history. With `--allow-clean` the user can opt in to a two-step `plan_cleanup` /
  `apply_cleanup` limited to safe categories and idle projects' build folders, with expiring single-use plans,
  size ceilings, a rate limit and audit records. See the README and SECURITY.md.
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
- Release workflow: actions pinned to commit SHAs, the tag must point at a commit on `main`, signing material
  is removed even when the job fails. `scripts/install-cli.sh` copies (never links) and does not run the
  binary when used as root.

### Changed

- "Editor data of deleted projects" (contains editor chat history) and the Maven local repository are now
  *caution*. Poetry's virtual environments are a separate *caution* category; only its cache is *safe*.
- `.wrangler` is no longer treated as a build folder; `.terraform` only when git ignores it.
- `clean --group X` without `--safe`/`--all` selects only the safe categories of that group. The plan printed
  by `clean` lists the items of each category (first 8, then a count), also with `-y`.
- Cache folders reached through a symbolic link are no longer listed.
- The confirmation sheet states the total number of files and folders behind the rows it shows.

### Notes

- Release builds are ad-hoc signed and not notarized unless the maintainer configures signing secrets.
