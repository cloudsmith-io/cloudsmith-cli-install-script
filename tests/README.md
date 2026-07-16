# Tests

Both test suites are network-free. Fixtures are served over loopback only
(`127.0.0.1` or `localhost`).

## Shell suite

The shell suite covers `install.bats` and `detect_target.bats`. It requires
[bats-core](https://github.com/bats-core/bats-core) 1.5.0 or later and
Python 3.

Run it from the repository root:

```sh
bats tests/
```

## PowerShell suite

The Windows-only PowerShell suite (`Install.Tests.ps1`) requires Pester 5.5 or
later in the 5.x release line. The suite skips cleanly on non-Windows hosts.

Install the supported Pester version:

```powershell
Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser
```

Run the suite from the repository root:

```powershell
Import-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99
Invoke-Pester -Path tests/Install.Tests.ps1
```
