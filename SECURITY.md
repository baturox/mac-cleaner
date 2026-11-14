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
- a protected folder, credential or configuration file being listed or removed,
- a build folder containing git-tracked files being reported,
- a clone with uncommitted, unpushed or otherwise unique work being removed without an explicit override,
- anything that makes the app or CLI run code or commands the user did not ask for: through a repository on
  disk, a file name, a parsed JSON or plist file, or an environment variable.

## Threat model

Treated as hostile input:

- **File names, symlinks and folder contents** anywhere under the home folder (an unpacked archive, a synced
  folder, a cloned repository) and in the world-writable temp areas (`/private/tmp`, `/private/var/tmp`), where
  other local accounts can create entries.
- **Git repositories on disk**, including their `.git/config`, `.gitattributes`, hooks and submodules.
- **Files the scanners parse**: simulator `device.plist`, Ollama manifests, editor `workspace.json`, tool
  version files, Docker's and `simctl`'s output.
- **Environment variables** of the process that starts the app or CLI.

Not defended against (see "Known limitations"): code that is already running as the same user.

## Safety model in brief

**What may be deleted**

- Only inside the home folder (at least two levels down) and the temp areas. A path must be canonical: if
  any folder on the way to it is a symbolic link, the request is refused.
- Removal works on open directory descriptors (`openat`/`fstat`/`unlinkat`, `O_NOFOLLOW` at every step) and
  never re-resolves a path while it runs. Symlinks are unlinked, never followed; the walk stays on one
  volume; an entry that is swapped during the walk is left alone and counted as a failure.
- Permission changes needed to empty a read-only tree are made only on folders inside that tree and are
  undone on any folder that survives. (One exception to "through a descriptor": a folder with no read
  permission at all cannot be opened, so it is made readable with `fchmodat(…, AT_SYMLINK_NOFOLLOW)` relative
  to its open parent, then opened and verified by device and inode.)
- In shared temp areas only entries owned by the current user are listed or removed, and every folder on the
  way to them must be owned by the current user too.
- Protected folders (a built-in list of credential, key and configuration locations plus the user's own list)
  are never listed or touched. They are matched by case-folded, Unicode-normalized path and by file identity
  (device and inode), so another spelling or alias of a protected location does not get past the check.
- The app and the CLI read the same settings file (`~/Library/Application Support/MacCleaner/settings.json`).
  If it is unreadable, the CLI refuses every deleting command.
- Age checks fail closed: if a folder is too large to check completely, or cannot be read, it counts as in use.

**What may be run**

- System tools (`git`, `xcrun`, `tmutil`, `du`, `diskutil`, `sandbox-exec`) are run from `/usr/bin`, `/bin`,
  `/usr/sbin`, `/sbin` only. Third-party tools (`brew`, `docker`, `ollama`, `pnpm`, `uv`, `go`) are searched in
  those directories first, then Homebrew, then folders in the home directory, and a candidate is used only if
  it is a regular file owned by root or the user, not writable by others, in a directory with the same
  properties. Group write access is tolerated for the `admin` group only, because Homebrew's default prefix
  is set up that way and its members can use `sudo` anyway.
- Child processes get a constructed environment (`PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG=C`,
  `LC_ALL=C`). Nothing is inherited: no `DYLD_*`, `GIT_*`, `DOCKER_HOST`, proxy settings.
- Commands are accepted only as exact argv shapes (see `CommandPolicy` in `Sources/CleanerCore/Safety.swift`).
  Identifiers read from disk must match a strict pattern, and a simulator UDID must also equal the name of
  the folder its `device.plist` sits in.
- Docker categories exist only when the selected endpoint is a local unix socket, and every Docker command
  passes that endpoint with `--host`.
- A location named by an environment variable is honored only when its content has the tool's shape; only
  matching entries are offered, never as "safe".

**Git repositories**

A repository's local configuration can make ordinary read-only git commands run programs
(`core.fsmonitor`, `filter.<name>.clean`/`smudge`/`process`, `diff.<name>.textconv`, `core.hooksPath`,
`core.sshCommand`, `core.pager`, aliases, `include.path`, transport helpers in remote URLs, …). Three layers:

1. *Configuration audit.* Before running git in a working copy, every configuration file git would read for
   it (`config` and `config.worktree` of the common directory, `config.worktree` of a linked worktree) is
   listed with `git config --file <f> --no-includes --list`, which parses and prints but executes nothing and
   does not follow includes. Each key must be on an **allowlist** of settings that cannot name a program
   (`GitConfigPolicy` in `Sources/CleanerCore/Git.swift`): for example `core.repositoryformatversion`,
   `core.bare=false`, `core.ignorecase`, `remote.*.url`/`fetch`, `branch.*`, `user.*`, `extensions.worktreeConfig`,
   `submodule.*.url`. `core.fsmonitor` is accepted only as a boolean. Anything else, including every
   `filter.*` (so also Git LFS), `include.*`, `includeIf.*`, `alias.*`, `url.*`, `credential.*` and
   `core.hooksPath`, makes the repository *untrusted*: git is not run in it, it is shown as "not inspected",
   it is never removed, and its build folders are not offered. An allowlist is used, not a denylist, because
   git keeps gaining settings that run things. The cost is that honest repositories with such settings (LFS,
   hook managers that set `core.hooksPath`) are not inspected.
2. *Hardened invocation.* `/usr/bin/git` only; no system or global configuration (`GIT_CONFIG_NOSYSTEM=1`,
   `GIT_CONFIG_GLOBAL=/dev/null`); no prompts; `-c core.fsmonitor=false -c core.hooksPath=/dev/null
   -c core.pager=cat -c protocol.allow=never`; `GIT_NO_LAZY_FETCH=1`; explicit `--git-dir` and `--work-tree`, so
   git cannot discover a different (unaudited) repository in a parent folder; `--ignore-submodules=all`, with
   each submodule audited and inspected as a repository of its own.
3. *Sandbox.* Read-only git runs under `sandbox-exec` with a profile that denies executing anything but git
   itself, all file writes and all network access. `git worktree remove`/`prune` run under the same profile
   without the write restriction. The sandbox is probed once per process; if it cannot be applied (for
   example because the process is itself sandboxed), git runs without it and layers 1 and 2 remain.

**Everything else**

- "Safe" categories are rebuilt or re-downloaded automatically; "caution" categories are real data and are
  never selected by `--safe`, by `--group` alone, or preselected in the app.
- Everything is listed and confirmed before deletion; `--dry-run` shows the plan and changes nothing.
- Working copies are removable only when inspected, committed, pushed to a network remote, without a stash
  and without ignored-only files. An override applies only to the copies the user acknowledged; the CLI
  never overrides.
- Text printed by the CLI has control characters and escape sequences from file names and labels replaced.
- The mock engine and the `MACCLEANER_*` environment hooks used for screenshots exist in debug builds only.
- The app and CLI make no network connections and send no telemetry.

## MCP server (`mac-cleaner mcp`)

**Threat model.** The caller is a language model that may be under prompt injection. File and folder names,
paths, branch names and tool output on the user's disk are attacker-controlled text that the server hands to
that model. The server therefore assumes that any model output (tool name, arguments, the decision to apply a
plan) can be adversarial, and that the model's judgment is not a security boundary.

**What the server will never do**

- Delete anything unless the *user* started it with `--allow-clean`. Without the flag the deleting tools are
  not listed and cannot be called. A corrupt settings file or a turned-off audit log disables them too.
- Accept a path (or any file name) to delete. Plans are built server-side from the engine's own scan results;
  `apply_cleanup` takes only a `plan_id` and `confirm: true`.
- Put a *caution* category, Time Machine snapshots, an item removed by a tool command, a clone or worktree, the
  Trash, an explorer path or a forced removal into a plan. Build folders are planned only for projects idle for
  at least the configured number of days (default 14, at least 1; the model cannot lower it), and are
  re-validated with a fresh project scan right before deleting.
- Apply a plan twice, after it expired (10 minutes), above the per-plan or per-session size ceiling, or more
  than 3 times in 10 minutes. The plan is marked used before anything runs.
- Skip the audit log: every apply is recorded with client `mcp` and the plan id.
- List or measure the protected folders (built-in list and the user's), or inspect anything outside the home
  folder and the temp areas. `explore_folder` resolves symlinks before checking, and omits protected children.
- Return unsanitized file-system text: control characters, line breaks, direction overrides and zero-width
  characters are removed and lengths are capped; text always travels as quoted JSON string values, and the
  server instructions and each relevant tool description say it is data, not instructions.
- Write anything to stdout except protocol messages (logs go to stderr), read an unbounded line (1 MiB limit),
  open a network connection, or run a command that is not on the engine's allowlist.

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

**The audit log** holds paths. It is created 0600 in a 0700 folder under a protected path, never leaves the
machine, and never contains file contents. A program running as the same user can read, edit or delete it
(see "Same-user attackers"): it is an aid for the user, not tamper-proof evidence.

## Known limitations

These are real and not fixed. Please do not report them as new findings, but do tell us if you see a way to
close one.

- **Releases are not notarized.** Unless the release notes say otherwise, builds are ad-hoc signed: macOS
  cannot tell you who built them, and Gatekeeper has to be bypassed on first launch. Notarization needs a paid
  Developer ID and is planned, not done.
- **Checksums without provenance.** `SHA256SUMS` is published next to the downloads by the same workflow, so
  it detects a corrupted download, not a compromised release. There is no signed build attestation yet.
  Workflow actions are pinned to commit SHAs and a release tag must point at a commit on `main`, which
  narrows this but does not replace attestation.
- **The signing-certificate password appears on a command line in the release workflow.** `security import`
  only accepts it as an argument. It is visible in the process list of the single-use build runner for the
  moment the command runs; the temporary keychain and key files are removed afterwards even if the job fails.
- **Same-user attackers.** A program already running as you can replace a user-owned helper (anything in
  Homebrew's prefix or in `~/.cargo/bin`, `~/.bun/bin`, an nvm directory), edit a repository's configuration
  between the audit and the git command, or rewrite the settings file. Mac Cleaner would then run the
  replaced helper with its own privileges, including Full Disk Access if you granted it. The checks above
  keep *other accounts* and *passive data* from doing this; they cannot keep you from yourself. If that
  matters to you, do not grant Full Disk Access, or run only the read-only commands.
- **The ownership check on helpers is a snapshot.** It is made when the tool is looked up, not atomically
  with running it.
- **Trash mode moves by path.** Moving an item to the Trash is done by the system API with the item's path
  after the same checks as a permanent delete; the descriptor-based walk applies to permanent deletion only.
  A race there could at worst move a different item of the same name to the Trash, from where it can be
  restored.
- **`sandbox-exec` is a deprecated Apple tool.** It still works on current macOS and the code falls back
  safely without it, but the third layer of the git defense may disappear with a future macOS release.
- **"Backed up" trusts the local remote-tracking refs.** A commit counts as pushed when a ref under
  `refs/remotes/<network remote>/` contains it. Mac Cleaner does not contact the remote, so a remote branch
  that was deleted or force-pushed since the last fetch is not noticed.
- **Ignored-file detection is name based.** Ignored folders with a known build-output name (`node_modules`,
  `dist`, `build`, …) are assumed rebuildable even if you put something precious in them.
