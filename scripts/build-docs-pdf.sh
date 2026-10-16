#!/usr/bin/env bash
# Renders the Markdown documentation into docs/bot-finanzas.pdf.
# Usage: scripts/build-docs-pdf.sh
set -euo pipefail
cd "$(dirname "$0")/.."

docker build -q -t bot-finanzas-docs docs/build >/dev/null
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD:/repo" bot-finanzas-docs python3 /repo/docs/build/build_pdf.py
