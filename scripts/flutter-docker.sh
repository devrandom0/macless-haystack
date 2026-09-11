#!/usr/bin/env bash
# Runs Flutter commands against macless_haystack/ inside a container, so you
# don't need the Flutter SDK installed on the host.
#
# Usage:
#   scripts/flutter-docker.sh test
#   scripts/flutter-docker.sh analyze
#   scripts/flutter-docker.sh test test/history/history_archive_service_test.dart
#   scripts/flutter-docker.sh pub get
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="ghcr.io/cirruslabs/flutter:stable"

docker run --rm \
  -v "$REPO_ROOT/macless_haystack:/app" \
  -w /app \
  "$IMAGE" \
  sh -c "flutter pub get && flutter $*"
