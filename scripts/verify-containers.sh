#!/usr/bin/env bash
# Run the mock E2E suite from a disposable Playwright container against an
# already-built paperless-gpt runtime image. The image argument is deliberately
# mandatory so CI cannot accidentally test a different image than it publishes.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <paperless-gpt-image>" >&2
  exit 64
fi

image_ref=$1
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runner_image=${E2E_RUNNER_IMAGE:-paperless-gpt-e2e-runner:local}
artifact_root=${E2E_ARTIFACT_DIR:-"$repo_root/web-app"}
runner_name="paperless-gpt-e2e-$RANDOM-$RANDOM"

cleanup() {
  docker rm -f "$runner_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build \
  --file "$repo_root/web-app/e2e/Dockerfile" \
  --tag "$runner_image" \
  "$repo_root/web-app"

# Testcontainers starts the application and its dependencies through the host
# Docker daemon. Host networking lets the Playwright process reach the mapped
# ports at localhost, while the socket lets Testcontainers create and clean up
# its own network and containers. Create the runner by name so reports can be
# copied out even when the test command fails.
docker create \
  --name "$runner_name" \
  --network host \
  --env CI=true \
  --env DOCKER_HOST=unix:///var/run/docker.sock \
  --env E2E_LLM_MODE=mock \
  --env PAPERLESS_GPT_IMAGE="$image_ref" \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  "$runner_image" >/dev/null

set +e
docker start --attach "$runner_name"
test_status=$?
set -e

mkdir -p "$artifact_root/playwright-report" "$artifact_root/test-results"
docker cp "$runner_name:/work/playwright-report/." "$artifact_root/playwright-report" 2>/dev/null || true
docker cp "$runner_name:/work/test-results/." "$artifact_root/test-results" 2>/dev/null || true

exit "$test_status"
