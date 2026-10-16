#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

fixture_dir="$temp_dir/fixtures"
mock_bin="$temp_dir/bin"
workspace="$temp_dir/workspace"
mkdir -p "$fixture_dir" "$mock_bin" "$workspace/demo project"

cat > "$fixture_dir/datatug" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  version)
    printf '{"version":"1.2.3"}\n'
    ;;
  validate)
    printf '%s\n' "${2:?expected validate directory argument}" > "$DATATUG_VALIDATION_LOG"
    ;;
  *)
    exit 64
    ;;
esac
CLI
chmod 0755 "$fixture_dir/datatug"
tar -czf "$fixture_dir/datatug-linux.tar.gz" -C "$fixture_dir" datatug

sha256_for() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

archive_sha="$(sha256_for "$fixture_dir/datatug-linux.tar.gz")"
cat > "$fixture_dir/latest.json" <<'JSON'
{"tag_name":"v1.2.3","draft":false,"prerelease":false}
JSON
cat > "$fixture_dir/checksums.txt" <<CHECKSUMS
${archive_sha}  datatug_1.2.3_linux_amd64.tar.gz
${archive_sha} *datatug_1.2.3_linux_arm64.tar.gz
${archive_sha}  datatug_1.2.3_darwin_amd64.tar.gz
${archive_sha}  datatug_1.2.3_darwin_arm64.tar.gz
CHECKSUMS
cp "$fixture_dir/datatug-linux.tar.gz" "$fixture_dir/datatug-darwin.tar.gz"

cat > "$mock_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
auth_header=0
while (($#)); do
  case "$1" in
    --output|-o)
      output="$2"
      shift 2
      ;;
    --header|-H)
      [[ "$2" == Authorization:* ]] && auth_header=1
      shift 2
      ;;
    --fail|--silent|--show-error|--location|-f|-s|-S|-L)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || exit 65
if [[ "$url" == https://api.github.com/repos/datatug/datatug/releases/latest ]]; then
  [[ "$auth_header" == 1 ]] || exit 66
  printf 'api\n' >> "$CURL_LOG"
  cp "$FIXTURE_DIR/latest.json" "$output"
elif [[ "$url" == https://github.com/datatug/datatug/releases/download/v1.2.3/datatug_1.2.3_checksums.txt ]]; then
  printf 'checksums\n' >> "$CURL_LOG"
  cp "$FIXTURE_DIR/checksums.txt" "$output"
elif [[ "$url" == https://github.com/datatug/datatug/releases/download/v1.2.3/datatug_1.2.3_linux_amd64.tar.gz || \
        "$url" == https://github.com/datatug/datatug/releases/download/v1.2.3/datatug_1.2.3_darwin_arm64.tar.gz ]]; then
  printf 'archive\n' >> "$CURL_LOG"
  cp "$FIXTURE_DIR/datatug-linux.tar.gz" "$output"
else
  printf 'unexpected URL: %s\n' "$url" >&2
  exit 67
fi
CURL
chmod 0755 "$mock_bin/curl"

export PATH="$mock_bin:$PATH"
export FIXTURE_DIR="$fixture_dir"
export CURL_LOG="$temp_dir/curl.log"
export DATATUG_GITHUB_TOKEN="test-token"
export RUNNER_TEMP="$temp_dir/runner"
mkdir -p "$RUNNER_TEMP"

reject_before_network() {
  : > "$CURL_LOG"
  if RUNNER_OS=Windows RUNNER_ARCH=X64 GITHUB_OUTPUT="$temp_dir/unsupported.out" \
    "$script_dir/datatug-cli.sh" resolve >"$temp_dir/unsupported.stdout" 2>"$temp_dir/unsupported.stderr"; then
    echo 'unsupported runner OS unexpectedly succeeded' >&2
    exit 1
  fi
  [[ ! -s "$CURL_LOG" ]] || { echo 'unsupported runner reached the network' >&2; exit 1; }
}

reject_before_network

release_output="$temp_dir/release-linux.out"
: > "$CURL_LOG"
RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_OUTPUT="$release_output" \
  "$script_dir/datatug-cli.sh" resolve
grep -Fx 'tag=v1.2.3' "$release_output" >/dev/null
grep -Fx 'version=1.2.3' "$release_output" >/dev/null
grep -Fx 'archive=datatug_1.2.3_linux_amd64.tar.gz' "$release_output" >/dev/null
grep -Fx "sha256=$archive_sha" "$release_output" >/dev/null
grep -Fx "cache-key=datatug-cli-v1.2.3-Linux-X64-$archive_sha" "$release_output" >/dev/null
[[ "$(wc -l < "$CURL_LOG" | tr -d ' ')" == 2 ]] || { echo 'release resolution must make one API and one checksum request' >&2; exit 1; }

archive_name='datatug_1.2.3_linux_amd64.tar.gz'
archive_path="$RUNNER_TEMP/datatug-cli-cache/$archive_name"
DATATUG_RELEASE_TAG=v1.2.3 DATATUG_ARCHIVE="$archive_name" \
  "$script_dir/datatug-cli.sh" download
DATATUG_ARCHIVE="$archive_name" DATATUG_EXPECTED_SHA256="$archive_sha" \
  "$script_dir/datatug-cli.sh" verify

cp "$archive_path" "$temp_dir/corrupt.tar.gz"
printf 'corrupt' >> "$archive_path"
if DATATUG_ARCHIVE="$archive_name" DATATUG_EXPECTED_SHA256="$archive_sha" \
  "$script_dir/datatug-cli.sh" verify >"$temp_dir/corrupt.stdout" 2>"$temp_dir/corrupt.stderr"; then
  echo 'corrupt cached archive unexpectedly passed checksum verification' >&2
  exit 1
fi
mv "$temp_dir/corrupt.tar.gz" "$archive_path"

install_output="$temp_dir/install.out"
install_path_file="$temp_dir/github.path"
DATATUG_ARCHIVE="$archive_name" DATATUG_EXPECTED_VERSION=1.2.3 \
  GITHUB_OUTPUT="$install_output" GITHUB_PATH="$install_path_file" \
  "$script_dir/datatug-cli.sh" install
cli_path="$(awk -F= '$1 == "path" {sub(/^[^=]*=/, ""); print; exit}' "$install_output")"
[[ -x "$cli_path" ]] || { echo 'installed CLI is not executable' >&2; exit 1; }

validation_log="$temp_dir/validation.log"
resolved_workspace="$(cd "$workspace" && pwd -P)"
DATATUG_CLI="$cli_path" DATATUG_PROJECT_DIR='demo project' \
  GITHUB_WORKSPACE="$workspace" DATATUG_VALIDATION_LOG="$validation_log" \
  "$script_dir/datatug-cli.sh" validate
[[ "$(cat "$validation_log")" == "-d=$resolved_workspace/demo project" ]] \
  || { printf 'CLI validation received unexpected argument: %s\n' "$(cat "$validation_log")" >&2; exit 1; }

release_output="$temp_dir/release-macos.out"
RUNNER_OS=macOS RUNNER_ARCH=ARM64 GITHUB_OUTPUT="$release_output" \
  "$script_dir/datatug-cli.sh" resolve
grep -Fx 'archive=datatug_1.2.3_darwin_arm64.tar.gz' "$release_output" >/dev/null
grep -Fx "cache-key=datatug-cli-v1.2.3-macOS-ARM64-$archive_sha" "$release_output" >/dev/null

cp "$fixture_dir/latest.json" "$temp_dir/latest-stable.json"
printf '{"tag_name":"v1.2.4-rc.1","draft":false,"prerelease":true}\n' > "$fixture_dir/latest.json"
release_output="$temp_dir/release-prerelease.out"
: > "$CURL_LOG"
if RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_OUTPUT="$release_output" \
  "$script_dir/datatug-cli.sh" resolve >"$temp_dir/prerelease.stdout" 2>"$temp_dir/prerelease.stderr"; then
  echo 'prerelease metadata unexpectedly resolved as stable' >&2
  exit 1
fi
[[ "$(wc -l < "$CURL_LOG" | tr -d ' ')" == 1 ]] \
  || { echo 'prerelease metadata should fail before fetching checksums' >&2; exit 1; }
mv "$temp_dir/latest-stable.json" "$fixture_dir/latest.json"

echo 'DataTug CLI resolver, cache-key inputs, checksum verification, install, and safe project path tests passed.'
