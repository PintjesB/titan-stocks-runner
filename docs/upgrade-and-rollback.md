# Upgrade and rollback

The runner version is tracked by the `RUNNER_VERSION` and
`RUNNER_SHA256` pair in `Dockerfile`. Pin both together &mdash;
the runner never self-updates, so the only way to receive a new
release is to publish a fresh image.

## Detecting that an upgrade is due

* The weekly `upstream-check` workflow compares the pinned version
  with the latest `actions/runner` release. When the major or
  minor drifts, it opens a `runner-drift` issue in this repository.
* GitHub ends Actions Runner support 30 days after a new release.
  Plan a tested image release within that window.

## Publishing a new version

1. Update both `ARG RUNNER_VERSION` and `ARG RUNNER_SHA256` in
   `Dockerfile`. Compute the digest with:

   ```bash
   curl --silent --show-error --location \
     "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" \
     | sha256sum
   ```

2. Refresh `PLAYWRIGHT_VERSION` if a Chromium update is needed.
   The capability probe only checks that the version string
   resolves; the application lockfile pins the actual binary used
   in workflow runs.

3. Open a pull request. The hosted `ubuntu-24.04-arm` CI rebuilds
   the real `linux/arm64` image and runs the probe.

4. Merge to `main` &mdash; the `publish` workflow pushes a moving
   `edge` tag and a `sha-<short>` tag.

5. Tag the release. Use `git tag -s vX.Y.Z` to create a signed tag
   the publish workflow will pick up. The workflow pushes
   `vX.Y.Z`, `X.Y`, `sha-<short>`, and (when on `main`) `edge`
   tags with a keyless cosign signature and an SPDX SBOM
   attestation.

6. Note the published digest in the deployment log.

## Updating the CI host

```bash
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<new-digest> \
TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
    ./deploy.sh up
```

`deploy.sh up` is idempotent: the Compose contract replaces the
running container with `--force-recreate` and the listener picks up
the existing credentials in `titan-runner-state`. No new
registration token is needed because the
`RUNNER_VERSION=${RUNNER_VERSION}` and the GitHub-issued secret in
`.credentials` are both image-only secrets; they survive a container
recreation on the same state volume.

## Rolling back

Rollbacks are an image switch, not a state mutation. Re-deploy
with the previous digest:

```bash
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<previous-digest> \
TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
    ./deploy.sh up
```

GitHub does not allow mutating an existing version tag
(`vX.Y.Z`); operators always deploy by digest. The previous
published digest is still available from GHCR.

The `down` action is intentionally non-destructive &mdash; it does
not delete the state, work, or browser volumes. A red badge on the
release never requires re-registering the runner.

## When to re-register

Re-registration produces a new GitHub-issued secret. The operator
needs a fresh registration token whenever:

* The host was rebuilt from scratch (the `state` volume is empty).
* The runner was offline for more than 30 days &mdash; GitHub
  invalidates stale credentials.
* The repository was transferred to a new owner.
* The host changed its IP or its metadata and a stale registration
  is causing GitHub to refuse reconnection.

The `register` action calls the upstream `config.sh --replace`, so a
stale registration is removed before a new one is created.

## Emergency stop

To stop the listener without losing state, simply run:

```bash
./deploy.sh down
```

The state, work, and browser volumes remain on disk. The container
will not restart itself; an operator must explicitly re-run
`up` to bring it back online.
