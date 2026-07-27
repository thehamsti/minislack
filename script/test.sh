#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_PATH="/private/tmp/mini-slack-swiftpm"

swift test --package-path "$ROOT_DIR" --scratch-path "$SCRATCH_PATH"
