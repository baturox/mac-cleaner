## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `swift build` and `swift test` pass locally, with no new warnings
- [ ] Tests are hermetic (temporary folders and fakes only, nothing outside the test sandbox)
- [ ] For a new cleanup category: paths verified against the tool's documentation, only rebuildable data is marked `safe`, and nothing touches credentials or configuration (see CONTRIBUTING.md)
- [ ] I did not change `Sources/CleanerCore/Models.swift` (the shared contract), or I explained why above
- [ ] User-visible changes are listed in `CHANGELOG.md`
- [ ] README or `--help` text updated if behavior changed
