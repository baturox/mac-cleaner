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

### Notes

- Release builds are ad-hoc signed and not notarized unless the maintainer configures signing secrets.
