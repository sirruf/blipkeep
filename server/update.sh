#!/usr/bin/env bash
#
# Move an installed panel to a published version. Runs on the server itself.
#
#   ./update.sh 0.7.0     — switch the stack to sirruf/tinymon-server:0.7.0
#   ./update.sh latest    — to the latest published one
#   ./update.sh --current — show what is running now
#
# Neither sources nor Elixir are needed on the server: the image arrives ready
# from the registry. Rolling back is the same call with the previous version —
# the image has not gone anywhere.
#
# Migrations are applied by the container on start (rel/overlays/bin/server),
# there is no separate step.
#
# English only, deliberately: this file ships in the public installation kit.

set -euo pipefail

IMAGE="${TINYMON_IMAGE:-sirruf/tinymon-server}"
STACK_NAME="${STACK_NAME:-tinymon}"
SERVICE="${STACK_NAME}_tinymon"
VERSION="${1:-}"

cd "$(dirname "$0")"

current_version() {
  docker service inspect "$SERVICE" \
    --format '{{index .Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || true
}

if [[ "$VERSION" == "--current" ]]; then
  echo "current: $(current_version)"
  exit 0
fi

if [[ -z "$VERSION" ]]; then
  echo "Specify a version: ./update.sh 0.7.0 (or latest)" >&2
  echo "Currently installed: $(current_version)" >&2
  exit 1
fi

if ! docker service inspect "$SERVICE" >/dev/null 2>&1; then
  echo "Service $SERVICE not found — the stack is not deployed yet." >&2
  echo "The first deployment is done with bootstrap." >&2
  exit 1
fi

BEFORE="$(current_version)"
echo "==> was: $BEFORE"
echo "==> pulling ${IMAGE}:${VERSION}"

# Pull up front: if the tag is missing or the registry is unreachable, we find
# out before Swarm stops the running container
docker pull "${IMAGE}:${VERSION}"

echo "==> updating $SERVICE"

# --with-registry-auth hands the registry credentials to the nodes; without it
# a task cannot pull from a private repository
docker service update \
  --with-registry-auth \
  --image "${IMAGE}:${VERSION}" \
  "$SERVICE"

echo "==> waiting until it is ready"

attempts=0
until [[ "$(docker service ls --filter "name=${SERVICE}" --format '{{.Replicas}}' | cut -d/ -f1)" == "1" ]]; do
  attempts=$((attempts + 1))

  if [[ $attempts -gt 90 ]]; then
    echo >&2
    echo "    the service did not start within 3 minutes. What happened:" >&2
    docker service ps "$SERVICE" --no-trunc | head -5 >&2
    echo >&2
    echo "    rollback: ./update.sh <the version from the \"was\" line>" >&2
    exit 1
  fi

  sleep 2
done

echo
echo "==> done: $(current_version)"
