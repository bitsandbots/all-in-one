#!/bin/bash
# Nextcloud AIO — re-apply integration_openai routing to the host LiteLLM proxy.
#
# Why: the nightly AUTOMATIC_UPDATES cycle recreates nextcloud-aio-local-ai and
# has been observed (2026-09-17) to silently reset integration_openai's `url`
# app-config value back to the bundled LocalAI container
# (http://nextcloud-aio-local-ai:10078), while leaving default_completion_model_id
# set to the LiteLLM alias `mistral-small3.2` — a model name that doesn't exist
# on the bundled backend, so every chat request fails with a 500. Unlike the
# eurooffice/richdocuments patches, this isn't a file wiped from custom_apps/;
# it's an app-config row reset via occ config:app:set, so the "patch" here is a
# re-set of the two config values, not a code patch.
#
# Idempotent: only writes when the current url has drifted from the expected value.

set -euo pipefail

EXPECTED_URL="http://192.168.0.236:4000/v1"
KEY_FILE="/home/coreconduit/.config/litellm/litellm.env"
NC_CONTAINER="nextcloud-aio-nextcloud"

if [ ! -f "$KEY_FILE" ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') ERROR: key file $KEY_FILE not found, aborting"
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$KEY_FILE"
set +a
LKEY="${LITELLM_MASTER_KEY:-}"
if [ -z "$LKEY" ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') ERROR: LITELLM_MASTER_KEY empty in $KEY_FILE, aborting"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$NC_CONTAINER"; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') ERROR: $NC_CONTAINER not running, skipping"
    exit 1
fi

CURRENT_URL=$(docker exec --user www-data "$NC_CONTAINER" php occ config:app:get integration_openai url 2>/dev/null || echo "")

if [ "$CURRENT_URL" = "$EXPECTED_URL" ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') ALREADY CORRECT: integration_openai url is $EXPECTED_URL, skipping"
    exit 0
fi

echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') DRIFT DETECTED: integration_openai url was '$CURRENT_URL', expected '$EXPECTED_URL' — re-applying"

docker exec --user www-data "$NC_CONTAINER" php occ config:app:set integration_openai url --value="$EXPECTED_URL"
docker exec --user www-data "$NC_CONTAINER" php occ config:app:set integration_openai api_key --value="$LKEY"

echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') FIXED: integration_openai url + api_key re-applied"

unset LKEY LITELLM_MASTER_KEY
