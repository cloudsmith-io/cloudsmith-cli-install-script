bats_require_minimum_version '1.5.0'

load 'helpers/fixture'

INSTALL_SH="$BATS_TEST_DIRNAME/../install.sh"

# detect_target() logs "detected target X" before touching the network, so an
# unreachable manifest URL is enough to test detection alone.
setup() {
  export CLOUDSMITH_CLI_ALLOW_INSECURE_URLS=true

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"

  INSTALL_ROOT="$BATS_TEST_TMPDIR/install-root"
  mkdir -p "$INSTALL_ROOT"

  UNREACHABLE_MANIFEST_URL="file://$BATS_TEST_TMPDIR/does-not-exist/manifest.txt"
}

teardown() {
  stop_fixture_server
}

# write_uname_stub <system> <machine>: fakes `uname -s`/`uname -m` on PATH.
write_uname_stub() {
  local system="$1" machine="$2"
  cat > "$STUB_BIN/uname" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -s) printf '%s\n' "$system" ;;
  -m) printf '%s\n' "$machine" ;;
  *) printf '%s\n' "$system" ;;
esac
EOF
  chmod +x "$STUB_BIN/uname"
}

# write_getconf_stub <gnu|fail>: "gnu" simulates glibc; "fail" forces the ldd fallback.
write_getconf_stub() {
  local mode="$1"
  if [ "$mode" = "gnu" ]; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/getconf"
  else
    printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_BIN/getconf"
  fi
  chmod +x "$STUB_BIN/getconf"
}

# write_ldd_stub <musl|gnu>
write_ldd_stub() {
  local libc="$1"
  if [ "$libc" = "musl" ]; then
    printf '#!/usr/bin/env bash\necho "musl libc (fake)"\nexit 1\n' > "$STUB_BIN/ldd"
  else
    printf '#!/usr/bin/env bash\necho "ldd (fake) GNU libc 2.31"\nexit 0\n' > "$STUB_BIN/ldd"
  fi
  chmod +x "$STUB_BIN/ldd"
}

@test "darwin/arm64 is detected as macos-arm64" {
  write_uname_stub Darwin arm64

  run --separate-stderr "$INSTALL_SH" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$UNREACHABLE_MANIFEST_URL"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"detected target macos-arm64"* ]]
}

@test "darwin/x86_64 is detected as macos-x86_64" {
  write_uname_stub Darwin x86_64

  run --separate-stderr "$INSTALL_SH" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$UNREACHABLE_MANIFEST_URL"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"detected target macos-x86_64"* ]]
}

@test "linux/x86_64 with glibc (getconf) is detected as linux-x86_64-gnu" {
  # The real filesystem probe (/etc/alpine-release, ld-musl) answers before the
  # getconf stub can, so this scenario is untestable on a musl host.
  if [ -f /etc/alpine-release ] || ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
    skip "musl host: filesystem probe wins over the getconf stub"
  fi
  write_uname_stub Linux x86_64
  write_getconf_stub gnu

  run --separate-stderr "$INSTALL_SH" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$UNREACHABLE_MANIFEST_URL"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"detected target linux-x86_64-gnu"* ]]
}

@test "linux/aarch64 with musl (no getconf, ldd reports musl) is detected as linux-aarch64-musl" {
  write_uname_stub Linux aarch64
  write_getconf_stub fail
  write_ldd_stub musl

  run --separate-stderr "$INSTALL_SH" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$UNREACHABLE_MANIFEST_URL"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"detected target linux-aarch64-musl"* ]]
}

@test "unsupported operating system fails detection" {
  write_uname_stub Plan9 x86_64

  run --separate-stderr "$INSTALL_SH" \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$UNREACHABLE_MANIFEST_URL"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unsupported operating system"* ]]
}

@test "--target override bypasses detection entirely and installs successfully" {
  # uname reports an OS that would otherwise fail detection, proving the override wins.
  write_uname_stub Plan9 x86_64

  FIXTURE_DIR="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE_DIR"
  start_fixture_server "$FIXTURE_DIR"
  build_fixture "$FIXTURE_DIR" "1.19.0" "custom-target-x86_64"

  run --separate-stderr "$INSTALL_SH" \
    --target custom-target-x86_64 \
    --version 1.19.0 \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$FIXTURE_URL/manifest.txt"

  [ "$status" -eq 0 ]
  [[ "$stderr" == *"detected target custom-target-x86_64"* ]]
  [ -x "$INSTALL_ROOT/1.19.0/custom-target-x86_64/cloudsmith/cloudsmith" ]
}

@test "invalid --target override is rejected" {
  run --separate-stderr "$INSTALL_SH" \
    --target 'bad target!' \
    --install-root "$INSTALL_ROOT" \
    --manifest-url "$UNREACHABLE_MANIFEST_URL"

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"invalid target"* ]]
}
