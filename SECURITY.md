# Security policy

## Reporting a vulnerability

Please report security problems **privately** through GitHub's
[private vulnerability reporting](https://github.com/baturox/mac-cleaner/security/advisories/new)
("Report a vulnerability" on the Security tab). Do not open a public issue for them.

Include what you found, how to reproduce it and the Mac Cleaner version (`mac-cleaner --version`). You can
expect an acknowledgement within a few days. This is a volunteer project, so there is no guaranteed fix time,
but anything that can delete data it should not is treated as the highest priority.

Supported versions: only the latest release.

## What counts

Mac Cleaner deletes files, so the interesting bugs are the ones that make it delete the wrong thing:

- a path outside the home or temp areas being deleted, or a symlink being followed out of them,
- a protected folder, credential or configuration file being listed or removed,
- a build folder containing git-tracked files being reported,
- a clone with uncommitted or unpushed work being removed without an explicit override,
- anything that makes the app or CLI run code or commands the user did not ask for.

## Safety model in brief

- Only the user's home folder and the temp areas can be deleted from, and nothing shallower than two levels
  below home. Protected folders are never listed or touched.
- "Safe" categories are rebuilt or re-downloaded automatically; "caution" categories are real data and are
  never selected by `--safe`.
- Credentials, tokens and configuration are not cleanup targets.
- Everything is listed and confirmed before deletion; `--dry-run` shows the plan and changes nothing.
- Working copies are removable only when committed and pushed; the CLI never overrides this.
- The app and CLI make no network connections and send no telemetry. They run local tools (`du`, `git`,
  `docker`, `ollama`, `tmutil`, `diskutil`) for what they report.
- Release builds are ad-hoc signed unless the release notes say they are notarized. Verify downloads with
  `SHA256SUMS`.
