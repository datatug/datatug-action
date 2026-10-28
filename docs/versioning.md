# Action versioning

Action tags version the Action metadata and runtime, independently of the CLI.
Exact `vX.Y.Z` tags are immutable. Consumer and demo workflows pin exact versions
or reviewed full SHAs; `main` is a development reference.

The owner-authorized initial test tag is `v0.0.1`. It is created explicitly after
review and passing CI; automatic tagging refuses to invent an initial baseline.
Action `v1.0.0` remains the target for Marketplace launch, subject to the separate
interface and release gates. No moving major tag is created by this automation.

## Automatic tags

The `Test` workflow's tagging job runs only on a push to this repository's
`main`, after both the release/cache fixtures and real demo validation succeed.
Pull requests, forks and manual workflow runs cannot publish tags. Only this
job receives `contents: write`; its checkout does not persist credentials.

The planner compares the tested commit's tree against the highest exact stable
version tag. A change to either Action metadata file (`action.yml` or
`action.yaml`) or `scripts/datatug-cli.sh` is a runtime change. When adding runtime
files, extend `RUNTIME_PATHS` in `scripts/plan-action-tag.py` in the same change.
Those paths are the current runtime entry points, not a general repository filter.

Changes only to README/docs, tests, CI, Renovate, or internal release helpers
create no tag. A changed file must still differ from the previous release;
changes reverted before tagging create no tag.

- A runtime-touching `feat:` or `feat(scope):` commit since the previous tag increments the minor
  version and resets the patch to zero.
- Other runtime changes increment the patch, including changes without a
  Conventional Commit prefix.
- A declared breaking change (`!:` or a `BREAKING CHANGE:` footer) stops tagging.
  Review compatibility and select the next version explicitly. Automatic tagging
  never increments the major version.

Serialize tag jobs so they observe tags published by earlier jobs. A repeated
completion for the already tagged commit is a no-op. If a newer tagged commit
is no longer an ancestor of an older candidate, skip that stale candidate.
Create the new ref using the GitHub API at the exact tested SHA; never update,
delete or force an existing ref. Any creation conflict fails rather than moving
a version. A later internal-only commit may tag previously untagged runtime
changes since the baseline, after its own CI passes.

This job creates **Git tags only**. It does not create a GitHub Release, publish
an Action Marketplace listing, advance a moving `v1` alias, release the CLI, or
enable hosted result uploads. The built-in token's tag event does not launch
another push-triggered workflow; no downstream publication is assumed.

Pinning the Action does not pin the CLI downloaded by the current validator:
it selects the latest stable CLI. Explicit CLI version selection is part of the
separately held Everywhere candidate.
