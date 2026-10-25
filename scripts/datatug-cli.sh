#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'datatug-action: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  else
    die 'sha256sum or shasum is required'
  fi
}

resolve_platform() {
  case "${RUNNER_OS:-}" in
    Linux) DATATUG_OS=linux ;;
    macOS) DATATUG_OS=darwin ;;
    *) die "unsupported runner OS '${RUNNER_OS:-unset}'; supported OS values are Linux and macOS" ;;
  esac

  case "${RUNNER_ARCH:-}" in
    X64) DATATUG_ARCH=amd64 ;;
    ARM64) DATATUG_ARCH=arm64 ;;
    *) die "unsupported runner architecture '${RUNNER_ARCH:-unset}'; supported architectures are X64 and ARM64" ;;
  esac
}

resolve_release() (
  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
  : "${DATATUG_GITHUB_TOKEN:?GitHub token is required to read release metadata}"
  resolve_platform

  local temp_dir release_json tag version archive checksums release_url checksum_file hashes sha256 cache_key release_api
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  release_json="$temp_dir/release.json"
  checksum_file="$temp_dir/checksums.txt"

  if [[ -n "${DATATUG_CLI_VERSION:-}" ]]; then
    [[ "$DATATUG_CLI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || die 'CLI version must be a stable semantic version such as 1.2.3'
    release_api="https://api.github.com/repos/datatug/datatug/releases/tags/v${DATATUG_CLI_VERSION}"
  else
    release_api='https://api.github.com/repos/datatug/datatug/releases/latest'
  fi
  curl --fail --silent --show-error --output "$release_json" \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: Bearer ${DATATUG_GITHUB_TOKEN}" \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "$release_api"

  tag="$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' "$release_json")" \
    || die 'latest DataTug release metadata is missing a stable tag'
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected latest stable release tag '${tag}'"
  version="${tag#v}"
  [[ -z "${DATATUG_CLI_VERSION:-}" || "$version" == "$DATATUG_CLI_VERSION" ]] \
    || die 'resolved CLI release does not match the requested version'
  archive="datatug_${version}_${DATATUG_OS}_${DATATUG_ARCH}.tar.gz"
  checksums="datatug_${version}_checksums.txt"
  release_url="https://github.com/datatug/datatug/releases/download/${tag}"

  curl --fail --silent --show-error --location --output "$checksum_file" \
    "${release_url}/${checksums}"
  hashes="$(awk -v name="$archive" '$2 == name || $2 == "*" name { print tolower($1) }' "$checksum_file")"
  [[ "$(wc -l <<< "$hashes" | tr -d ' ')" == 1 ]] \
    || die "checksums file must contain exactly one SHA-256 entry for ${archive}"
  sha256="${hashes//$'\n'/}"
  [[ "$sha256" =~ ^[[:xdigit:]]{64}$ ]] || die "invalid SHA-256 entry for ${archive}"

  cache_key="datatug-cli-${tag}-${RUNNER_OS}-${RUNNER_ARCH}-${sha256}"
  {
    printf 'tag=%s\n' "$tag"
    printf 'version=%s\n' "$version"
    printf 'archive=%s\n' "$archive"
    printf 'sha256=%s\n' "$sha256"
    printf 'cache-key=%s\n' "$cache_key"
  } >> "$GITHUB_OUTPUT"
  printf 'Resolved DataTug %s for %s/%s\n' "$tag" "$DATATUG_OS" "$DATATUG_ARCH"
)

download_archive() {
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  : "${DATATUG_RELEASE_TAG:?DATATUG_RELEASE_TAG is required}"
  : "${DATATUG_ARCHIVE:?DATATUG_ARCHIVE is required}"
  [[ "$DATATUG_RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'release tag is not a stable semantic version'
  [[ "$DATATUG_ARCHIVE" =~ ^datatug_[0-9]+\.[0-9]+\.[0-9]+_(linux|darwin)_(amd64|arm64)\.tar\.gz$ ]] \
    || die 'archive name is invalid'

  local archive_path
  archive_path="$(archive_path_for "$DATATUG_ARCHIVE")"
  mkdir -p "$(dirname "$archive_path")"
  curl --fail --silent --show-error --location --output "$archive_path" \
    "https://github.com/datatug/datatug/releases/download/${DATATUG_RELEASE_TAG}/${DATATUG_ARCHIVE}"
}

archive_path_for() {
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  : "${1:?archive name is required}"
  printf '%s/datatug-cli-cache/%s\n' "$RUNNER_TEMP" "$1"
}

verify_archive() {
  : "${DATATUG_ARCHIVE:?DATATUG_ARCHIVE is required}"
  : "${DATATUG_EXPECTED_SHA256:?DATATUG_EXPECTED_SHA256 is required}"
  [[ "$DATATUG_ARCHIVE" =~ ^datatug_[0-9]+\.[0-9]+\.[0-9]+_(linux|darwin)_(amd64|arm64)\.tar\.gz$ ]] \
    || die 'archive name is invalid'
  [[ "$DATATUG_EXPECTED_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || die 'expected SHA-256 is invalid'

  local archive_path actual expected
  archive_path="$(archive_path_for "$DATATUG_ARCHIVE")"
  [[ -f "$archive_path" ]] || die "CLI archive is missing at ${archive_path}"
  actual="$(sha256_file "$archive_path")"
  expected="$(tr '[:upper:]' '[:lower:]' <<< "$DATATUG_EXPECTED_SHA256" | tr -d '\n')"
  [[ "$actual" == "$expected" ]] \
    || die "CLI archive checksum mismatch for ${DATATUG_ARCHIVE}"
}

install_cli() {
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  : "${DATATUG_ARCHIVE:?DATATUG_ARCHIVE is required}"
  : "${DATATUG_EXPECTED_VERSION:?DATATUG_EXPECTED_VERSION is required}"
  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
  : "${GITHUB_PATH:?GITHUB_PATH is required}"

  local archive_path install_dir executable version_json reported_version
  archive_path="$(archive_path_for "$DATATUG_ARCHIVE")"
  install_dir="${RUNNER_TEMP}/datatug-cli/bin"
  executable="${install_dir}/datatug"
  mkdir -p "$install_dir"
  tar -xzf "$archive_path" -C "$install_dir" datatug \
    || die 'verified CLI archive does not contain the datatug executable at its root'
  chmod 0755 "$executable"

  version_json="$("$executable" version --json)" || die 'installed DataTug CLI could not report its version'
  reported_version="$(jq -er '.version' <<< "$version_json")" || die 'CLI version output has no version field'
  [[ "$reported_version" == "$DATATUG_EXPECTED_VERSION" ]] \
    || die "installed CLI reports ${reported_version}; expected ${DATATUG_EXPECTED_VERSION}"
  printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
  {
    printf 'path=%s\n' "$executable"
    printf 'version=%s\n' "$reported_version"
  } >> "$GITHUB_OUTPUT"
  printf 'Installed verified DataTug CLI %s\n' "$reported_version"
}

validate_project() {
  : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
  : "${DATATUG_CLI:?DATATUG_CLI is required}"
  local workspace project_dir
  workspace="$(cd "$GITHUB_WORKSPACE" && pwd -P)"
  if [[ -z "${DATATUG_PROJECT_DIR:-}" ]]; then
    project_dir="$workspace"
  else
    [[ "$DATATUG_PROJECT_DIR" != /* ]] || die 'project directory must be relative to GITHUB_WORKSPACE'
    project_dir="$(cd "$workspace/$DATATUG_PROJECT_DIR" && pwd -P)" \
      || die "project directory does not exist: ${DATATUG_PROJECT_DIR}"
  fi
  case "$project_dir" in
    "$workspace"|"$workspace"/*) ;;
    *) die 'project directory resolves outside GITHUB_WORKSPACE' ;;
  esac
  "$DATATUG_CLI" validate "-d=${project_dir}"
}

resolve_project_dir() {
  : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
  local workspace project_dir
  workspace="$(cd "$GITHUB_WORKSPACE" && pwd -P)"
  if [[ -z "${DATATUG_PROJECT_DIR:-}" ]]; then
    project_dir="$workspace"
  else
    [[ "$DATATUG_PROJECT_DIR" != /* ]] || die 'project directory must be relative to GITHUB_WORKSPACE'
    project_dir="$(cd "$workspace/$DATATUG_PROJECT_DIR" && pwd -P)" \
      || die 'project directory does not exist'
  fi
  case "$project_dir" in
    "$workspace"|"$workspace"/*) ;;
    *) die 'project directory resolves outside GITHUB_WORKSPACE' ;;
  esac
  printf '%s\n' "$project_dir"
}

check_run() (
  : "${DATATUG_CLI:?DATATUG_CLI is required}"
  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
  : "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  [[ "${DATATUG_LOCAL_OWNER:-}" == true ]] || die 'checks mode requires explicit local-owner consent'
  [[ -z "${DATATUG_ENDPOINT:-}" ]] || die 'execution endpoint is not supported by this Action version'
  [[ "${DATATUG_ENVIRONMENT:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
    || die 'environment must be a name containing letters, digits, dot, underscore, or hyphen'
  [[ "${DATATUG_TIMEOUT:-}" =~ ^(0|[1-9][0-9]{0,3})(s|m)$ ]] \
    || die 'timeout must be from 1s through 3600s or 1m through 60m'
  local timeout_value="${BASH_REMATCH[1]}" timeout_unit="${BASH_REMATCH[2]}" timeout_seconds
  timeout_seconds="$timeout_value"
  [[ "$timeout_unit" == s ]] || timeout_seconds=$((timeout_value * 60))
  if ((timeout_seconds < 1 || timeout_seconds > 3600)); then
    die 'timeout must be from 1s through 3600s or 1m through 60m'
  fi
  [[ "${DATATUG_WARNINGS:-}" == fail || "${DATATUG_WARNINGS:-}" == ignore ]] \
    || die 'warnings must be fail or ignore'
  [[ -n "${DATATUG_CHECKS:-}" ]] || die 'at least one named Check is required'

  local project_dir evidence_dir raw_file safe_file cli_status item check_count=0 seen_checks=' '
  project_dir="$(resolve_project_dir)"
  evidence_dir="$(mktemp -d "${RUNNER_TEMP%/}/datatug-evidence.XXXXXXXX")"
  chmod 700 "$evidence_dir"
  raw_file="$evidence_dir/child-output.json"
  safe_file="$evidence_dir/result.json"
  local -a args=(checks run --project "$project_dir" --env "$DATATUG_ENVIRONMENT")
  while IFS= read -r item || [[ -n "$item" ]]; do
    [[ -n "$item" ]] || continue
    [[ "$item" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || die 'Check IDs must be simple named identifiers'
    [[ "$seen_checks" != *" $item "* ]] || die 'duplicate Check IDs are not allowed'
    seen_checks+="$item "
    check_count=$((check_count + 1))
    ((check_count <= 100)) || die 'no more than 100 Checks may be run in one Action invocation'
    args+=(--check "$item")
  done <<< "$DATATUG_CHECKS"
  [[ "${#args[@]}" -gt 7 ]] || die 'at least one named Check is required'
  args+=(--local-owner --evidence-dir "$evidence_dir" --timeout "$DATATUG_TIMEOUT" --warnings "$DATATUG_WARNINGS" --format json)

  set +e
  python3 - "$DATATUG_TIMEOUT" "$raw_file" "$DATATUG_CLI" "${args[@]}" <<'PY'
import subprocess
import sys
import os
import selectors
import signal
import time

duration, output, executable, *argv = sys.argv[1:]
unit = duration[-1]
seconds = int(duration[:-1]) * (60 if unit == "m" else 1)
safe_prefix = '{"schemaVersion":"datatug.checks.run/v1","status":"%s","exitCode":%d,"checks":[],"deepLink":"https://datatug.app","deepLinkReason":"hosted_result_reference_unsupported"}\n'
process = None
class Cancelled(Exception):
    pass

def on_cancel(_signal, _frame):
    raise Cancelled

signal.signal(signal.SIGINT, on_cancel)
signal.signal(signal.SIGTERM, on_cancel)

def stop_process():
    if process is not None and process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

try:
    child_env = os.environ.copy()
    child_env["DATATUG_TELEMETRY"] = "0"
    child_env["DATATUG_CLIENT"] = ""
    process = subprocess.Popen([executable, *argv], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               start_new_session=True, env=child_env)
    deadline = time.monotonic() + seconds
    captured = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                stop_process()
                raise TimeoutError
            events = selector.select(remaining)
            if not events:
                stop_process()
                raise TimeoutError
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            if len(captured) + len(chunk) > 1024 * 1024:
                stop_process()
                with open(output, "w", encoding="utf-8") as stream:
                    stream.write(safe_prefix % ("error", 4))
                raise SystemExit(4)
            captured.extend(chunk)
    try:
        child_status = process.wait(timeout=max(0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        stop_process()
        raise TimeoutError
except TimeoutError:
    with open(output, "w", encoding="utf-8") as stream:
        stream.write(safe_prefix % ("timeout", 124))
    raise SystemExit(124)
except Cancelled:
    stop_process()
    if process is not None:
        process.wait()
    with open(output, "w", encoding="utf-8") as stream:
        stream.write(safe_prefix % ("cancelled", 130))
    raise SystemExit(130)
with open(output, "wb") as stream:
    stream.write(captured)
raise SystemExit(child_status)
PY
  cli_status=$?
  set -e

  # Reconstruct an allowlisted envelope and enforce the documented status/exit mapping.
  jq -e --argjson code "$cli_status" --argjson expected_checks "$check_count" --arg warnings "$DATATUG_WARNINGS" '
    .schemaVersion == "datatug.checks.run/v1" and
    (.status | IN("pass","fail","warning","unknown","error","timeout","cancelled","configuration_error","access_denied","not_found")) and
    (.exitCode | type == "number" and . == $code) and
    (.status as $s | if $s == "warning" then .exitCode == (if $warnings == "ignore" then 0 else 1 end) else .exitCode == ({"pass":0,"fail":1,"unknown":1,"configuration_error":2,"not_found":3,"error":4,"timeout":124,"cancelled":130,"access_denied":5}[$s]) end) and
    (.status as $s | if (["pass","fail","warning","unknown"] | index($s)) != null then (.checks | length == $expected_checks) else (.checks | length <= $expected_checks) end) and
    (.checks | type == "array" and all(.[];
      (.index | type == "number" and . >= 1) and
      (.status | IN("pass","fail","warning","unknown","error","timeout","cancelled","configuration_error","access_denied","not_found")) and
      (.executionStatus | IN("completed","error","skipped","pending","running")) and
      (.outcome | IN("pass","fail","unknown")) and
      (.severity | IN("","info","warning","error","critical")) and
      (.durationMs | type == "number" and . >= 0)
    )) and
    .deepLink == "https://datatug.app" and .deepLinkReason == "hosted_result_reference_unsupported"
  ' "$raw_file" >/dev/null 2>/dev/null || die 'CLI returned an invalid or inconsistent safe result envelope'
  jq -c '{schemaVersion,status,exitCode,checks:[.checks[] | {index,status,executionStatus,outcome,severity,durationMs}],deepLink,deepLinkReason}' \
    "$raw_file" > "$safe_file" 2>/dev/null || die 'CLI returned an invalid or inconsistent safe result envelope'
  chmod 600 "$raw_file" "$safe_file"

  local status exit_code
  status="$(jq -r .status "$safe_file")"
  exit_code="$(jq -r .exitCode "$safe_file")"
  {
    printf 'status=%s\n' "$status"
    printf 'exit-code=%s\n' "$exit_code"
    printf 'result-json=%s\n' "$(cat "$safe_file")"
  } >> "$GITHUB_OUTPUT"
  # shellcheck disable=SC2016 # Backticks are Markdown code delimiters, not shell substitutions.
  {
    printf '## DataTug Checks: `%s`\n\n' "$status"
    printf 'Environment: `%s`  \nChecks run: %s\n\n' \
      "$DATATUG_ENVIRONMENT" "$(jq '.checks | length' "$safe_file")"
    printf 'Hosted result references are not supported for private CI evidence. [Open DataTug.app](https://datatug.app)\n'
  } >> "$GITHUB_STEP_SUMMARY"
  exit "$exit_code"
)

validate_mode() {
  case "${DATATUG_MODE:-validate}" in
    validate|checks) ;;
    *) die 'mode must be validate or checks' ;;
  esac
}

case "${1:-}" in
  resolve) resolve_release ;;
  download) download_archive ;;
  verify) verify_archive ;;
  install) install_cli ;;
  validate) validate_project ;;
  checks) check_run ;;
  mode) validate_mode ;;
  *) die 'usage: datatug-cli.sh {resolve|download|verify|install|validate|checks}' ;;
esac
