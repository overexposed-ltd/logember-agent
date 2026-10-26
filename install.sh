#!/bin/sh
# LogEmber agent installer. Usage: curl -fsSL https://get.logember.com | sudo sh -s -- --token <ENROLLMENT_TOKEN> [--version vX.Y.Z] [--hub URL] [--env production]
set -eu

TOKEN=""; VERSION="latest"; HUB="https://app.logember.com"; INGEST="https://ingest.logember.com"; ENV_NAME="production"
while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --hub) HUB="$2"; shift 2 ;;
    --ingest) INGEST="$2"; shift 2 ;;
    --env) ENV_NAME="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TOKEN" ] || { echo "--token is required (create one in the hub: Settings → Keys → Enrollment token)" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 2; }
command -v systemctl >/dev/null || { echo "systemd is required" >&2; exit 2; }

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 2 ;;
esac

REPO="overexposed-ltd/logember-agent"
if [ "$VERSION" = "latest" ]; then
  VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
fi
BASE="https://github.com/$REPO/releases/download/$VERSION"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "Downloading logember-agent $VERSION ($ARCH)…"
curl -fsSL "$BASE/logember-agent_linux_$ARCH" -o "$TMP/logember-agent"
curl -fsSL "$BASE/checksums.txt" -o "$TMP/checksums.txt"
( cd "$TMP" && grep " logember-agent_linux_$ARCH\$" checksums.txt | sed "s/logember-agent_linux_$ARCH/logember-agent/" | sha256sum -c - ) || { echo "checksum mismatch" >&2; exit 1; }
install -m 0755 "$TMP/logember-agent" /usr/local/bin/logember-agent

id logember >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin logember
install -d -m 0750 -o logember -g logember /etc/logember /var/lib/logember /var/lib/logember/buffer

echo "Enrolling with $HUB…"
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)
OS_DESC=$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-linux}" )
RESP=$(curl -fsSL -X POST "$HUB/v1/enroll" -H "Content-Type: application/json" \
  -d "{\"token\":\"$TOKEN\",\"hostname\":\"$HOSTNAME_FQDN\",\"os\":\"$OS_DESC\",\"arch\":\"$ARCH\",\"agent_version\":\"$VERSION\"}")
KEY=$(echo "$RESP" | sed -n 's/.*"ingest_key": *"\([^"]*\)".*/\1/p')
[ -n "$KEY" ] || { echo "enrollment failed: $RESP" >&2; exit 1; }

umask 077
cat > /etc/logember/agent.env <<ENV
LOGEMBER_INGEST_URL=$INGEST
LOGEMBER_INGEST_KEY=$KEY
LOGEMBER_HUB_URL=$HUB
LOGEMBER_ENV=$ENV_NAME
ENV
chown logember:logember /etc/logember/agent.env
curl -fsSL "https://raw.githubusercontent.com/$REPO/$VERSION/config/agent.yaml" -o /etc/logember/agent.yaml
curl -fsSL "https://raw.githubusercontent.com/$REPO/$VERSION/deploy/logember-agent.service" -o /etc/systemd/system/logember-agent.service
systemctl daemon-reload
systemctl enable --now logember-agent
sleep 2
systemctl --no-pager --lines=5 status logember-agent || true
echo "Done. The host should appear in the hub within a minute."
