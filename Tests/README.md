# Engine verification

Run on macOS with Xcode Command Line Tools:

```sh
./Tests/run-engine-tests.sh
```

Last result: **16/16 test groups passed** on the development Mac. Tests create disposable fixtures next to this README and remove them when each group finishes. They do not read, copy, execute, install or modify real plug-ins, `/Library`, or the current user's plug-in directories.

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
