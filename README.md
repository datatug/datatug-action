# DataTug GitHub Action

The composite Action installs a checksum-verified DataTug CLI release and can
validate a project or run named DataTug Checks. The default `mode: validate`
preserves the original validator behavior. The checks mode uses the local
execution path and requires explicit `local-owner: 'true'` consent.

Pin this Action to a full commit SHA and grant only the permissions needed by
your workflow:

```yaml
permissions:
  contents: read

steps:
  - uses: actions/checkout@v6
  - uses: datatug/datatug-action@<full-commit-sha>
    with:
      dir: demo-project
```

`dir` is relative to `GITHUB_WORKSPACE`, defaults to its root, and is checked
after resolving symlinks so it cannot escape the checked-out workspace. The
CLI defaults to the latest stable release. Set `version: 1.2.3` to resolve a
specific stable semantic version; invalid versions are rejected before any
network request. The archive checksum is verified on cache hits and downloads.

## Run Checks

Checks mode requires a CLI release containing `checks run`. This draft is tested against a candidate build; the existing public CLI release is not claimed to provide this new command. Pin a verified supporting release once publication is approved.

Checks mode requires a project configuration that already provides its
environment and any needed credentials through the CLI's supported local
configuration. Store credentials in GitHub Secrets and expose only the
specific variables your project configuration expects. Never pass credentials
as Action inputs or command-line arguments. Do not expose secrets to workflows
that run untrusted pull-request code.

```yaml
permissions:
  contents: read

steps:
  - uses: actions/checkout@v6
  - uses: datatug/datatug-action@<full-commit-sha>
    env:
      # Example only: use the variable name required by your DataTug config.
      DATABASE_PASSWORD: ${{ secrets.DATABASE_PASSWORD }}
    with:
      mode: checks
      dir: demo-project
      environment: ci
      checks: |
        invoices-reconcile
        accounts-have-owner
      local-owner: 'true'
      timeout: 30s
      warnings: fail
```

`checks` is a newline-separated list of named Check IDs. Each ID is passed as a
separate argument without shell evaluation. `environment` must be a named
environment. `local-owner: 'true'` is a deliberate authorization to execute
locally with the CLI's local-owner admission path; a GitHub identity alone is
not this consent. `timeout` accepts 1–3600 seconds or 1–60 minutes. Up to 100
named Checks may be selected per invocation. `warnings` is
`fail` or `ignore`.

An optional `endpoint` input is reserved for a future supported execution
endpoint. Any nonempty value currently fails with an explicit unsupported
endpoint error; the Action does not silently route to local owner execution.

The Action emits the safe Checks status, exit code, and a sanitized JSON result
envelope as outputs. Its job summary includes the status and check count. Exit
codes distinguish business failure/unknown (1), configuration error (2),
missing resource (3), execution error (4), access denied (5), timeout (124),
and cancellation (130). A result reference currently opens only
`https://datatug.app`; hosted result pages for private CI evidence are not yet
supported. Raw evidence remains in a private runner temporary directory and is
never uploaded as an artifact.

See [SECURITY.md](SECURITY.md) for the trust and data-handling boundaries.
The Action supports GitHub-hosted Linux and macOS runners on X64 and ARM64.
