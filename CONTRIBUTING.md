# Contributing

Thank you for helping improve the Cloudsmith CLI installers. Bug reports,
documentation improvements, tests, and focused code changes are welcome.

## Before you start

- Search existing issues and pull requests before opening a duplicate.
- Use the issue templates for bugs, feature requests, and usage questions.
- Do not open a public issue for a suspected vulnerability. Follow
  [SECURITY.md](SECURITY.md) instead.
- Keep changes focused. The installers are vendored by multiple CI/CD
  integrations, so compatibility and reviewability matter.

## Development setup

Fork and clone the repository, then create a branch from `main`.

The shell suite requires bats-core 1.5 or later and Python 3:

```sh
bats tests/
```

Shell changes should also pass the checks used in CI:

```sh
sh -n install.sh
shellcheck --shell=sh --severity=style install.sh
```

The Windows suite requires Pester 5.5 through 5.99:

```powershell
Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser
Import-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99
Invoke-Pester -Path tests/Install.Tests.ps1
```

See [tests/README.md](tests/README.md) for more detail. Tests use local fixtures
and do not require access to the public package repository.

## Compatibility expectations

Treat these interfaces as public contracts:

- command-line options and PowerShell parameters
- `CLOUDSMITH_CLI_*` environment variables
- supported target identifiers
- versioned installation layout
- the four `key=value` output lines

Changes to a public contract need explicit release notes, integration impact
analysis, and an appropriate semantic-versioning decision. Preserve POSIX `sh`
compatibility in `install.sh` and Windows PowerShell 5.1 compatibility in
`install.ps1`.

## Pull requests

- Explain the problem and the chosen solution.
- Add or update tests for behavior changes.
- Update `README.md` and `CHANGELOG.md` when user-visible behavior changes.
- List the validation commands you ran.
- Keep commits free of credentials, private URLs, generated test artifacts, and
  unrelated changes.

Maintainers may request additional integration validation before merging a
change that affects installer behavior or release distribution.
