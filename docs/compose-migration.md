# Compose migration after the runner repository split

The repository move to `runners/titan/` and `runners/oportunist/` does not by itself stop already-running containers. The deployment files on a runner VM are local files, and the existing Titan GHCR image name remains `ghcr.io/pintjesb/titan-stocks-runner`.

## Titan

An existing Titan Compose deployment can keep running while you schedule the migration. Update it before using Codex or before the next normal image refresh.

Use the current files from `runners/titan/` as the source of truth. In particular, the current Compose model adds:

```yaml
environment:
  CODEX_HOME: /home/runner/.codex

volumes:
  - titan-runner-codex:/home/runner/.codex

volumes:
  titan-runner-codex:
    name: titan-runner-codex
```

The existing `titan-runner-state`, `titan-runner-work`, and `titan-runner-browser` volume names are unchanged, so adopting the current Compose file reuses the existing GitHub registration, workspace, and browser cache.

If the old deployment pins an image digest, update `TITAN_RUNNER_IMAGE` to the newly published digest after the image pipeline succeeds. A digest pin never moves automatically. If the deployment uses `:latest`, run `docker compose pull` before recreating the runner.

After deployment, authenticate Codex once:

```bash
cd runners/titan
docker compose exec --user runner runner codex login --device-auth
docker compose exec --user runner runner codex login status
```

Deleting `titan-runner-codex` only removes Codex authentication. Recreate the runner and repeat the device login.

## Oportunist

Use `runners/oportunist/docker-compose.yml` rather than adapting the Titan Compose file. Its persistent state is intentionally separate:

- `oportunist-runner-state`
- `oportunist-runner-work`
- `oportunist-runner-codex`

After first registration, clear `OPORTUNIST_RUNNER_TOKEN` from `.env` and recreate the container so the short-lived token is no longer present in Docker's stored container environment metadata.

Authenticate Codex once with:

```bash
cd runners/oportunist
docker compose exec --user runner runner codex login --device-auth
docker compose exec --user runner runner codex login status
```

## Repository rename

The GitHub repository is now `PintjesB/github-runners`. Existing Git remotes pointing at the former repository name are redirected by GitHub, but update local remotes when convenient:

```bash
git remote set-url origin git@github.com:PintjesB/github-runners.git
```

The GHCR package names intentionally remain independent of the source repository name.
