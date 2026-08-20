#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r script; do
    bash -n "$script"
done < <(find . -path './tests/__pycache__' -prune -o -type f -name '*.sh' -print)

while IFS= read -r script; do
    shellcheck -S warning "$script"
done < <(find . -path './tests/__pycache__' -prune -o -type f -name '*.sh' -print)

bash tests/test_runner_scripts.sh

# The original Titan contract file predates the monorepo layout. Keep all
# non-publication assertions there and validate publication separately against
# the real repository-level reusable workflow.
python3 -m pytest tests/test_runner_contract.py -v -k 'not test_publish'
python3 -m pytest tests/test_codex_contract.py -v
python3 -m pytest tests/test_publish_titan_contract.py -v
python3 tests/check_compose_contract.py
