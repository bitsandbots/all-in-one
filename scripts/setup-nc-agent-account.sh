#!/usr/bin/env bash
# One-time (idempotent) setup of the Nextcloud service account the cc-platform agent
# uses to put files into people's Nextcloud Files (see nc-agent-workspace.py).
#
#   sudo scripts/setup-nc-agent-account.sh            # create account + credential if missing
#   sudo scripts/setup-nc-agent-account.sh --rotate   # replace the app password
#
# What it does:
#   1. creates the NON-admin user `cc-agent` with a storage quota (default 5 GB), in no group
#   2. creates an app password for it (named cc-platform-agent)
#   3. stores that app password as [credentials.nextcloud-agent] in the cc-platform
#      credential store (~/.coreconduit/credentials.toml, mode 0600, kept owned by its
#      directory's owner; a timestamped 0600 backup is made before any change)
#   4. verifies the credential against Nextcloud's WebDAV endpoint
# The account's own login password is random and thrown away; only the app password
# is kept. Nothing secret is printed.
set -euo pipefail

ROTATE=false
[[ "${1:-}" == "--rotate" ]] && ROTATE=true

CONTAINER="${NC_CONTAINER:-nextcloud-aio-nextcloud}"
AGENT_USER="${NC_AGENT_USER:-cc-agent}"
QUOTA="${NC_AGENT_QUOTA:-5 GB}"
CRED_NAME="${NC_AGENT_CREDENTIAL:-nextcloud-agent}"
CC_HOME="${CORECONDUIT_HOME:-/home/coreconduit/.coreconduit}"
NC_URL="${NC_AGENT_URL:-http://localhost:11000}"
CRED_FILE="$CC_HOME/credentials.toml"

occ() { docker exec --user www-data "$CONTAINER" php occ "$@"; }

[[ -d "$CC_HOME" ]] || { echo "error: $CC_HOME does not exist" >&2; exit 1; }

have_credential() {
  [[ -f "$CRED_FILE" ]] && CRED_FILE="$CRED_FILE" CRED_NAME="$CRED_NAME" python3 - <<'PY'
import os, sys, tomllib
with open(os.environ["CRED_FILE"], "rb") as f:
    sys.exit(0 if tomllib.load(f).get("credentials", {}).get(os.environ["CRED_NAME"], {}).get("value") else 1)
PY
}

if have_credential && ! $ROTATE; then
  echo "credential '$CRED_NAME' already present in $CRED_FILE (use --rotate to replace); checking account only"
  NEED_TOKEN=false
else
  NEED_TOKEN=true
fi

# 1. the account
if occ user:info "$AGENT_USER" >/dev/null 2>&1; then
  echo "account '$AGENT_USER' exists"
else
  PW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  docker exec --user www-data -e OC_PASS="$PW" "$CONTAINER" php occ user:add \
    --password-from-env --display-name="cc-platform agent" "$AGENT_USER" >/dev/null
  unset PW
  echo "created account '$AGENT_USER'"
fi
occ user:setting "$AGENT_USER" files quota "$QUOTA" >/dev/null
if occ user:info "$AGENT_USER" 2>/dev/null | grep -qE '^\s+- admin\s*$'; then
  echo "error: '$AGENT_USER' is in the admin group; refusing (it must stay unprivileged)" >&2
  exit 1
fi

# 2 + 3. app password -> credential store
if $NEED_TOKEN; then
  PW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  # A fresh login password lets us mint an app password for an existing account too.
  docker exec --user www-data -e OC_PASS="$PW" "$CONTAINER" php occ user:resetpassword \
    --password-from-env "$AGENT_USER" >/dev/null
  # drop any previous app passwords of ours so a rotate really revokes the old one
  occ user:auth-tokens:list "$AGENT_USER" 2>/dev/null | awk -F'|' '/cc-platform-agent/ {gsub(/ /,"",$2); print $2}' |
    while read -r id; do [[ -n "$id" ]] && occ user:auth-tokens:delete "$AGENT_USER" "$id" >/dev/null; done
  TOKEN="$(docker exec --user www-data -e OC_PASS="$PW" "$CONTAINER" php occ user:auth-tokens:add \
    --password-from-env --name=cc-platform-agent "$AGENT_USER" | tail -1)"
  unset PW
  [[ ${#TOKEN} -ge 20 ]] || { echo "error: could not create an app password" >&2; exit 1; }

  CRED_FILE="$CRED_FILE" CRED_NAME="$CRED_NAME" TOKEN="$TOKEN" python3 - <<'PY'
import os, re, shutil, time
path, name, token = os.environ["CRED_FILE"], os.environ["CRED_NAME"], os.environ["TOKEN"]
owner = os.stat(os.path.dirname(path))
text = ""
if os.path.exists(path):
    backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    os.chmod(backup, 0o600)
    os.chown(backup, owner.st_uid, owner.st_gid)
    text = open(path).read()
block = f'[credentials.{name}]\nmethod = "password"\nvalue = "{token}"\n'
pattern = re.compile(rf"^\[credentials\.{re.escape(name)}\]\n(?:(?!\[).*\n?)*", re.M)
text = pattern.sub(block, text) if pattern.search(text) else (text.rstrip("\n") + "\n\n" if text else "") + block
tmp = path + ".new"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(text)
os.chown(tmp, owner.st_uid, owner.st_gid)  # stay owned by the cc-platform user, even under sudo
os.replace(tmp, path)
os.chmod(path, 0o600)
PY
  unset TOKEN
  echo "stored credential '$CRED_NAME' in $CRED_FILE"
fi

# 4. verify end to end (WebDAV with the stored credential)
CODE="$(CRED_FILE="$CRED_FILE" CRED_NAME="$CRED_NAME" AGENT_USER="$AGENT_USER" NC_URL="$NC_URL" python3 - <<'PY'
import base64, os, tomllib, urllib.error, urllib.request
with open(os.environ["CRED_FILE"], "rb") as f:
    secret = tomllib.load(f)["credentials"][os.environ["CRED_NAME"]]["value"]
auth = base64.b64encode(f'{os.environ["AGENT_USER"]}:{secret}'.encode()).decode()
req = urllib.request.Request(
    f'{os.environ["NC_URL"]}/remote.php/dav/files/{os.environ["AGENT_USER"]}/',
    method="PROPFIND", headers={"Authorization": "Basic " + auth, "Depth": "0"})
try:
    print(urllib.request.urlopen(req, timeout=20).status)
except urllib.error.HTTPError as exc:
    print(exc.code)
PY
)"
if [[ "$CODE" == "207" ]]; then
  echo "verified: '$AGENT_USER' can reach its files over WebDAV (HTTP 207)"
else
  echo "error: WebDAV check failed (HTTP $CODE)" >&2
  exit 1
fi
