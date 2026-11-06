# Engine verification

Run on macOS with Xcode Command Line Tools:

```sh
./Tests/run-engine-tests.sh
```

Latest engine result (2026-11-07): **21/21 test groups passed** on macOS 27.2 / arm64. The baseline before this audit passed 16/16 groups. Tests create disposable fixtures next to this README and remove them when each group finishes. They do not read, copy, execute, install or modify real plug-ins, `/Library`, or the current user's plug-in directories.

Covered behaviors:

- Export → verify → restore, preserving the original source and restoring into a separate user home.
- Relative internal symlinks, executable mode, custom extended attributes and resource forks survive the copy.
- Existing directories and files are skipped without overwriting or merging.
- Every selected entry is verified before destination writes; a modified later entry aborts the whole preflight.
- Explicit item selection; unknown IDs and empty selections fail.
- Invalid paths, traversal, NULs, scopes, IDs, duplicate/overlapping targets and format versions fail.
- Escaping, absolute and payload-root symlinks fail; partial exports are removed.
- Existing destination symlinks, dangling symlinks and ancestor symlinks block installation.
- A failing destination produces a partial-result report while independent valid entries complete.
- Export destinations inside the source are rejected, including redirection through an ancestor symlink.

Scope of integrity checking: SHA-256 covers relative paths, types, file lengths, regular-file contents and link targets. It does not cover permission/owner metadata, ACLs, extended attributes or resource forks. The separate copy tests verify that the fixture's mode, custom xattr and resource fork survived; they do not extend the digest's guarantees. ACLs are intentionally excluded by the copy utility's `--noacl` option.

Not exercised: real plug-in execution, DAW validation, licensing, a second Mac, network/removable filesystems, privileged restore or adversarial concurrent changes to source/archive/destination paths.

## Audit checks (2026-11-07)

```sh
./Tests/run-engine-tests.sh
./Tests/run-preset-tests.sh
./Tests/run-cli-tests.sh
./Tests/run-app-tests.sh
./Tests/run-coverage.sh
```

The AppKit suite requires a GUI login session and injects an empty inventory; it checks main-window lifetime, reopen, and menu routing without scanning or installing actual plug-ins. The CLI suite injects a fixture inventory. Set `PLUGIN_PORTER_CLI` to a built app executable to test the actual Release binary; the one inventory-injection test is explicitly skipped in that mode.

The coverage runner snapshots sources before compiling, instruments the CLI child processes too, and retains reports under `.build/coverage.*/`. Its whole-project report includes unexecuted GUI code. Core-only coverage is reported separately and must not be presented as project coverage. The 80% project target is not yet met; see [the audit report](../docs/audit-2026-11-07.md).

New regression coverage includes JSON output/source collisions before writes, command-specific options, bounded export-plan input, negative/overflowing byte counts, safe bundle metadata inspection, archive writer/reader size limits, and Vital auxiliary-file placement. `EnginePerformance.swift` is a separate disposable 256 MiB benchmark; it has no timing pass/fail threshold.
