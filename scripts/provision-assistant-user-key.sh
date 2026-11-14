#!/usr/bin/env bash
# Give a Nextcloud user their own Assistant *harness* key (full cc-platform agent
# graph: bash, ssh_command, file tools, behind the approve/deny gate).
#
#   sudo scripts/provision-assistant-user-key.sh <nextcloud-uid>           # new user
#   sudo scripts/provision-assistant-user-key.sh <nextcloud-uid> --rotate  # replace their key
#
# Only do this for people who should have shell-level access to this host: the shim
# runs the agent as the host user. Users WITHOUT a personal key get the global
# 'chat' key (plain model call, no tools). Keys never leave this script's files.
#
# What it does: 1) appends '<harness> <uid> <random key>' to the shim registry
# (hot-reloaded by cc-shim, no restart), 2) stores the same key as the user's personal
# integration_openai api_key via the app's settings service (encrypted), 3) restarts
# the task-processing worker, which caches settings for up to 5 minutes, 4) creates the user's
# Nextcloud "AI Workspace" shared folder (nc-agent-workspace.py).
set -euo pipefail

UID_ARG="${1:-}"
ROTATE=false
[[ "${2:-}" == "--rotate" ]] && ROTATE=true
[[ -n "$UID_ARG" && "$UID_ARG" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] || { echo "usage: $0 <nextcloud-uid> [--rotate]" >&2; exit 2; }

KEYS_FILE="${SHIM_KEYS_FILE:-/home/coreconduit/.config/cc-shim/keys}"
CONTAINER="${NC_CONTAINER:-nextcloud-aio-nextcloud}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -w "$KEYS_FILE" ]] || { echo "registry not writable (run with sudo?): $KEYS_FILE" >&2; exit 1; }
docker exec --user www-data "$CONTAINER" php occ user:info "$UID_ARG" >/dev/null 2>&1 \
  || { echo "Nextcloud user '$UID_ARG' does not exist" >&2; exit 1; }

NAME_RE="${UID_ARG//./\\.}"
if grep -qE "^harness[[:space:]]+${NAME_RE}[[:space:]]" "$KEYS_FILE" && ! $ROTATE; then
  echo "'$UID_ARG' already has a harness key; pass --rotate to replace it" >&2
  exit 1
fi

ENVF="$(mktemp)"; trap 'rm -f "$ENVF"' EXIT; chmod 600 "$ENVF"
UID_ARG="$UID_ARG" KEYS_FILE="$KEYS_FILE" ENVF="$ENVF" python3 - <<'PY'
import json, os, secrets
uid, path, envf = os.environ["UID_ARG"], os.environ["KEYS_FILE"], os.environ["ENVF"]
key = secrets.token_urlsafe(32)
lines = [l for l in open(path).read().splitlines()
         if not (l.split("#")[0].split()[:2] == ["harness", uid])]
lines.append(f"harness {uid} {key}")
tmp = path + ".new"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("\n".join(lines) + "\n")
st = os.stat(path)  # the registry belongs to the shim's user; running as root must not change that
os.chown(tmp, st.st_uid, st.st_gid)
os.replace(tmp, path)
os.chmod(path, 0o600)
with open(envf, "w") as f:
    f.write("KEYS_JSON=" + json.dumps({uid: key}) + "\n")
PY

docker exec -i --user www-data --env-file "$ENVF" "$CONTAINER" php < "$HERE/set-user-api-key.php"
systemctl restart nextcloud-taskprocessing-worker 2>/dev/null || true
# Also give them their Nextcloud "AI Workspace": a folder the agent's service account owns and
# shares with them, so files the agent creates show up in their Files (Shared/AI Workspace).
if ! python3 "$HERE/nc-agent-workspace.py" "$UID_ARG"; then
  echo "warning: AI Workspace not set up for '$UID_ARG' (run setup-nc-agent-account.sh once, then nc-agent-workspace.py $UID_ARG)" >&2
fi
echo "done: '$UID_ARG' now has a harness key (registry hot-reloads; worker restarted)."
