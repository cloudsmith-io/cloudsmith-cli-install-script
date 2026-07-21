# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Release workflow job publishing `install.sh`, `install.ps1`, and
  `SHA256SUMS` to Cloudsmith, gated on configuration and authenticated via the
  CLI's GitHub Actions OIDC exchange.
- README instructions for installing from the published Cloudsmith URLs.

## [0.1.0] - 2026-07-16

### Added

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
