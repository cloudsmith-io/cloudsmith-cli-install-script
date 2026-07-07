# Tests

Bash suite (`install.bats`, `detect_target.bats`): requires [bats-core](https://github.com/bats-core/bats-core) >= 1.5.0 and python3.
Run: `bats tests/`

PowerShell suite (`Install.Tests.ps1`), Windows only: requires Pester >= 5.5.0
(`Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser`).
Run: `Invoke-Pester -Path tests`. Self-skips cleanly on non-Windows hosts.

Both suites are network-free: all fixtures are served over loopback only (127.0.0.1 / localhost).
