# DataTug GitHub Action

**Make DataTug project validation part of every pull request.**

Keep your DataTug project alongside your code and validate changes in GitHub
Actions. Add one reusable step: the Action installs the DataTug CLI, verifies
the release checksum and runs the project validator for you.

[Get started](#get-started) · [See a demo](https://github.com/datatug/datatug-demo-project/blob/main/.github/workflows/datatug.yml) · [Explore DataTug.app](https://datatug.app)

## Why use it?

- **Review project changes with your code.** Run validation on pushes and pull
  requests, with the outcome visible in your existing GitHub workflow.
- **Skip the installation script.** Resolve the latest stable CLI release,
  install it and reuse the executable in subsequent steps.
- **Reuse verified downloads.** Release archives are cached by version, runner
  platform and published SHA-256, then checked again before installation.
- **Choose your project.** Validate the checkout root or a folder within it.
  GitHub-hosted Linux and macOS runners are supported on X64 and ARM64.

## Get started

Add `.github/workflows/datatug.yml` to a repository containing a DataTug project:

```yaml
name: Validate DataTug project

on: [push, pull_request, workflow_dispatch]

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: datatug/datatug-action@v0.0.1
        with:
          dir: demo-project-1
```

Replace `demo-project-1` with your project folder, or omit `dir` to validate the
repository root. The path must be relative to `GITHUB_WORKSPACE`.

**Want a working example?** Explore the maintained
[DataTug demo project](https://github.com/datatug/datatug-demo-project), which pins
an exact Action version so cloned workflows do not follow changes to `main`. The
older Chinook demo is archived; use the maintained project for current examples. If your
project needs local fixtures, prepare them before validation, as shown in the
[Action's demo acceptance workflow](.github/workflows/test.yml).

## From project validation to data Checks

**Available behavior:** install a checksum-verified CLI and validate a DataTug
project. Project validation does not establish that your data satisfies a Check.

**In preparation:** run named DataTug Checks against a selected environment,
report pass/fail and a concise job summary, and control timeouts and warning
handling. These additions are being tested in the
[Everywhere release candidate](https://github.com/datatug/datatug-action/pull/3)
and require a supporting CLI release. They are not part of Action `v0.0.1`.

For example, a Checks workflow could verify that invoices reconcile or that
accounts have an owner, then report the outcome where your team already reviews
changes. Keep detailed investigation in [DataTug.app](https://datatug.app).
Optional hosted summary links are also in preparation; they require a separately
enabled hosted service and explicit upload consent. Upload is off by default
in the candidate and is not included in `v0.0.1`.

## Inputs and outputs

The validator Action has one input:

| Input | Purpose | Default |
| --- | --- | --- |
| `dir` | Relative path to the DataTug project inside the checkout | Workspace root |

Give the Action step an `id` to use its outputs in later steps:

| Output | Value |
| --- | --- |
| `version` | Installed DataTug CLI version |
| `path` | Absolute path to the installed executable |
| `cache-hit` | Whether the verified archive was restored from cache |

## Choose when to update

Use an exact Action tag, such as `@v0.0.1`, to update deliberately. For stronger
control, pin its reviewed full commit SHA. `@main` follows ongoing development
and is not recommended for cloned demo or production workflows.

**The Action and CLI have separate versions.** Freezing the Action revision
does not freeze its downloaded CLI: this validator Action resolves the latest
stable CLI on each run. Explicit CLI version selection is in preparation.

After successful CI on `main`, changes to `action.yml` or the runtime
`scripts/datatug-cli.sh` receive an immutable version tag. Documentation,
tests, Renovate configuration and release helpers alone create no tag.
Features use a minor increment; other behavioral changes use a patch increment.
Declared breaking changes require an explicit release decision. See the
[tagging policy](docs/versioning.md).

`v0.0.1` is the initial test version. **Action `v1.0.0` remains the target for
the public Marketplace launch**, after interface and release acceptance. That
launch and a moving `v1` tag are separate from automatic exact-version tags.

## Run with appropriate permissions

Start with `contents: read`, as in the example. Keep database credentials in
GitHub Secrets and expose them only to trusted jobs that need them. Never give
untrusted pull-request code access to credentials.

Checksum verification checks that an archive matches the digest published with
its release; it does not independently establish publisher identity. Review
the Action revision and CLI releases you allow your workflows to execute.

## Explore and contribute

- [Browse the CLI source](https://github.com/datatug/datatug-cli) and
  [published downloads](https://github.com/datatug/datatug/releases).
- [Try a demo project](https://github.com/datatug/datatug-demo-project).
- [Report a bug or request a feature](https://github.com/datatug/datatug-action/issues).
  Report security issues privately to the maintainers; do not put credentials
  or customer data in a public issue.

**Start with one validation step. Give every project change a CI check.**
