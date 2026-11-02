# Contributing

This project is in early development. Open an issue before starting a large change so we can agree on scope. Small fixes can go directly to a pull request.

Use Xcode 27.1 or newer and XcodeGen. Run `xcodegen generate` when source files or project settings change, then build both schemes with signing disabled. Keep setup keys, profiles, derived data, and personal device identifiers out of commits.

Commit messages follow Conventional Commits, for example `fix(network): restore discovery after wake`.

Any included third-party code must retain its required copyright notices and licensing terms. Keep product interfaces, copy and implementation project-specific.
