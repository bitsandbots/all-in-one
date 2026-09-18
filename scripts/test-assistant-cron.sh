#!/usr/bin/env bash
# Cron wrapper for test-assistant.sh — runs the full check suite including the
# real e2e chat round-trip, using a short-lived scoped app password generated
# fresh for each run (never a stored credential, never the admin login password).
#
# Runs after both auto-heal crons (eurooffice patch 03:00, LiteLLM routing
# patch 03:05) so a failure here means the stack is unhealthy even after
# self-repair has had a chance to run, not just mid-drift.
#
# Usage:
#   ./test-assistant-cron.sh
#
# To run manually:  sudo bash /home/coreconduit/projects/nextcloud-aio/scripts/test-assistant-cron.sh

set -uo pipefail

CONTAINER="nextcloud-aio-nextcloud"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_NAME="cron-e2e-$(date -u +%Y%m%d-%H%M%S)"
TOKEN=""
TOKEN_ID=""

# shellcheck disable=SC2317  # only called indirectly, via the EXIT trap below
cleanup() {
  if [[ -n "$TOKEN_ID" ]]; then
    docker exec --user www-data "$CONTAINER" php occ user:auth-tokens:delete admin "$TOKEN_ID" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "$(date -u +%FT%TZ) SKIP: $CONTAINER is not running"
  exit 0
fi

TOKEN=$(docker exec --user www-data "$CONTAINER" php occ user:auth-tokens:add admin --name="$TOKEN_NAME" -n 2>/dev/null | tail -1)
if [[ -z "$TOKEN" ]]; then
  echo "$(date -u +%FT%TZ) ERROR: failed to generate a temporary app password for admin, aborting"
  exit 1
fi

TOKEN_ID=$(docker exec --user www-data "$CONTAINER" php occ user:auth-tokens:list admin 2>/dev/null \
  | grep "$TOKEN_NAME" | awk -F'|' '{print $2}' | tr -d ' ')

echo "$(date -u +%FT%TZ) Running test-assistant.sh with e2e (token: $TOKEN_NAME)"
"$SCRIPT_DIR/test-assistant.sh" --e2e-user admin --e2e-pass "$TOKEN"
exit_code=$?

echo "$(date -u +%FT%TZ) test-assistant.sh exited $exit_code"
exit $exit_code
