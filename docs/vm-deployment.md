# VM deployment

The runner is deployed on a dedicated, disposable CI VM. The VM
is the security boundary: the GitHub runner container has
unrestricted access to the VM's Docker daemon, and the VM is
isolated from production systems and the rest of the private
network. The `docker-compose.yml` contract is intentionally
concise so the security boundary lives in the VM platform and
host firewall, not in the Compose manifest.

## VM profile

The image is published as a multi-platform manifest with both
native `linux/amd64` and `linux/arm64` entries; the runner
listener runs once on whichever compatible architecture is
available. The VM profile table covers the supported native
architectures; `deploy.sh` maps `uname -m` to the matching
`linux/amd64` or `linux/arm64` platform and refuses any other
host architecture before any state is touched.

| Attribute | Value |
| --- | --- |
| Architectures | `linux/amd64` (`x86_64`) or `linux/arm64` (`aarch64`); each VM is single-architecture |
| Operating system | Ubuntu 24.04 LTS (or a compatible upstream) |
| Local storage | at least 50 GiB for the persistent state, browser, and workspace volumes |
| Outbound network | HTTPS to `*.github.com`, `*.actions.githubusercontent.com`, `ghcr.io`, `deb.nodesource.com`, `cli.github.com`, package archives, DNS, and NTP |
| Inbound network | one TCP/UDP port to the documented management path (typically SSH from a bastion) |
| Identity | dedicated for CI; no shared accounts, no production credentials, no unrelated workloads |

The VM is **not** a development host, a bastion, or a shared
resource. Rebuild it from the platform image if runner integrity
is in doubt; the container boundary is not the recovery boundary.

## Inbound traffic

Deny inbound by default. The VM firewall MUST reject every
TCP/UDP port except the explicitly approved management path.
Ephemeral Docker-published ports bind to the loopback or the
`docker0` bridge and are not externally reachable. A security
group or network policy that allows only the operator (or
bastion) IP to port 22 is the documented minimum.

The listener itself does not listen on a TCP port; the runner
container opens an outbound HTTPS connection to the GitHub
Actions service. The VM does not need to expose any additional
TCP/UDP port for the runner to function.

## Outbound traffic

Allow only the destinations the runner needs for CI:

| Destination | Purpose |
| --- | --- |
| `*.github.com` | Registration handshake, runner API, source checkouts |
| `*.actions.githubusercontent.com` | Job distribution |
| `ghcr.io` | Pull the pinned image digest |
| `deb.nodesource.com`, `cli.github.com`, `ppa.launchpadcontent.net` | Image build-time package fetches (host tools only) |
| Ubuntu archive mirrors | `apt-get` updates and base packages |
| DNS resolvers (port 53) | Name resolution |
| NTP (port 123) | Time synchronisation |

All other outbound traffic is denied.

## Blocked destinations

The VM firewall MUST drop traffic to the following destinations
even if a workflow job requests it. The block applies to both
host processes and Docker-forwarded traffic.

* **RFC 1918 private ranges**: `10.0.0.0/8`, `172.16.0.0/12`,
  `192.168.0.0/16`.
* **Link-local**: `169.254.0.0/16`. The `169.254.169.254`
  endpoint is the cloud metadata service and MUST be blocked.
* **IPv6 link-local**: `fe80::/10`.
* **IPv6 unique-local**: `fc00::/7`.
* **Loopback**: `127.0.0.0/8`, `::1/128` (the VM is not a
  service endpoint; only the host-gateway alias is allowed
  inside the listener).
* **VM host-management network**: the subnet the cloud platform
  uses for control-plane traffic (varies by platform; the
  operator must identify and block it).
* **Production VPC ranges**: the production application
  subnets, the staging subnets, and any other environment that
  is not the dedicated CI VM.

The Docker `DOCKER-USER` chain MUST apply the same egress
restrictions to container-forwarded traffic so a workflow service
container cannot reach the host-management network or the cloud
metadata endpoint either. The chain restrictions apply to
traffic leaving the VM's physical interface so Docker bridges
and `host.docker.internal` continue to work inside the listener.

## Deployment

The deployment is reproducible from a single `.env` file. The
host only needs Docker Engine with the Compose v2 plugin and
Buildx on `PATH`; the VM platform and host firewall are the
*outer* half of the security boundary.

1. Copy the committed `.env.example` and fill in the deployment
   variables:

   ```bash
   cp .env.example .env
   chmod 0600 .env
   ```

2. Fetch a short-lived registration token from GitHub and store
   it on the `TITAN_RUNNER_TOKEN=` line of `.env`:

   ```bash
   gh api -X POST \
     repos/PintjesB/titan-stocks/actions/runners/registration-token \
     | jq -r .token
   ```

3. Pull the multi-platform image and bring up the stack:

   ```bash
   docker compose pull
   docker compose up -d
   ```

   The `register` sidecar runs first and the listener only
   starts once registration completes successfully.

4. Blank the token and re-run Compose so the stopped
   registration container metadata no longer carries the token:

   ```bash
   sed -i '/^TITAN_RUNNER_TOKEN=/d' .env
   docker compose up -d
   ```

5. Dispatch the `runner-smoke` workflow from the
   `PintjesB/titan-stocks` repository to confirm the listener
   can run a multi-stack Compose job end-to-end on either
   architecture (`RUNNER_ARCH=X64` or `RUNNER_ARCH=ARM64`).

## Acceptance checks

The following checks confirm the VM network isolation is in
effect. Run them on the VM and inside a disposable Docker
container to verify the boundary applies to both the host
processes and the Docker-forwarded traffic.

### From the host

```bash
# Cloud metadata service MUST be unreachable.
curl --silent --show-error --max-time 5 \
  http://169.254.169.254/latest/meta-data/ \
  || echo "PASS: metadata endpoint blocked"

# RFC 1918 traffic MUST be unreachable.
ping -c 1 -W 2 10.0.0.1 || echo "PASS: 10/8 blocked"
ping -c 1 -W 2 172.16.0.1 || echo "PASS: 172.16/12 blocked"
ping -c 1 -W 2 192.168.0.1 || echo "PASS: 192.168/16 blocked"

# GitHub MUST be reachable.
curl --silent --show-error --max-time 5 -o /dev/null \
  -w '%{http_code}\n' https://github.com/PintjesB/titan-stocks

# GHCR MUST be reachable.
docker pull ghcr.io/pintjesb/titan-stocks-runner@sha256:none 2>&1 \
  | grep -E 'manifest unknown|denied' || echo "PASS: GHCR reachable"
```

### From a disposable Docker container

```bash
# Run a one-shot alpine container that mirrors the listener's
# networking model (default bridge network, default shm size).
docker run --rm --network bridge alpine:3.20 sh -c '
  # Cloud metadata service MUST be unreachable.
  wget --timeout=5 -q -O - http://169.254.169.254/ \
    && echo "FAIL: metadata reachable" || echo "PASS: metadata blocked"
  # RFC 1918 traffic MUST be unreachable.
  ping -c 1 -W 2 10.0.0.1 || echo "PASS: 10/8 blocked"
  ping -c 1 -W 2 172.16.0.1 || echo "PASS: 172.16/12 blocked"
  ping -c 1 -W 2 192.168.0.1 || echo "PASS: 192.168/16 blocked"
  # GitHub MUST be reachable.
  wget --timeout=5 -q -O - https://github.com/PintjesB/titan-stocks \
    | head -n1 || echo "FAIL: github unreachable"
'
```

The `DOCKER-USER` chain applies the same egress restrictions to
container-forwarded traffic (scoped to traffic leaving the VM's
physical interface so Docker bridges and `host.docker.internal`
continue to work), so the disposable container must fail every
RFC 1918 / link-local / cloud metadata check and must succeed
on the GitHub check.

If any acceptance check fails, the VM is not ready for a
runner deployment. Fix the firewall rules and re-run the
checks before bringing the listener up.

## VM rotation

When the VM is rotated, only the persistent state volume and
the work directory bind mount must survive the rotation. The
`runtime` tree, the `browser` volume, and the running container
are disposable.

```bash
# Old VM: stop the stack. The named volume and bind mount remain on disk.
docker compose down

# New VM: transfer the titan-runner-state volume and the work
# host bind mount (e.g. via rsync, btrfs send, or a Docker volume
# backup plugin), then bring the stack up without re-registering.
docker compose up -d
```

A token is only necessary when the `state` volume is empty or
the persisted identity has drifted.

## Forensic posture

The VM is disposable. If the runner integrity is in doubt:

1. Stop the listener (`docker compose down`).
2. Snapshot the VM disk for forensic analysis.
3. Provision a fresh VM from the platform image. Do **not**
   copy credentials, volumes, or workspaces into the
   replacement; the new VM starts with fresh state and a fresh
   registration token.
4. Re-transfer the `titan-runner-state` volume and the work
   bind mount from the snapshot only when the operator intends
   to keep the same GitHub identity.
5. Bring the stack up; the listener re-registers only if the
   persisted identity has drifted.

Treating the container as the recovery boundary is explicitly
forbidden: a compromised container is a compromised VM.

## Identity drift when adding the AMD64 VM

The existing ARM64 runners must re-register once because
changing `TITAN_RUNNER_LABELS` from the old
`self-hosted,linux,ARM64,titan-ci` to `titan-ci` is intentional
identity drift: GitHub auto-attaches the `self-hosted`,
`linux`, and architecture (`X64` / `ARM64`) labels based on the
listener's actual platform, so the custom-label list shrinks to
`TITAN_RUNNER_LABELS=titan-ci` only. Set a fresh
`TITAN_RUNNER_TOKEN` in `.env` and re-run `docker compose up -d`
so the registration sidecar re-registers against GitHub with the
new label list. The previous ARM64 registration is replaced in
place through `--replace`; a stale offline entry in the GitHub
UI under **Settings &rarr; Actions &rarr; Runners** must be
removed manually if a partial commit leaves it behind.

The new AMD64 VM registers normally with fresh state and a
fresh token: `docker compose pull` resolves the matching
`linux/amd64` entry from the multi-platform digest,
`docker compose up -d` runs the registration sidecar, and the
listener starts. No prior ARM64 credentials are copied to the
new VM.
