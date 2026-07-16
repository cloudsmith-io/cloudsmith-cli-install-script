bats_require_minimum_version '1.5.0'

load 'helpers/fixture'

INSTALL_SH="$BATS_TEST_DIRNAME/../install.sh"

# --target is always passed explicitly so detect_target() is never exercised here.
TEST_TARGET="linux-x86_64-gnu"

setup() {
  export CLOUDSMITH_CLI_ALLOW_INSECURE_URLS=true

  FIXTURE_DIR="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE_DIR"
  start_fixture_server "$FIXTURE_DIR"

  INSTALL_ROOT="$BATS_TEST_TMPDIR/install-root"
  mkdir -p "$INSTALL_ROOT"
}

teardown() {
  stop_fixture_server
}

make_path_without_curl() {
  local bin="$BATS_TEST_TMPDIR/path-without-curl"
  mkdir -p "$bin"

  local cmd path
  for cmd in sh mkdir mktemp rm rmdir awk tr tar gzip gunzip cat chmod mv dirname grep cp sha256sum shasum openssl sleep; do
    path="$(command -v "$cmd" 2>/dev/null || true)"
    if [ -n "$path" ] && [ ! -e "$bin/$cmd" ]; then
      ln -s "$path" "$bin/$cmd"
    fi
  done

  printf '%s\n' "$bin"
}

write_busybox_wget_stub() {
  local bin="$1"
  cat > "$bin/wget" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$WGET_LOG"

if [ "${1-}" = "--help" ]; then
  printf '%s\n' "BusyBox wget"
  exit 0
fi

output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -O) output="$2"; shift 2 ;;
    -T) shift 2 ;;
    -q) shift ;;
    --https-only) printf '%s\n' "unexpected --https-only" >&2; exit 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done

[ -n "$output" ] || exit 3
[ -n "$url" ] || exit 3
cp "$WGET_FIXTURE_DIR/${url##*/}" "$output"
EOF
  chmod +x "$bin/wget"
}

@test "happy path: exact version installs and prints exactly four key=value lines" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -eq 0 ]

  local bin_dir="$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith"
  local expected
  expected="version=1.19.0
target=$TEST_TARGET
bin_dir=$bin_dir
executable=$bin_dir/cloudsmith"
  [ "$output" = "$expected" ]

  [ -x "$bin_dir/cloudsmith" ]
  [ -f "$bin_dir/.cloudsmith-installation" ]

  run "$bin_dir/cloudsmith" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLI Package Version: 1.19.0"* ]]
}

@test "--help prints usage with HOME and XDG_DATA_HOME unset" {
  run --separate-stderr env -u HOME -u XDG_DATA_HOME "$INSTALL_SH" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: install.sh"* ]]
  [[ "$output" == *"--version VERSION"* ]]
}

@test "explicit --install-root works with HOME and XDG_DATA_HOME unset" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"

  run --separate-stderr env -u HOME -u XDG_DATA_HOME "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -eq 0 ]
  [ -x "$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "happy path: --version latest resolves and installs the manifest's version" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"

  run --separate-stderr "$INSTALL_SH" \
    --version latest \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -eq 0 ]
  local bin_dir="$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith"
  local expected
  expected="version=1.19.0
target=$TEST_TARGET
bin_dir=$bin_dir
executable=$bin_dir/cloudsmith"
  [ "$output" = "$expected" ]
  [ -x "$bin_dir/cloudsmith" ]
}

@test "--output-file writes the four result lines to a file and stdout stays empty" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  local out_file="$BATS_TEST_TMPDIR/result.txt"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt" \
    --output-file "$out_file"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$out_file" ]

  local bin_dir="$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith"
  local expected
  expected="version=1.19.0
target=$TEST_TARGET
bin_dir=$bin_dir
executable=$bin_dir/cloudsmith"
  [ "$(cat "$out_file")" = "$expected" ]
}

@test "install root containing spaces works end-to-end" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  local spaced_root="$BATS_TEST_TMPDIR/install root with spaces"
  mkdir -p "$spaced_root"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$spaced_root" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -eq 0 ]
  [ -x "$spaced_root/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "reuse: second run with an unchanged manifest does not re-download the archive" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"
  [ "$status" -eq 0 ]

  # Corrupt the archive without touching the manifest's sha256, so a re-download would fail checksum.
  local archive_path
  archive_path="$(fixture_archive_path "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET")"
  echo "corrupted" > "$archive_path"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -eq 0 ]
  [[ "$stderr" == *"reusing"* ]]
}

@test "--force reinstalls even when a valid installation already exists" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"
  [ "$status" -eq 0 ]

  run --separate-stderr "$INSTALL_SH" \
    --force \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -eq 0 ]
  [[ "$stderr" != *"reusing"* ]]
  [[ "$stderr" == *"installed Cloudsmith CLI"* ]]
}

@test "checksum mismatch fails and installs nothing" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  # Well-formed (64 hex chars) but wrong, to hit the mismatch path rather than the format check.
  set_manifest_field "$FIXTURE_DIR/manifest.txt" sha256 \
    "$(printf '0%.0s' $(seq 1 64))"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"checksum mismatch"* ]]
  [ ! -e "$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "unsupported manifest schema fails" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  set_manifest_field "$FIXTURE_DIR/manifest.txt" schema 2

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unsupported manifest schema"* ]]
}

@test "target mismatch between manifest and requested target fails" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  set_manifest_field "$FIXTURE_DIR/manifest.txt" target "other-target"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"does not match"* ]]
}

@test "requested version mismatch with manifest's resolved version fails" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.0.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"manifest resolved"* ]]
}

@test "requested version '..' is rejected before any network access" {
  run --separate-stderr "$INSTALL_SH" \
    --version '..' \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid version"* ]]
}

@test "invalid sha256 in manifest (non-hex) fails" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  set_manifest_field "$FIXTURE_DIR/manifest.txt" sha256 "not-a-real-sha-value"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid SHA-256"* ]]
}

@test "invalid sha256 in manifest (short hex) fails" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  set_manifest_field "$FIXTURE_DIR/manifest.txt" sha256 "abc123"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"64 hexadecimal characters"* ]]
}

@test "manifest version '..' is rejected before install paths are composed" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  set_manifest_field "$FIXTURE_DIR/manifest.txt" version '..'

  run --separate-stderr "$INSTALL_SH" \
    --version latest \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"manifest contains an invalid version"* ]]
  [ ! -e "$INSTALL_ROOT/../$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "archive entry outside cloudsmith/ is rejected" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  local archive_path
  archive_path="$(fixture_archive_path "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET")"
  build_evil_archive outside "$archive_path" "1.19.0"
  sync_manifest_sha "$FIXTURE_DIR/manifest.txt" "$archive_path"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unexpected archive entry"* ]]
  [ ! -e "$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "archive entry with path traversal is rejected" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  local archive_path
  archive_path="$(fixture_archive_path "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET")"
  build_evil_archive traversal "$archive_path" "1.19.0"
  sync_manifest_sha "$FIXTURE_DIR/manifest.txt" "$archive_path"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unsafe archive entry"* ]]
  [ ! -e "$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "archive symlink executable is rejected" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  local archive_path
  archive_path="$(fixture_archive_path "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET")"
  build_evil_archive symlink "$archive_path" "1.19.0"
  sync_manifest_sha "$FIXTURE_DIR/manifest.txt" "$archive_path"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unsafe link entry"* ]]
  [ ! -e "$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "archive with a safe relative symlink installs" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  local archive_path
  archive_path="$(fixture_archive_path "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET")"
  build_evil_archive safe-symlink "$archive_path" "1.19.0"
  sync_manifest_sha "$FIXTURE_DIR/manifest.txt" "$archive_path"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -eq 0 ]
  [ -e "$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "archive hardlink executable is rejected" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  local archive_path
  archive_path="$(fixture_archive_path "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET")"
  build_evil_archive hardlink "$archive_path" "1.19.0"
  sync_manifest_sha "$FIXTURE_DIR/manifest.txt" "$archive_path"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unsupported link entry"* ]]
  [ ! -e "$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "corrupt (truncated) archive with a matching checksum fails safely" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  local archive_path
  archive_path="$(fixture_archive_path "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET")"
  truncate_archive "$archive_path"
  sync_manifest_sha "$FIXTURE_DIR/manifest.txt" "$archive_path"

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [ ! -e "$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "staged executable failing --version validation aborts install" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET" fail

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"failed validation"* ]]
  [ ! -e "$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "staged executable reporting the wrong version aborts install" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET" wrong-version

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"did not report CLI version 1.19.0"* ]]
  [ ! -e "$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
}

@test "BusyBox-style wget is rejected in secure mode because it cannot enforce HTTPS redirects" {
  local no_curl_path="$BATS_TEST_TMPDIR/no-curl-secure"
  no_curl_path="$(make_path_without_curl)"
  write_busybox_wget_stub "$no_curl_path"
  unset CLOUDSMITH_CLI_ALLOW_INSECURE_URLS

  export WGET_FIXTURE_DIR="$FIXTURE_DIR"
  export WGET_LOG="$BATS_TEST_TMPDIR/wget-secure.log"
  : > "$WGET_LOG"

  run --separate-stderr env PATH="$no_curl_path" \
    WGET_FIXTURE_DIR="$WGET_FIXTURE_DIR" \
    WGET_LOG="$WGET_LOG" \
    "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "https://example.invalid/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"secure downloads require curl or GNU wget with --https-only"* ]]
  [[ "$(cat "$WGET_LOG")" == *"--help"* ]]
}

@test "BusyBox-style wget is allowed when insecure URLs are explicitly enabled" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"

  local no_curl_path="$BATS_TEST_TMPDIR/no-curl-insecure"
  no_curl_path="$(make_path_without_curl)"
  write_busybox_wget_stub "$no_curl_path"

  export WGET_FIXTURE_DIR="$FIXTURE_DIR"
  export WGET_LOG="$BATS_TEST_TMPDIR/wget-insecure.log"
  : > "$WGET_LOG"

  run --separate-stderr env PATH="$no_curl_path" \
    CLOUDSMITH_CLI_ALLOW_INSECURE_URLS=true \
    WGET_FIXTURE_DIR="$WGET_FIXTURE_DIR" \
    WGET_LOG="$WGET_LOG" \
    "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -eq 0 ]
  [ -x "$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith" ]
  [[ "$(cat "$WGET_LOG")" != *"--https-only"* ]]
}

@test "http:// manifest URL without CLOUDSMITH_CLI_ALLOW_INSECURE_URLS fails" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  unset CLOUDSMITH_CLI_ALLOW_INSECURE_URLS

  run --separate-stderr "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"must use HTTPS"* ]]
}

@test "--target . is rejected" {
  run --separate-stderr "$INSTALL_SH" \
    --target '.' \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid target"* ]]
}

@test "--target .. is rejected" {
  run --separate-stderr "$INSTALL_SH" \
    --target '..' \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid target"* ]]
}

@test "unknown option fails with a descriptive error" {
  run --separate-stderr "$INSTALL_SH" --bogus-option

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unknown option"* ]]
}

@test "invalid --version value is rejected before any network access" {
  run --separate-stderr "$INSTALL_SH" \
    --version '1.0;rm' \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid version"* ]]
}

@test "--help prints usage on stdout and exits 0" {
  run --separate-stderr "$INSTALL_SH" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: install.sh"* ]]
  [[ "$output" == *"--version VERSION"* ]]
}

@test "stale lock directory is respected and released once it is removed" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  local final_parent="$INSTALL_ROOT/1.19.0/$TEST_TARGET"
  mkdir -p "$final_parent/.install.lock"

  local out_file="$BATS_TEST_TMPDIR/bg.out"
  local err_file="$BATS_TEST_TMPDIR/bg.err"

  "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt" \
    >"$out_file" 2>"$err_file" &
  local bg_pid=$!

  sleep 2
  rmdir "$final_parent/.install.lock"

  wait "$bg_pid"
  local bg_status=$?

  [ "$bg_status" -eq 0 ]
  [ -x "$final_parent/cloudsmith/cloudsmith" ]
}

@test "a waiter that dies does not remove another installer's lock" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"
  local final_parent="$INSTALL_ROOT/1.19.0/$TEST_TARGET"
  mkdir -p "$final_parent/.install.lock"

  "$INSTALL_SH" \
    --version 1.19.0 \
    --target "$TEST_TARGET" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt" \
    >"$BATS_TEST_TMPDIR/bg.out" 2>"$BATS_TEST_TMPDIR/bg.err" &
  local bg_pid=$!

  sleep 2
  kill -TERM "$bg_pid"

  local bg_status=0
  wait "$bg_pid" || bg_status=$?

  [ "$bg_status" -ne 0 ]
  [ -d "$final_parent/.install.lock" ]
}

@test "concurrent installs of the same version both succeed" {
  build_fixture "$FIXTURE_DIR" "1.19.0" "$TEST_TARGET"

  local out1="$BATS_TEST_TMPDIR/out1.txt" out2="$BATS_TEST_TMPDIR/out2.txt"
  local err1="$BATS_TEST_TMPDIR/err1.txt" err2="$BATS_TEST_TMPDIR/err2.txt"

  "$INSTALL_SH" \
    --version 1.19.0 --target "$TEST_TARGET" --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt" >"$out1" 2>"$err1" &
  local pid1=$!

  "$INSTALL_SH" \
    --version 1.19.0 --target "$TEST_TARGET" --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt" >"$out2" 2>"$err2" &
  local pid2=$!

  wait "$pid1"; local status1=$?
  wait "$pid2"; local status2=$?

  [ "$status1" -eq 0 ]
  [ "$status2" -eq 0 ]

  local bin="$INSTALL_ROOT/1.19.0/$TEST_TARGET/cloudsmith/cloudsmith"
  [ -x "$bin" ]
  run "$bin" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLI Package Version: 1.19.0"* ]]
}
