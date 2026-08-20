#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r script; do
    bash -n "$script"
    shellcheck -S warning "$script"
done < <(find scripts -type f -name '*.sh' -print)

docker compose --env-file .env.example config >/dev/null

grep -q '@openai/codex' Dockerfile
grep -q 'docker-compose-v2' Dockerfile
grep -q 'docker-buildx' Dockerfile
grep -q 'python3' Dockerfile
grep -q 'nodejs' Dockerfile
! grep -qi 'playwright' Dockerfile
! grep -qi 'chromium' Dockerfile
! grep -qi 'postgresql-client' Dockerfile

grep -q 'oportunist-runner-state' docker-compose.yml
grep -q 'oportunist-runner-work' docker-compose.yml
grep -q 'oportunist-runner-codex' docker-compose.yml
grep -q 'CODEX_HOME: /home/runner/.codex' docker-compose.yml
