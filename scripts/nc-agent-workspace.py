#!/usr/bin/env python3
"""Ensure a Nextcloud user has a cc-platform "AI Workspace" folder, shared with them.

The cc-platform agent writes files through a dedicated, non-admin Nextcloud service
account (``cc-agent``). For each person who may use the harness it keeps a folder
``/<uid>/AI Workspace`` that it owns and shares (edit rights) with that person, so the
files appear in their Nextcloud Files under ``Shared/AI Workspace`` -- and the
credential cannot reach any of the person's other files.

Idempotent: re-running only creates what is missing. Run as the shim's user (or root);
needs only network access to Nextcloud plus the credential store, no docker.

    nc-agent-workspace.py <uid>            # create folder + share if missing
    nc-agent-workspace.py <uid> --check    # report only; exit 1 if anything is missing

Environment:
    CORECONDUIT_HOME   credential store dir (default /home/coreconduit/.coreconduit)
    NC_AGENT_URL       Nextcloud base URL (default http://localhost:11000)
    NC_AGENT_USER      service account (default cc-agent)
    NC_AGENT_CREDENTIAL  credential name (default nextcloud-agent)
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import stat
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("NC_AGENT_URL", "http://localhost:11000").rstrip("/")
AGENT = os.environ.get("NC_AGENT_USER", "cc-agent")
CRED_NAME = os.environ.get("NC_AGENT_CREDENTIAL", "nextcloud-agent")
HOME = os.environ.get("CORECONDUIT_HOME") or "/home/coreconduit/.coreconduit"
WORKSPACE = "AI Workspace"
UID_RE = re.compile(r"^[A-Za-z0-9_.@-]{1,64}$")
SHARE_PERMS = 15  # read + update + create + delete; no resharing


def load_secret() -> str:
    """Read the service account's app password from the 0600 credential store."""
    path = os.path.join(HOME, "credentials.toml")
    try:
        mode = os.stat(path).st_mode
    except OSError as exc:
        sys.exit(f"error: credential store not readable: {path} ({exc})")
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        sys.exit(f"error: {path} must be mode 0600 (is {stat.filemode(mode)})")
    with open(path, "rb") as f:
        entry = tomllib.load(f).get("credentials", {}).get(CRED_NAME)
    if not entry or not entry.get("value"):
        sys.exit(f"error: no [credentials.{CRED_NAME}] value in {path}")
    return str(entry["value"])


class Client:
    """Minimal WebDAV/OCS client for the service account (stdlib only)."""

    def __init__(self, secret: str) -> None:
        raw = f"{AGENT}:{secret}".encode()
        self._auth = "Basic " + base64.b64encode(raw).decode()

    def request(
        self,
        method: str,
        path: str,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, bytes]:
        h = {
            "Authorization": self._auth,
            "OCS-APIRequest": "true",
            "Accept": "application/json",
        }
        h.update(headers or {})
        req = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()


def dav(*parts: str) -> str:
    quoted = "/".join(urllib.parse.quote(p, safe="") for p in parts)
    return f"/remote.php/dav/files/{urllib.parse.quote(AGENT, safe='')}/{quoted}"


def exists(client: Client, *parts: str) -> bool:
    status, _ = client.request("PROPFIND", dav(*parts), headers={"Depth": "0"})
    return status == 207


def ensure_folder(client: Client, check: bool, *parts: str) -> bool:
    """Return True if the folder exists (or was created)."""
    if exists(client, *parts):
        print(f"ok      folder /{'/'.join(parts)}")
        return True
    if check:
        print(f"MISSING folder /{'/'.join(parts)}")
        return False
    status, body = client.request("MKCOL", dav(*parts))
    if status in (201, 405):
        print(f"created folder /{'/'.join(parts)}")
        return True
    sys.exit(f"error: MKCOL /{'/'.join(parts)} -> HTTP {status}: {body[:200]!r}")


def share_exists(client: Client, uid: str) -> bool:
    path = urllib.parse.quote(f"/{uid}/{WORKSPACE}", safe="/")
    status, body = client.request(
        "GET", f"/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json&path={path}"
    )
    if status != 200:
        sys.exit(f"error: listing shares -> HTTP {status}: {body[:200]!r}")
    data = json.loads(body)["ocs"]["data"]
    return any(s.get("share_type") == 0 and s.get("share_with") == uid for s in data)


def ensure_share(client: Client, check: bool, uid: str) -> bool:
    if share_exists(client, uid):
        print(f"ok      share  /{uid}/{WORKSPACE} -> {uid}")
        return True
    if check:
        print(f"MISSING share  /{uid}/{WORKSPACE} -> {uid}")
        return False
    form = urllib.parse.urlencode(
        {
            "path": f"/{uid}/{WORKSPACE}",
            "shareType": 0,
            "shareWith": uid,
            "permissions": SHARE_PERMS,
        }
    )
    status, body = client.request(
        "POST",
        "/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json",
        data=form.encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    if status != 200:
        sys.exit(f"error: creating share for {uid} -> HTTP {status}: {body[:200]!r}")
    print(
        f"created share  /{uid}/{WORKSPACE} -> {uid} (appears in their Files as Shared/{WORKSPACE})"
    )
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("uid", help="Nextcloud user id")
    parser.add_argument(
        "--check",
        action="store_true",
        help="report only; exit 1 if anything is missing",
    )
    args = parser.parse_args()
    if not UID_RE.match(args.uid):
        sys.exit(f"error: invalid Nextcloud uid {args.uid!r}")
    client = Client(load_secret())
    ok = ensure_folder(client, args.check, args.uid)
    ok = ensure_folder(client, args.check, args.uid, WORKSPACE) and ok
    if ok or not args.check:
        ok = ensure_share(client, args.check, args.uid) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
