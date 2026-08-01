# Automatic Stable Tagging Design

## Context

Stable image builds and GitHub Releases already run from `v*` tag pushes. The
current workflow is reliable, but creating the tag is still a manual step. The
stable add-on version is declared in `ha_opencode/config.yaml`, and
`scripts/apply-plus.sh` is responsible for producing the OpenCode+ version
format, such as `2.4.0.1`.

The repository also has a scheduled upstream synchronization workflow. That
workflow uses the `SYNC_TOKEN` repository secret because it may push workflow
files and must therefore be able to trigger downstream Actions workflows.

## Goals

- Create stable release tags automatically when the stable version changes on
  `main`.
- Preserve the existing tag-triggered stable build and release workflows.
- Avoid duplicate tags, duplicate releases, and release loops.
- Fail safely when a version is invalid or a version tag already belongs to a
  different release.
- Require no manual release command for normal version changes.

## Non-Goals

- Automatically deciding or incrementing versions.
- Changing beta release behavior.
- Replacing the existing stable build or GitHub Release workflows.
- Moving or rewriting an existing Git tag.

## Design

Add `.github/workflows/auto-tag-stable.yml`, a dedicated workflow with this
trigger:

```yaml
on:
  push:
    branches: [main]
    paths:
      - ha_opencode/config.yaml
```

The workflow checks out the repository with `SYNC_TOKEN`, reads the version
from `ha_opencode/config.yaml`, and validates it as a numeric dotted version
with at least three components. It then builds the tag name `v<version>`.

### Version-change detection

The workflow compares the current version with the version in the commit
before the push. If the version did not change, it exits successfully without
creating a tag. This handles config-only corrections made by the release
workflow after a tag has already been created.

If the push has no usable parent commit, the workflow treats the current
version as changed and continues through the normal tag-existence checks.

### Tag creation

The tag handling is idempotent so a workflow rerun is safe:

1. Check the remote for `v<version>`.
2. If the tag does not exist and the version changed, create it at `GITHUB_SHA`
   and push it with `SYNC_TOKEN`.
3. If the tag exists at `GITHUB_SHA`, exit successfully. This covers a rerun
   after the tag push succeeded.
4. If the tag exists at another commit and the version did not change in this
   push, exit successfully because the config-only change does not represent a
   new release.
5. If the tag exists at another commit and the version did change in this
   push, fail without moving the tag and open one issue describing the
   collision.

The workflow must never force-update or delete tags. The issue step should be
idempotent so repeated runs do not create duplicate issues.

### Authentication

The workflow uses the existing `SYNC_TOKEN` repository secret for checkout and
tag pushes. This is required because a tag pushed with the default
`GITHUB_TOKEN` does not trigger another Actions workflow. The token is passed
through Actions inputs/environment variables and is never printed.

The workflow keeps the default token's `issues: write` permission for collision
issues but does not rely on it for the tag push.

### Existing release pipeline

No changes are required to the stable build or release workflows:

- Pushing `v<version>` triggers `.github/workflows/build.yaml`.
- The build publishes `amd64` and `aarch64` images and then creates the
  multi-architecture GHCR manifest.
- `.github/workflows/release.yaml` creates the stable GitHub Release and
  updates stable metadata when necessary.
- The build workflow uploads the image manifest assets to the created Release.

The automatic tagging workflow only creates the trigger tag. The existing
release validation remains responsible for ensuring that stable tags are based
on `main` and do not publish a downgrade.

## Failure Handling

- Missing `SYNC_TOKEN`: fail with an actionable error before checkout/push.
- Invalid or empty version: fail without creating a tag.
- Existing tag at the current commit: succeed as a no-op.
- Existing tag at another commit after an unchanged version: succeed as a
  no-op.
- Existing tag at another commit after a newly changed version: fail, preserve
  the existing tag, and open one manual-resolution issue.
- Tag push failure: fail the workflow; rerunning the failed job after the cause
  is fixed is safe.
- Expired or revoked `SYNC_TOKEN`: sync and automatic tagging both stop until
  the repository secret is rotated.

## Testing and Verification

- Parse the new workflow as YAML.
- Extend the workflow regression checks to cover the branch/path trigger,
  version validation, `SYNC_TOKEN` usage, no-op behavior, and non-force tag
  creation.
- Run shell syntax checks for any embedded scripts.
- Verify an unchanged version does not create a tag.
- Verify a new version creates exactly one tag.
- Verify an existing tag is never moved.
- Confirm the existing stable build and release workflows remain triggered by
  `v*` tags.

## Rollout

The workflow will be added to `main`. The existing `v2.4.0.1` tag and Release
remain unchanged. The first production validation will occur on the next
stable version change made on `main`; no additional release command should be
needed.
