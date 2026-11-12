#!/usr/bin/env bash
# lib-alert.sh — source me. nc_alert <low|medium|high> "message"
#
# Forwards to netwatch's notify.sh (desktop notification + alerts.log + optional
# webhook). These crons run as root, notify.sh belongs to the desktop user, so
# it is invoked via runuser. Never fails the caller: alerting is best-effort.
# Override with NC_ALERT_USER / NC_ALERT_NOTIFY for another host.
NC_ALERT_USER="${NC_ALERT_USER:-coreconduit}"
NC_ALERT_NOTIFY="${NC_ALERT_NOTIFY:-/home/${NC_ALERT_USER}/.coreconduit/netwatch/notify.sh}"

nc_alert() {
  local level="${1:-high}" msg="${2:-nextcloud-aio alert}"
  if [[ -x "$NC_ALERT_NOTIFY" ]]; then
    if [[ $EUID -eq 0 ]]; then
      runuser -u "$NC_ALERT_USER" -- "$NC_ALERT_NOTIFY" "$level" "$msg" >/dev/null 2>&1 || true
    else
      "$NC_ALERT_NOTIFY" "$level" "$msg" >/dev/null 2>&1 || true
    fi
  fi
  return 0
}
