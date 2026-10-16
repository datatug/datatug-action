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

  local temp_dir release_json tag version archive checksums release_url checksum_file hashes sha256 cache_key
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  release_json="$temp_dir/release.json"
  checksum_file="$temp_dir/checksums.txt"

  curl --fail --silent --show-error --output "$release_json" \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: Bearer ${DATATUG_GITHUB_TOKEN}" \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    https://api.github.com/repos/datatug/datatug/releases/latest

  tag="$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' "$release_json")" \
    || die 'latest DataTug release metadata is missing a stable tag'
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected latest stable release tag '${tag}'"
  version="${tag#v}"
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

case "${1:-}" in
  resolve) resolve_release ;;
  download) download_archive ;;
  verify) verify_archive ;;
  install) install_cli ;;
  validate) validate_project ;;
  *) die 'usage: datatug-cli.sh {resolve|download|verify|install|validate}' ;;
esac
