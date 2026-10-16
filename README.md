# DataTug GitHub Action

Install the latest stable DataTug CLI release, verify its checksum, and run the
project validator. The action caches the release archive by version, runner
platform, and the SHA-256 published with that release; cached files are checked
again before installation.

```yaml
permissions:
  contents: read

steps:
  - uses: actions/checkout@v6
  - uses: datatug/datatug-action@<full-commit-sha>
    with:
      dir: demo-project-1
```

The `dir` input is a relative path inside `GITHUB_WORKSPACE`; it defaults to the
workspace root. The installed CLI version, executable path, and archive cache
hit are exposed as `version`, `path`, and `cache-hit` action outputs.

The action supports GitHub-hosted Linux and macOS runners on X64 and ARM64.
It resolves the latest stable release once per invocation and verifies the
release checksum on both cache hits and downloads. Pin the action itself to a
full commit SHA when using it in a workflow.
