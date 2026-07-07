# Helpers for a loopback-only (127.0.0.1) HTTP fixture server that serves a fake
# Cloudsmith CLI release, so install.sh can be tested end-to-end with no real network.

# fixture_sha256 <file>: prints the lowercase hex SHA-256 digest, via shasum or sha256sum.
fixture_sha256() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    echo "fixture.bash: shasum or sha256sum is required" >&2
    return 1
  fi
}

# fixture_archive_name <version> <target>
fixture_archive_name() {
  printf 'cloudsmith-%s-%s.tar.gz' "$1" "$2"
}

# fixture_archive_path <dir> <version> <target>
fixture_archive_path() {
  printf '%s/%s' "$1" "$(fixture_archive_name "$2" "$3")"
}

# start_fixture_server <dir>: serves <dir> on an ephemeral 127.0.0.1 port; exports FIXTURE_URL.
start_fixture_server() {
  local dir="$1"
  mkdir -p "$dir"

  FIXTURE_SERVER_LOG="$dir/.server.log"
  : > "$FIXTURE_SERVER_LOG"

  local port_file err_file
  port_file="$(mktemp "${TMPDIR:-/tmp}/cloudsmith-fixture-port.XXXXXX")"
  err_file="$dir/.server.err"

  python3 - "$dir" "$FIXTURE_SERVER_LOG" >"$port_file" 2>"$err_file" <<'PY' &
import http.server
import os
import socketserver
import sys

served_dir, log_file = sys.argv[1], sys.argv[2]
os.chdir(served_dir)


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        with open(log_file, "a") as handle:
            handle.write((fmt % args) + "\n")


class Server(socketserver.TCPServer):
    allow_reuse_address = True


with Server(("127.0.0.1", 0), Handler) as httpd:
    print(httpd.server_address[1], flush=True)
    httpd.serve_forever()
PY
  FIXTURE_SERVER_PID=$!

  local waited=0
  while [ ! -s "$port_file" ]; do
    if ! kill -0 "$FIXTURE_SERVER_PID" 2>/dev/null; then
      echo "fixture.bash: fixture server exited before it started listening" >&2
      cat "$err_file" >&2 || true
      rm -f "$port_file"
      return 1
    fi
    waited=$((waited + 1))
    if [ "$waited" -gt 50 ]; then
      echo "fixture.bash: timed out waiting for fixture server to start" >&2
      cat "$err_file" >&2 || true
      rm -f "$port_file"
      return 1
    fi
    sleep 0.1
  done

  local port
  port="$(cat "$port_file")"
  rm -f "$port_file"

  export FIXTURE_URL="http://127.0.0.1:${port}"
  export FIXTURE_SERVER_PID
  export FIXTURE_SERVER_LOG
}

# stop_fixture_server: safe to call even if no server was started.
stop_fixture_server() {
  if [ -n "${FIXTURE_SERVER_PID:-}" ]; then
    kill "$FIXTURE_SERVER_PID" 2>/dev/null || true
    wait "$FIXTURE_SERVER_PID" 2>/dev/null || true
    unset FIXTURE_SERVER_PID
  fi
}

# build_fixture <dir> <version> <target> [ok|fail|wrong-version]: writes a fake archive +
# manifest.txt into <dir> (must already be served by start_fixture_server). "fail" makes
# the staged executable always exit 1, while "wrong-version" exits 0 with a mismatched
# version string.
build_fixture() {
  local dir="$1" version="$2" target="$3" behavior="${4:-ok}"

  if [ -z "${FIXTURE_URL:-}" ]; then
    echo "fixture.bash: FIXTURE_URL is not set; call start_fixture_server first" >&2
    return 1
  fi

  local archive_name staging
  archive_name="$(fixture_archive_name "$version" "$target")"
  staging="$(mktemp -d "${TMPDIR:-/tmp}/cloudsmith-fixture-src.XXXXXX")"
  mkdir -p "$staging/cloudsmith"

  if [ "$behavior" = "fail" ]; then
    cat > "$staging/cloudsmith/cloudsmith" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
  elif [ "$behavior" = "wrong-version" ]; then
    cat > "$staging/cloudsmith/cloudsmith" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  --version) printf 'Versions:\nCLI Package Version: 0.0.0\nAPI Package Version: 2.0.27\n' ;;
  *) exit 1 ;;
esac
EOF
  else
    cat > "$staging/cloudsmith/cloudsmith" <<EOF
#!/usr/bin/env sh
case "\$1" in
  --version) printf 'Versions:\nCLI Package Version: %s\nAPI Package Version: 2.0.27\n' "$version" ;;
  *) exit 1 ;;
esac
EOF
  fi
  chmod +x "$staging/cloudsmith/cloudsmith"

  ( cd "$staging" && tar -czf "$dir/$archive_name" cloudsmith )
  rm -rf "$staging"

  local sha
  sha="$(fixture_sha256 "$dir/$archive_name")"

  cat > "$dir/manifest.txt" <<EOF
schema=1
version=$version
target=$target
archive=$archive_name
url=${FIXTURE_URL}/$archive_name
sha256=$sha
EOF
}

# set_manifest_field <manifest_file> <field> <value>: rewrites or appends a key=value line.
set_manifest_field() {
  local manifest="$1" field="$2" value="$3"
  awk -F= -v f="$field" -v v="$value" '
    BEGIN { done = 0 }
    $1 == f { print f "=" v; done = 1; next }
    { print }
    END { if (!done) print f "=" v }
  ' "$manifest" > "$manifest.tmp" && mv "$manifest.tmp" "$manifest"
}

# sync_manifest_sha <manifest_file> <archive_path>: recomputes and writes the archive's sha256,
# so a later validation step (not the checksum check) is what fails after mutating the archive.
sync_manifest_sha() {
  local manifest="$1" archive_path="$2"
  local sha
  sha="$(fixture_sha256 "$archive_path")"
  set_manifest_field "$manifest" sha256 "$sha"
}

# build_evil_archive <outside|traversal|symlink|hardlink> <archive_path> <version>: overwrites
# the archive with an offending entry. Link modes replace cloudsmith/cloudsmith with link
# metadata so pre-extraction archive validation is what must reject them.
# Follow with sync_manifest_sha. Uses python3 tarfile for portability across bsdtar and GNU tar.
build_evil_archive() {
  local mode="$1" archive_path="$2" version="$3"
  python3 - "$mode" "$archive_path" "$version" <<'PY'
import io
import sys
import tarfile

mode, archive_path, version = sys.argv[1], sys.argv[2], sys.argv[3]


def add(tar, name, content, file_mode=0o755):
    data = content.encode()
    info = tarfile.TarInfo(name=name)
    info.size = len(data)
    info.mode = file_mode
    tar.addfile(info, io.BytesIO(data))


script = (
    "#!/usr/bin/env sh\n"
    "case \"$1\" in\n"
    "  --version) printf 'Versions:\\nCLI Package Version: %s\\nAPI Package Version: 2.0.27\\n' \"" + version + "\" ;;\n"
    "  *) exit 1 ;;\n"
    "esac\n"
)

with tarfile.open(archive_path, "w:gz") as tar:
    if mode in ("symlink", "hardlink"):
        info = tarfile.TarInfo(name="cloudsmith/cloudsmith")
        info.mode = 0o755
        if mode == "symlink":
            info.type = tarfile.SYMTYPE
            info.linkname = "../outside-cloudsmith"
        else:
            info.type = tarfile.LNKTYPE
            info.linkname = "../outside-cloudsmith"
        tar.addfile(info)
    else:
        add(tar, "cloudsmith/cloudsmith", script)

    if mode == "outside":
        add(tar, "evil.txt", "pwned", 0o644)
    elif mode == "traversal":
        add(tar, "cloudsmith/../evil.txt", "pwned", 0o644)
    elif mode == "safe-symlink":
        add(tar, "cloudsmith/_internal/lib.so.1", "fake lib", 0o644)
        info = tarfile.TarInfo(name="cloudsmith/_internal/lib.so")
        info.type = tarfile.SYMTYPE
        info.linkname = "lib.so.1"
        tar.addfile(info)
    elif mode in ("symlink", "hardlink"):
        pass
    else:
        raise SystemExit("build_evil_archive: unknown mode " + mode)
PY
}

# truncate_archive <archive_path>: chops the file in half in place, producing an unreadable
# gzip stream. Follow with sync_manifest_sha to make the checksum check pass despite corruption.
truncate_archive() {
  local archive_path="$1"
  local size half
  size=$(wc -c < "$archive_path" | tr -d ' ')
  half=$((size / 2))
  [ "$half" -gt 0 ] || half=1
  dd if="$archive_path" of="$archive_path.tmp" bs=1 count="$half" 2>/dev/null
  mv "$archive_path.tmp" "$archive_path"
}
