#!/usr/bin/env bash
# LogEmber agent uninstaller.
#
#   curl -fsSL https://github.com/overexposed-ltd/logember-agent/releases/latest/download/uninstall.sh | sudo bash
#   curl -fsSL https://github.com/overexposed-ltd/logember-agent/releases/latest/download/uninstall.sh | sudo bash -s -- --purge
#
# Stops and disables the systemd unit, removes the binary and the unit file. The config
# (/etc/logember, including the ingest key) and the disk buffer (/var/lib/logember) are kept
# unless --purge is given, which also removes them and the logember user. Safe to re-run:
# anything already gone is skipped. Nothing is downloaded. The host stays registered in the
# hub and its ingest key stays valid until the host is removed there. See --help.
#
# Everything runs from main() on the last line, so a download cut short by the network runs nothing.

# This check must stay POSIX: `sh` on Debian/Ubuntu is dash, which stops here.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "logember uninstall: this script needs bash. Run it with:" >&2
  echo "  sudo bash uninstall.sh [--purge]" >&2
  exit 1
fi
set -euo pipefail

SERVICE="logember-agent"
AGENT_USER="logember"
BIN="/usr/local/bin/logember-agent"
CONF_DIR="/etc/logember"
ENV_FILE="$CONF_DIR/agent.env"
UNIT_DIR="/etc/systemd/system"
STATE_DIR="/var/lib/logember"
# The hub config sync (logember-agent-sync + its timer) where installed; timers stop first.
UNITS=("$SERVICE-sync.timer" "$SERVICE-sync.service" "$SERVICE.service")
FILES=("$BIN" "$BIN-sync")

PURGE=0
HUB=""

usage() {
  cat <<'USAGE'
Remove the LogEmber agent from this host.

Usage:
  curl -fsSL https://github.com/overexposed-ltd/logember-agent/releases/latest/download/uninstall.sh | sudo bash [-s -- --purge]
  sudo bash uninstall.sh [--purge]

Options:
  --purge     also remove /etc/logember (config, redaction rules, ingest key),
              /var/lib/logember (disk buffer) and the logember user
  -h, --help  show this help

Without --purge, /etc/logember and /var/lib/logember are kept, so running install.sh again
picks up the same ingest key and redaction rules. Logs still in the disk buffer are not sent.

This script does not revoke the ingest key: remove the host in the hub to do that.
USAGE
}

info() { echo "==> $*"; }
warn() { echo "logember uninstall: warning: $*" >&2; }
die() {
  echo "logember uninstall: error: $*" >&2
  exit 1
}
die_usage() {
  echo "logember uninstall: $*" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --purge) PURGE=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die_usage "unknown option: $1" ;;
    esac
  done
}

check_host() {
  [[ $(id -u) -eq 0 ]] || die "run as root, e.g.: sudo bash uninstall.sh"
  [[ $(uname -s) == Linux ]] || die "only Linux is supported, this is $(uname -s)"
}

# The hub this host was enrolled with, for the closing message.
load_hub() {
  local k v
  if [[ -r $ENV_FILE ]]; then
    while IFS='=' read -r k v || [[ -n $k ]]; do
      if [[ $k == LOGEMBER_HUB_URL ]]; then
        HUB=$v
      fi
    done <"$ENV_FILE"
  fi
}

have_systemd() {
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]
}

# "not-found" once neither a unit file nor a running instance is left.
load_state() {
  systemctl show --property=LoadState --value -- "$1" 2>/dev/null || echo not-found
}

stop_units() {
  if ! have_systemd; then
    warn "systemd is not running; skipping systemctl stop/disable"
    return 0
  fi
  local unit
  for unit in "${UNITS[@]}"; do
    if [[ $(load_state "$unit") != not-found ]]; then
      info "Stopping and disabling $unit"
      systemctl disable --now --quiet -- "$unit"
    fi
  done
}

remove_files() {
  local f unit
  for unit in "${UNITS[@]}"; do
    FILES+=("$UNIT_DIR/$unit")
  done
  for f in "${FILES[@]}"; do
    if [[ -e $f || -L $f ]]; then
      info "Removing $f"
      rm -f -- "$f"
    fi
  done
  if have_systemd; then
    systemctl daemon-reload
    for unit in "${UNITS[@]}"; do
      systemctl reset-failed -- "$unit" 2>/dev/null || true
    done
  fi
}

purge() {
  local dir unit dirs=("$CONF_DIR" "$STATE_DIR")
  # Drop-ins someone added for the agent's units (systemctl edit) go with --purge only.
  for unit in "${UNITS[@]}"; do
    dirs+=("$UNIT_DIR/$unit.d")
  done
  for dir in "${dirs[@]}"; do
    if [[ -e $dir ]]; then
      info "Removing $dir"
      rm -rf -- "$dir"
    fi
  done
  if have_systemd; then
    systemctl daemon-reload
  fi
  if id "$AGENT_USER" >/dev/null 2>&1; then
    info "Removing system user $AGENT_USER"
    userdel "$AGENT_USER" || die "could not remove user $AGENT_USER (are processes still running as it? see: ps -u $AGENT_USER)"
  fi
  # userdel removes the user's own group only where USERGROUPS_ENAB is on.
  if getent group "$AGENT_USER" >/dev/null; then
    groupdel "$AGENT_USER" || warn "could not remove group $AGENT_USER"
  fi
}

main() {
  parse_args "$@"
  check_host
  load_hub
  stop_units
  remove_files
  if [[ $PURGE -eq 1 ]]; then
    purge
    info "logember-agent is removed, including its config, disk buffer and user."
  else
    info "logember-agent is removed. Kept $CONF_DIR (config and ingest key) and $STATE_DIR (disk buffer); run again with --purge to remove them and the $AGENT_USER user."
  fi
  echo
  echo "This host is still registered in LogEmber and its ingest key has not been revoked."
  echo "Remove the host in the hub (${HUB:-https://api.logember.com}) to revoke the key."
}

main "$@"
