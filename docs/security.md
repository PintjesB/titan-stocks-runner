# Security

The runner is a *non-ephemeral* container with full access to the
host Docker daemon. Treat the host as a developer workstation: no
production credentials, no application volumes, no production data.

## Host boundary

The Compose contract enforces three separate guarantees:

* `no-new-privileges:true` blocks setuid escalation inside the
  container. The runner never needs `privileged: true`; privileged
  mode and DinD daemons are explicitly forbidden.
* `/var/run/docker.sock` is bind-mounted read/write. The host's
  socket group ID is granted to the runner user inside the
  container as a **supplemental** group (the user-mod mapping
  uses `usermod -a -G`); the runner user's *primary* group remains
  `runner`. This keeps Docker access a separate capability from
  every other operation the runner performs.
* `restart: unless-stopped` keeps the listener online through host
  reboots; nothing else automatically restarts the container.

The Docker socket grant is effectively host root access. Operators
must:

* Keep the host OS and the Docker daemon patched.
* Restrict SSH to the host to operators only.
* Never reuse the host for staging or production workloads.
* Never expose the host network ports used by the workflows
  (`5432`, `8000`, &hellip;) to the public internet.

## Registration token handling

The token is the only credential the operator must protect at
runtime. Three rules apply:

* Always source it from a 0600 file or a secret-store adapter.
  Never pass it through an environment variable, a CI log, or a
  shell history file.
* Never commit it. The repository excludes `.env`, `tokens/`, and
  `*.token` patterns in `.gitignore` for this reason.
* Delete the bootstrap file after `register` returns. The next
  restart uses the GitHub-issued long-lived secret in the state
  volume; the token is never needed again until the host is
  rebuilt from scratch.

## Image provenance

Every published image is signed with a keyless cosign signature and
attested with an SPDX SBOM. The release workflow also verifies the
signature and attestation immediately after signing; verify a
downloaded digest with:

```bash
cosign verify \
  --certificate-identity 'https://github.com/PintjesB/titan-stocks-runner/.github/workflows/publish.yml@refs/tags/vX.Y.Z' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest>
```

## Vulnerability scanning

* Pull requests and `main` builds run
  [`aquasecurity/trivy-action`](https://github.com/aquasecurity/trivy-action)
  with `severity: HIGH,CRITICAL` and `ignore-unfixed: true`.
  Findings at those severities fail the job.
* Release-tag builds re-scan the immutable digest that was just
  published so the failure trips before any operator can pull it.
* The pipeline does not depend on the runner image itself; it
  runs on hosted `ubuntu-24.04-arm`.

## Source-code reuse

The project does not ship a `LICENSE` file. Pulling the image does
not grant any reproduction or reuse rights; the source code,
documentation, and configuration in this repository are the only
authoritative copies and they do not carry an open-source license.
