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
#
# Usage: patch-assistant-litellm-url.sh [--quiet]
#   --quiet  stay silent unless something drifted or failed (for the 5-minute cron:
#            the reset happens whenever AIO restarts nextcloud-aio-local-ai, so
#            this runs often; "already correct" and "container down" are normal).

set -euo pipefail

QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true

# Backend selector (set ASSISTANT_BACKEND in the cron file; rollback = "litellm"):
#   shim    cc-platform OpenAI shim (agent graph + tools), model "cc-platform"
#   litellm host LiteLLM proxy straight to Ollama, model "mistral-small3.2"
BACKEND="${ASSISTANT_BACKEND:-shim}"
case "$BACKEND" in
shim)
    EXPECTED_URL="http://172.19.0.1:4200/v1"
    EXPECTED_MODEL="cc-platform"
    EXPECTED_LABEL="cc-platform agent (shim, tier2-chat)"
    KEY_FILE="/home/coreconduit/.config/cc-shim/shim.env"
    KEY_VAR="CC_SHIM_KEY"
    ;;
litellm)
    EXPECTED_URL="http://172.19.0.1:4000/v1"
    EXPECTED_MODEL="mistral-small3.2"
    EXPECTED_LABEL="LiteLLM (host GPU, mistral-small3.2)"
    KEY_FILE="/home/coreconduit/.config/litellm/litellm.env"
    KEY_VAR="LITELLM_MASTER_KEY"
    ;;
*)
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') ERROR: unknown ASSISTANT_BACKEND '$BACKEND' (expected shim|litellm), aborting"
    exit 1
    ;;
esac
NC_CONTAINER="nextcloud-aio-nextcloud"

if [ ! -f "$KEY_FILE" ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') ERROR: key file $KEY_FILE not found, aborting"
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$KEY_FILE"
set +a
LKEY="${!KEY_VAR:-}"
if [ -z "$LKEY" ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') ERROR: $KEY_VAR empty in $KEY_FILE, aborting"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$NC_CONTAINER"; then
    $QUIET && exit 0
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') ERROR: $NC_CONTAINER not running, skipping"
    exit 1
fi

OCC=(docker exec --user www-data "$NC_CONTAINER" php occ)

# ── Guard: the Assistant apps must be *enabled*, not merely configured ─────────
# A Nextcloud major upgrade disables apps that are not yet compatible
# (2026-11-12: NC 35 disabled assistant + integration_openai; this script kept
# "FIXED"-ing config rows for an app that was off). Alert, never auto-enable:
# forcing an incompatible app on can break the instance. Alerts are deduped via
# a marker in /run (re-sent every 6h while the condition persists).
# shellcheck source=lib-alert.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-alert.sh"
ENABLED_APPS=$("${OCC[@]}" app:list 2>/dev/null | sed '/^Disabled:/,$d')
if [ -n "$ENABLED_APPS" ]; then
    MISSING=""
    for app in assistant integration_openai; do
        echo "$ENABLED_APPS" | grep -qE "^[[:space:]]+- ${app}:" || MISSING="${MISSING:+$MISSING,}$app"
    done
    APPS_MARKER=/run/nc-assistant-apps-disabled.alerted
    if [ -n "$MISSING" ]; then
        echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') WARNING: Assistant app(s) not enabled: $MISSING — try: occ app:update <app> && occ app:enable <app>"
        if [ ! -f "$APPS_MARKER" ] || [ -n "$(find "$APPS_MARKER" -mmin +360 2>/dev/null)" ] || [ "$(cat "$APPS_MARKER" 2>/dev/null)" != "$MISSING" ]; then
            nc_alert high "Nextcloud Assistant apps not enabled: $MISSING (Assistant is down; likely a Nextcloud upgrade — run occ app:update + app:enable)"
            echo "$MISSING" > "$APPS_MARKER"
        fi
    else
        rm -f "$APPS_MARKER"
    fi
fi
CURRENT_URL=$("${OCC[@]}" config:app:get integration_openai url 2>/dev/null || echo "")
CURRENT_MODEL=$("${OCC[@]}" config:app:get integration_openai default_completion_model_id 2>/dev/null || echo "")
CURRENT_KEY=$("${OCC[@]}" config:app:get integration_openai api_key 2>/dev/null || echo "")

if [ "$CURRENT_URL" = "$EXPECTED_URL" ] && [ "$CURRENT_MODEL" = "$EXPECTED_MODEL" ] && [ "$CURRENT_KEY" = "$LKEY" ]; then
    $QUIET || echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') ALREADY CORRECT: integration_openai is $BACKEND ($EXPECTED_URL, $EXPECTED_MODEL), skipping"
    exit 0
fi

echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') DRIFT DETECTED: integration_openai url '$CURRENT_URL' model '$CURRENT_MODEL' (key match: $([ "$CURRENT_KEY" = "$LKEY" ] && echo yes || echo no)), expected $BACKEND '$EXPECTED_URL' '$EXPECTED_MODEL' — re-applying"

"${OCC[@]}" config:app:set integration_openai url --value="$EXPECTED_URL"
"${OCC[@]}" config:app:set integration_openai api_key --value="$LKEY"
"${OCC[@]}" config:app:set integration_openai default_completion_model_id --value="$EXPECTED_MODEL"
"${OCC[@]}" config:app:set integration_openai service_name --value="$EXPECTED_LABEL"

echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') FIXED: integration_openai url + api_key + model re-applied ($BACKEND)"

unset LKEY CURRENT_KEY
