# cloudsmith-cli-install-script

Install scripts for the [Cloudsmith CLI](https://github.com/cloudsmith-io/cloudsmith-cli)
standalone binary: `install.sh` (POSIX sh) and `install.ps1` (PowerShell).

Each script detects the platform, downloads the matching release archive,
verifies its SHA-256, and installs it into a versioned directory. It prints
where the binary was installed; it does not modify `PATH` or authenticate.

These scripts are vendored into the Cloudsmith CI integrations (GitHub
Action, CircleCI orb, Azure DevOps task). They are also published as assets
on this repository's GitHub releases, alongside a `SHA256SUMS` file.

## Usage

Linux/macOS:

```sh
sh install.sh --version latest
```

Windows:

```powershell
./install.ps1 -Version latest
```

### Options

`install.sh` flag / `install.ps1` parameter, matching environment variable, default:

| sh | PowerShell | Env var | Default |
| --- | --- | --- | --- |
| `--version` | `-Version` | `CLOUDSMITH_CLI_VERSION` | `latest` |
| `--install-root` | `-InstallRoot` | `CLOUDSMITH_CLI_INSTALL_ROOT` | `~/.local/share/cloudsmith-cli` (sh), `%LOCALAPPDATA%\Cloudsmith\CLI` (ps1) |
| `--target` | `-Target` | `CLOUDSMITH_CLI_TARGET` | auto-detected |
| `--output-file` | `-OutputFile` | `CLOUDSMITH_CLI_OUTPUT_FILE` | stdout |
| `--repository` | `-Repository` | `CLOUDSMITH_CLI_REPOSITORY` | `cloudsmith/cli-standalone` |
| `--manifest-url` | `-ManifestUrl` | `CLOUDSMITH_CLI_MANIFEST_URL` | derived from repository/version/target |
| `--force` | `-Force` | — | off |

## Output

On success the script prints exactly four `key=value` lines (to stdout, or
to the output file if set). Everything else goes to stderr.

```
version=1.19.0
target=linux-x86_64-gnu
bin_dir=/home/runner/.local/share/cloudsmith-cli/1.19.0/linux-x86_64-gnu/cloudsmith
executable=/home/runner/.local/share/cloudsmith-cli/1.19.0/linux-x86_64-gnu/cloudsmith/cloudsmith
```

## Supported targets

| Target | Notes |
| --- | --- |
| `linux-x86_64-gnu` | glibc 2.28+ |
| `linux-aarch64-gnu` | glibc 2.28+ |
| `linux-x86_64-musl` | Alpine and other musl distros |
| `linux-aarch64-musl` | Alpine and other musl distros |
| `macos-x86_64` | Intel |
| `macos-arm64` | Apple Silicon |
| `windows-x86_64` | Also used on Windows ARM64 (x86_64 emulation) |

If libc detection fails on an unusual host, pass `--target` explicitly.

## Security

- HTTPS-only downloads.
- Archive SHA-256 verified against the release manifest before extraction.
- Archive entries validated before extraction (no absolute paths or `..`).
- Binary is staged, checked with `cloudsmith --version`, then activated
  atomically; concurrent installs are serialized with a lock.
- Already-installed, verified versions are reused unless `--force` is given.

Proxies and custom CAs: downloads use `curl`/`wget` (sh) or
`Invoke-WebRequest` (PowerShell), so standard proxy environment variables
and OS trust stores apply.

## Development

```sh
bats tests/          # shell suite (needs bats-core and python3)
Invoke-Pester        # PowerShell suite (Pester 5.5+, Windows)
```

## Releases

Tagged `vX.Y.Z`. Release assets are immutable; breaking changes to flags or
output are a major version bump.
