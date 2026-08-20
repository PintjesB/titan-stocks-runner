# Codex on the self-hosted runner

The runner image includes a pinned OpenAI Codex CLI so workflows in the
consumer repository can invoke `codex exec` without installing Codex for
every job.

Codex authentication is intentionally **not** baked into the public image.
ChatGPT/Codex login state is stored in the Docker named volume
`titan-runner-codex`, mounted at:

```text
/home/runner/.codex
```

`CODEX_HOME` is set to that path for the listener and all GitHub Actions jobs.
The startup entrypoint ensures the mounted directory is owned by the non-root
`runner` user before the listener starts.

## Initial login

After deploying an image that contains Codex, authenticate once from the CI VM:

```bash
docker compose exec --user runner runner codex login --device-auth
```

Complete the browser/device flow shown by Codex, then verify the persisted
login:

```bash
docker compose exec --user runner runner codex login status
```

The `--user runner` argument is important. It ensures the credentials written
into the named volume belong to the same non-root user that executes Actions
jobs.

No OpenAI API key is required when the runner is intentionally using the
ChatGPT/Codex subscription login.

## Persistence and recovery

The `titan-runner-codex` volume survives normal container recreation, image
upgrades, host reboots, and:

```bash
docker compose down
```

It is deliberately treated as replaceable authentication state rather than a
required backup artifact. If the volume is deleted, for example by running:

```bash
docker compose down -v
```

or by explicitly removing `titan-runner-codex`, recreate/start the runner and
repeat the device login:

```bash
docker compose up -d
docker compose exec --user runner runner codex login --device-auth
```

No application data or GitHub runner registration is stored in the Codex
volume. Deleting it only logs Codex out.

## Verify after deployment

The published image capability probe verifies that the Codex binary exists and
that its reported version matches the image's `CODEX_VERSION` pin:

```bash
./deploy.sh probe
```

Authentication itself is intentionally excluded from the image probe because
published images must not contain or require a user's ChatGPT credentials.
Before enabling an autonomous Codex workflow, verify the runtime login with:

```bash
docker compose exec --user runner runner codex login status
```

## Version updates

`CODEX_VERSION` is pinned in the root `Dockerfile`. Update the pin deliberately,
then publish the runner image normally. The native amd64 and arm64 image probes
must both pass before the multi-platform image is promoted.

The current automation design expects Codex CLI versions that support the
GPT-5.6 model family. The issue/PR workflow itself belongs in the consumer
repository, not this runner-image repository.

## Dedicated Codex runner

A second Codex-specific runner does not require a different image. Reuse this
same tested image and give the second runner its own GitHub registration,
runner label, state volume, work volume, browser volume, and Codex auth volume.

Keeping those volumes separate is important because long-running autonomous
jobs must not share the same Actions `_work` directory or runner credentials
with the normal CI listener.

A dedicated runner is useful when Codex jobs become frequent or long-running,
because a single persistent Actions runner can execute only one job at a time.
Until that becomes a practical bottleneck, the existing `titan-ci` runner can
run Codex jobs directly.
