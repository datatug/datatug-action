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
  checks)
    printf '%s\n' "$@" >> "$DATATUG_CHECK_ARGS_LOG"
    printf '%s|%s\n' "${DATATUG_TELEMETRY:-unset}" "${DATATUG_CLIENT+x}" >> "$DATATUG_CHECK_ENV_LOG"
    trap '[[ -n "${DATATUG_TERM_MARKER:-}" ]] && touch "$DATATUG_TERM_MARKER"; exit 143' TERM
    if [[ "${DATATUG_CHECK_FIXTURE:-}" == hang-after-stdout ]]; then
      cat "$DATATUG_CHECK_HANG_FIXTURE"
      exec 1>&-
      sleep 3
      exit 0
    fi
    if [[ "${DATATUG_CHECK_FIXTURE:-}" == timeout ]]; then sleep 3; fi
    cat "$DATATUG_CHECK_FIXTURE"
    exit "${DATATUG_CHECK_EXIT:-0}"
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
if [[ "$url" == https://api.github.com/repos/datatug/datatug/releases/latest || \
      "$url" == https://api.github.com/repos/datatug/datatug/releases/tags/v1.2.3 ]]; then
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
if DATATUG_MODE=checks-v2 "$script_dir/datatug-cli.sh" mode >/dev/null 2>&1; then
  echo 'invalid operation mode unexpectedly passed' >&2
  exit 1
fi

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

: > "$CURL_LOG"
release_output="$temp_dir/release-pinned.out"
RUNNER_OS=Linux RUNNER_ARCH=X64 DATATUG_CLI_VERSION=1.2.3 GITHUB_OUTPUT="$release_output" \
  "$script_dir/datatug-cli.sh" resolve
grep -Fx 'version=1.2.3' "$release_output" >/dev/null
[[ "$(head -n 1 "$CURL_LOG")" == api ]] || { echo 'pinned version did not resolve from release metadata' >&2; exit 1; }

: > "$CURL_LOG"
if RUNNER_OS=Linux RUNNER_ARCH=X64 DATATUG_CLI_VERSION='1.2.3;touch /tmp/bad' GITHUB_OUTPUT="$temp_dir/bad-version.out" \
  "$script_dir/datatug-cli.sh" resolve >"$temp_dir/bad-version.stdout" 2>"$temp_dir/bad-version.stderr"; then
  echo 'invalid CLI version unexpectedly resolved' >&2
  exit 1
fi
[[ ! -s "$CURL_LOG" ]] || { echo 'invalid CLI version reached network' >&2; exit 1; }

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

check_fixture="$temp_dir/check-result.json"
cat > "$check_fixture" <<'JSON'
{"schemaVersion":"datatug.checks.run/v1","status":"pass","exitCode":0,"checks":[{"index":1,"status":"pass","executionStatus":"completed","outcome":"pass","severity":"","durationMs":12},{"index":2,"status":"pass","executionStatus":"completed","outcome":"pass","severity":"","durationMs":8}],"deepLink":"https://datatug.app","deepLinkReason":"hosted_result_reference_unsupported"}
JSON
check_args_log="$temp_dir/check-args.log"
export DATATUG_CHECK_FIXTURE="$check_fixture" DATATUG_CHECK_ARGS_LOG="$check_args_log"
checks_output="$temp_dir/checks.out"
checks_summary="$temp_dir/checks.summary"
checks_env=(DATATUG_CLI="$cli_path" DATATUG_PROJECT_DIR='demo project' DATATUG_ENVIRONMENT=ci-prod \
  DATATUG_CHECKS=$'invoice.reconcile\nchecks.run' DATATUG_LOCAL_OWNER=true DATATUG_TIMEOUT=30s \
  DATATUG_WARNINGS=fail DATATUG_ENDPOINT= GITHUB_WORKSPACE="$workspace" RUNNER_TEMP="$RUNNER_TEMP" \
  DATATUG_CHECK_ARGS_LOG="$check_args_log" DATATUG_CHECK_ENV_LOG="$temp_dir/check-env.log" \
  DATATUG_TERM_MARKER="$temp_dir/term-received" \
  GITHUB_OUTPUT="$checks_output" GITHUB_STEP_SUMMARY="$checks_summary")
env "${checks_env[@]}" "$script_dir/datatug-cli.sh" checks
grep -Fx 'status=pass' "$checks_output" >/dev/null
grep -F 'invoice.reconcile' "$check_args_log" >/dev/null
grep -Fx -- '--env' "$check_args_log" >/dev/null
grep -Fx 'ci-prod' "$check_args_log" >/dev/null
grep -Fx -- '--local-owner' "$check_args_log" >/dev/null
grep -Fx -- '--timeout' "$check_args_log" >/dev/null
grep -Fx '30s' "$check_args_log" >/dev/null
grep -Fx -- '--warnings' "$check_args_log" >/dev/null
grep -Fx -- '--format' "$check_args_log" >/dev/null
grep -Fx '0|x' "$temp_dir/check-env.log" >/dev/null
grep -F 'hosted_result_reference_unsupported' "$checks_output" >/dev/null
grep -F 'Hosted result references are not supported' "$checks_summary" >/dev/null

for bad_case in missing-consent unsupported-endpoint invalid-check invalid-timeout invalid-long-timeout invalid-zero-timeout duplicate-check; do
  case "$bad_case" in
    missing-consent) override=(DATATUG_LOCAL_OWNER=false) ;;
    unsupported-endpoint) override=(DATATUG_ENDPOINT='https://example.test') ;;
    invalid-check) override=(DATATUG_CHECKS='ok;touch /tmp/datatug-action-injected') ;;
    invalid-timeout) override=(DATATUG_TIMEOUT=forever) ;;
    invalid-long-timeout) override=(DATATUG_TIMEOUT=61m) ;;
    invalid-zero-timeout) override=(DATATUG_TIMEOUT=0s) ;;
    duplicate-check) override=(DATATUG_CHECKS=$'same\nsame') ;;
  esac
  if env "${checks_env[@]}" "${override[@]}" GITHUB_OUTPUT="$temp_dir/$bad_case.out" \
    GITHUB_STEP_SUMMARY="$temp_dir/$bad_case.summary" "$script_dir/datatug-cli.sh" checks \
    >"$temp_dir/$bad_case.stdout" 2>"$temp_dir/$bad_case.stderr"; then
    echo "$bad_case unexpectedly succeeded" >&2
    exit 1
  fi
done
many_checks="$(python3 -c 'print(chr(10).join("check%d" % i for i in range(101)))')"
if env "${checks_env[@]}" DATATUG_CHECKS="$many_checks" GITHUB_OUTPUT="$temp_dir/too-many.out" \
  GITHUB_STEP_SUMMARY="$temp_dir/too-many.summary" "$script_dir/datatug-cli.sh" checks \
  >"$temp_dir/too-many.stdout" 2>"$temp_dir/too-many.stderr"; then
  echo 'more than 100 Check IDs unexpectedly succeeded' >&2
  exit 1
fi
[[ ! -e /tmp/datatug-action-injected ]] || { echo 'Check input escaped argv boundary' >&2; exit 1; }

cat > "$temp_dir/malicious.json" <<'JSON'
{"schemaVersion":"datatug.checks.run/v1","status":"pass","exitCode":0,"checks":[{"index":1,"status":"pass\n::warning::secret","executionStatus":"completed","outcome":"pass","severity":"","durationMs":1}],"deepLink":"https://datatug.app","deepLinkReason":"hosted_result_reference_unsupported","secret":"never-print-me"}
JSON
if env "${checks_env[@]}" DATATUG_CHECK_FIXTURE="$temp_dir/malicious.json" GITHUB_OUTPUT="$temp_dir/malicious.out" \
  GITHUB_STEP_SUMMARY="$temp_dir/malicious.summary" "$script_dir/datatug-cli.sh" checks \
  >"$temp_dir/malicious.stdout" 2>"$temp_dir/malicious.stderr"; then
  echo 'malicious child envelope unexpectedly succeeded' >&2
  exit 1
fi
if grep -R 'never-print-me\|secret' "$temp_dir/malicious.stdout" "$temp_dir/malicious.stderr" >/dev/null; then
  echo 'child output or error leaked into action-visible output' >&2
  exit 1
fi

cat > "$temp_dir/extra-field.json" <<'JSON'
{"schemaVersion":"datatug.checks.run/v1","status":"pass","exitCode":0,"checks":[{"index":1,"status":"pass","executionStatus":"completed","outcome":"pass","severity":"","durationMs":1,"privateNested":{"token":"never-print-this-field"}}],"deepLink":"https://datatug.app","deepLinkReason":"hosted_result_reference_unsupported","privateExtra":"never-print-this-field"}
JSON
env "${checks_env[@]}" DATATUG_CHECK_FIXTURE="$temp_dir/extra-field.json" DATATUG_CHECKS=single \
  GITHUB_OUTPUT="$temp_dir/extra-field.out" \
  GITHUB_STEP_SUMMARY="$temp_dir/extra-field.summary" "$script_dir/datatug-cli.sh" checks
if grep -R 'never-print-this-field' "$temp_dir/extra-field.out" "$temp_dir/extra-field.summary" >/dev/null; then
  echo 'unknown top-level or nested child JSON field leaked into action output' >&2
  exit 1
fi

printf '{"schemaVersion":"datatug.checks.run/v1","status":"pass","exitCode":0,"secret":"malformed-private-token-42"' \
  > "$temp_dir/malformed-secret.json"
if env "${checks_env[@]}" DATATUG_CHECK_FIXTURE="$temp_dir/malformed-secret.json" GITHUB_OUTPUT="$temp_dir/malformed-secret.out" \
  GITHUB_STEP_SUMMARY="$temp_dir/malformed-secret.summary" "$script_dir/datatug-cli.sh" checks \
  >"$temp_dir/malformed-secret.stdout" 2>"$temp_dir/malformed-secret.stderr"; then
  echo 'malformed CLI JSON unexpectedly succeeded' >&2
  exit 1
fi
if grep -R 'malformed-private-token-42' "$temp_dir/malformed-secret.stdout" "$temp_dir/malformed-secret.stderr" >/dev/null; then
  echo 'JSON parser diagnostics leaked malformed child output' >&2
  exit 1
fi

env "${checks_env[@]}" GITHUB_OUTPUT="$temp_dir/checks-rerun.out" \
  GITHUB_STEP_SUMMARY="$temp_dir/checks-rerun.summary" "$script_dir/datatug-cli.sh" checks
evidence_arg_lines=()
while IFS= read -r line; do evidence_arg_lines+=("$line"); done \
  < <(grep -n -- '--evidence-dir' "$check_args_log" | cut -d: -f1)
[[ "${#evidence_arg_lines[@]}" == 5 ]] || { echo 'expected evidence paths for all valid CLI invocations' >&2; exit 1; }
first_evidence="$(sed -n "$((evidence_arg_lines[0] + 1))p" "$check_args_log")"
second_evidence="$(sed -n "$((evidence_arg_lines[4] + 1))p" "$check_args_log")"
[[ "$first_evidence" != "$second_evidence" ]] \
  || { echo 'rerun reused the prior evidence directory' >&2; exit 1; }

run_status_case() {
  local case_name="$1" status="$2" code="$3" expected_process="$4"
  local warning_policy=fail
  [[ "$case_name" == check-warning-ignored ]] && warning_policy=ignore
  cat > "$temp_dir/$case_name.json" <<JSON
{"schemaVersion":"datatug.checks.run/v1","status":"$status","exitCode":$code,"checks":[{"index":1,"status":"$status","executionStatus":"completed","outcome":"$([[ "$status" == pass ]] && printf pass || printf fail)","severity":"","durationMs":1}],"deepLink":"https://datatug.app","deepLinkReason":"hosted_result_reference_unsupported"}
JSON
  set +e
  env "${checks_env[@]}" DATATUG_CHECKS=single DATATUG_CHECK_FIXTURE="$temp_dir/$case_name.json" DATATUG_CHECK_EXIT="$code" \
    DATATUG_WARNINGS="$warning_policy" \
    GITHUB_OUTPUT="$temp_dir/$case_name.out" GITHUB_STEP_SUMMARY="$temp_dir/$case_name.summary" \
    "$script_dir/datatug-cli.sh" checks >"$temp_dir/$case_name.stdout" 2>"$temp_dir/$case_name.stderr"
  local actual=$?
  set -e
  [[ "$actual" == "$expected_process" ]] || { echo "$case_name exited $actual, expected $expected_process" >&2; exit 1; }
  grep -Fx "status=$status" "$temp_dir/$case_name.out" >/dev/null
}
run_status_case check-fail fail 1 1
run_status_case check-unknown unknown 1 1
run_status_case check-warning warning 1 1
run_status_case check-warning-ignored warning 0 0
run_status_case check-config configuration_error 2 2
run_status_case check-not-found not_found 3 3
run_status_case check-error error 4 4
run_status_case check-denied access_denied 5 5
run_status_case check-cancelled cancelled 130 130

ln -s "$temp_dir" "$workspace/escape"
if env "${checks_env[@]}" DATATUG_PROJECT_DIR=escape GITHUB_OUTPUT="$temp_dir/escape.out" \
  GITHUB_STEP_SUMMARY="$temp_dir/escape.summary" "$script_dir/datatug-cli.sh" checks \
  >"$temp_dir/escape.stdout" 2>"$temp_dir/escape.stderr"; then
  echo 'project symlink escape unexpectedly succeeded' >&2
  exit 1
fi

set +e
env "${checks_env[@]}" DATATUG_CHECK_FIXTURE=timeout DATATUG_TIMEOUT=1s \
  GITHUB_OUTPUT="$temp_dir/check-timeout.out" GITHUB_STEP_SUMMARY="$temp_dir/check-timeout.summary" \
  "$script_dir/datatug-cli.sh" checks >"$temp_dir/check-timeout.stdout" 2>"$temp_dir/check-timeout.stderr"
timeout_status=$?
set -e
[[ "$timeout_status" == 124 ]] || { echo "timeout case exited $timeout_status, expected 124: $(cat "$temp_dir/check-timeout.stderr")" >&2; exit 1; }
grep -Fx 'status=timeout' "$temp_dir/check-timeout.out" >/dev/null
[[ -e "$temp_dir/term-received" ]] || { echo 'timeout did not give the CLI process group a SIGTERM cleanup opportunity' >&2; exit 1; }

rm -f "$temp_dir/term-received"
set +e
env "${checks_env[@]}" DATATUG_CHECK_FIXTURE=hang-after-stdout DATATUG_CHECK_HANG_FIXTURE="$check_fixture" \
  DATATUG_TIMEOUT=1s GITHUB_OUTPUT="$temp_dir/check-timeout-after-eof.out" \
  GITHUB_STEP_SUMMARY="$temp_dir/check-timeout-after-eof.summary" "$script_dir/datatug-cli.sh" checks \
  >"$temp_dir/check-timeout-after-eof.stdout" 2>"$temp_dir/check-timeout-after-eof.stderr"
after_eof_status=$?
set -e
[[ "$after_eof_status" == 124 ]] || { echo "post-EOF timeout exited $after_eof_status, expected 124" >&2; exit 1; }
grep -Fx 'status=timeout' "$temp_dir/check-timeout-after-eof.out" >/dev/null

if env "${checks_env[@]}" DATATUG_TIMEOUT=60m GITHUB_OUTPUT="$temp_dir/max-timeout.out" \
  GITHUB_STEP_SUMMARY="$temp_dir/max-timeout.summary" "$script_dir/datatug-cli.sh" checks \
  >"$temp_dir/max-timeout.stdout" 2>"$temp_dir/max-timeout.stderr"; then
  grep -Fx 'status=pass' "$temp_dir/max-timeout.out" >/dev/null
else
  echo 'maximum supported timeout unexpectedly failed' >&2
  exit 1
fi

python3 -c 'import sys; sys.stdout.buffer.write(b"x" * (1024 * 1024 + 1))' > "$temp_dir/oversized.json"
set +e
env "${checks_env[@]}" DATATUG_CHECK_FIXTURE="$temp_dir/oversized.json" GITHUB_OUTPUT="$temp_dir/oversized.out" \
  GITHUB_STEP_SUMMARY="$temp_dir/oversized.summary" "$script_dir/datatug-cli.sh" checks \
  >"$temp_dir/oversized.stdout" 2>"$temp_dir/oversized.stderr"
oversized_status=$?
set -e
[[ "$oversized_status" == 4 ]] || { echo "oversized output exited $oversized_status, expected 4" >&2; exit 1; }
grep -Fx 'status=error' "$temp_dir/oversized.out" >/dev/null

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
