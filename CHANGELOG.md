# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-30

### Added

- Release workflow job publishing the install scripts to Cloudsmith as
  `cli.sh` and `cli.ps1` (with `SHA256SUMS`), gated on configuration and
  authenticated via the CLI's GitHub Actions OIDC exchange. Served at
  `https://install.cloudsmith.com/raw/versions/latest/cli.<sh|ps1>`.
- README instructions for installing from the published Cloudsmith URLs.
- Cross-platform `install.sh` and `install.ps1` installers for the standalone
  Cloudsmith CLI.
- Automatic platform detection, including native Arm64 selection under
  Rosetta 2, and support for selecting a specific CLI version or target.
- SHA-256 verification, archive safety checks, atomic installation, and
  concurrent-install locking.
- Preflight checks for archive and checksum tools before release archive
  downloads.
- Stable machine-readable output for CI/CD consumers.
- Cross-platform test, security scanning, release, and integration-vendoring
  workflows.

### Fixed

- The release workflow verifies the published Cloudsmith files at their
  actual download path (`raw/versions/<version>/<file>`), and a failed
  download is reported as a notice instead of a spurious checksum mismatch.
