# Security

## Workflow trust and credentials

Use a full commit SHA for this Action and a minimal workflow permission block.
Do not expose database or DataTug credentials to untrusted pull-request
workflows, forked code, or workflows that check out attacker-controlled
projects. Put credentials in GitHub Secrets and inject only variables required
by trusted project configuration. The Action has no secret-valued inputs and
never places credentials in its CLI argument vector.

The current Checks mode is local execution. It requires the explicit
`local-owner: 'true'` input and passes `--local-owner` to the CLI. This is an
authorization decision, not a claim that GitHub's workflow identity grants a
DataTug policy. Review project configuration and any environment-specific
source settings before running Checks.

## Inputs and subprocess boundary

Action inputs are passed through environment variables, then validated and
converted into fixed CLI argument positions. Check IDs are constrained to a
simple identifier alphabet. Project paths must be relative to the checked-out
workspace; resolved symlinks may not escape it. The optional endpoint is
rejected when nonempty because no supported endpoint contract is implemented.
At most 100 named Check IDs are accepted per invocation, and child telemetry
is disabled through the CLI's environment settings.

The CLI's stdout and stderr are captured privately. The Action accepts only the
documented `datatug.checks.run/v1` result envelope, validates status/exit-code
consistency, and reconstructs an allowlisted JSON value before writing action
outputs. Captured stdout is limited to 1 MiB; stderr is discarded. It does not
print child errors or raw output. Raw evidence and captured output are held
under a mode-0700 directory in `RUNNER_TEMP`; no automatic artifact upload is
performed. Runner administrators and later steps in the same job remain within
the runner trust boundary.

## Data and links

Check rows, SQL, inputs, credentials, local paths, and raw execution errors are
not included in the Action summary or result output. Links currently point to
the DataTug app home because a hosted result reference for private CI evidence
is not supported. The Action does not upload private evidence to DataTug.app.

Report security issues privately to the repository maintainers rather than
opening a public issue containing credentials or customer data.
