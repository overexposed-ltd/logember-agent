#!/usr/bin/env bash
# LogEmber agent installer.
#
#   curl -fsSL https://get.logember.com | sudo bash -s -- --token <ENROLLMENT_TOKEN>
#
# Downloads the release assets, verifies every one against the release's checksums.txt
# before anything is written, enrolls the host with the hub (once) and starts the
# systemd unit. Safe to re-run: upgrades the binary, agent.yaml and the unit, and keeps
# the existing ingest key unless --reenroll is given. redaction.yaml (the host's own
# redaction rules) is written once and never overwritten. See --help for all options.
#
# Release assets used: checksums.txt, logember-agent_linux_{amd64,arm64}, agent.yaml,
# redaction.yaml, docker.yaml, logember-agent.service. Everything runs from main() on the
# last line, so a download cut short by the network runs nothing.

# This check must stay POSIX: `sh` on Debian/Ubuntu is dash, which stops here.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "logember install: this script needs bash. Run it with:" >&2
  echo "  curl -fsSL https://get.logember.com | sudo bash -s -- --token <ENROLLMENT_TOKEN>" >&2
  exit 1
fi
set -euo pipefail

REPO="overexposed-ltd/logember-agent"
DEFAULT_HUB="https://app.logember.com"
DEFAULT_INGEST="https://ingest.logember.com"
DEFAULT_ENV="production"
SERVICE="logember-agent"
AGENT_USER="logember"
BIN="/usr/local/bin/logember-agent"
CONF_DIR="/etc/logember"
ENV_FILE="$CONF_DIR/agent.env"
UNIT_FILE="/etc/systemd/system/$SERVICE.service"
STATE_DIR="/var/lib/logember"
# Groups whose logs the agent reads; the user joins the ones that exist on this host.
# docker gives access to the Docker API, which names containers (see docker.yaml); the log
# files themselves are read with CAP_DAC_READ_SEARCH from the unit.
READ_GROUPS=(systemd-journal adm docker)

TOKEN=""
VERSION="latest"
HUB=""
INGEST=""
ENV_NAME=""
REENROLL=0
KEY=""
ARCH=""
AGENT_VERSION=""
TMP=""

usage() {
  cat <<'USAGE'
Install or upgrade the LogEmber agent (an OpenTelemetry Collector build) as a systemd service.

Usage:
  curl -fsSL https://get.logember.com | sudo bash -s -- --token <ENROLLMENT_TOKEN> [options]
  sudo bash install.sh --token <ENROLLMENT_TOKEN> [options]

Options:
  --token TOKEN     enrollment token from the hub (Settings → Keys → Enrollment token).
                    Required on the first install and with --reenroll.
  --version vX.Y.Z  release to install, e.g. v0.1.0 or v0.1.0-rc.1 (default: latest,
                    the newest release that is not a pre-release)
  --hub URL         hub URL (default: https://app.logember.com)
  --ingest URL      ingest URL (default: https://ingest.logember.com)
  --env NAME        value of the env attribute on every log line (default: production)
  --reenroll        enroll again even if this host already has an ingest key
  -h, --help        show this help

Re-running the script upgrades the binary, /etc/logember/agent.yaml and the systemd unit,
then restarts the agent. The ingest key in /etc/logember/agent.env is kept unless
--reenroll is given; --hub, --ingest and --env default to the values already there.
/etc/logember/redaction.yaml holds this host's own redaction rules: it is written on the
first install only, so edits to it are kept.

Environment (tests only):
  LOGEMBER_RELEASE_BASE  replaces https://github.com/overexposed-ltd/logember-agent/releases;
                         assets are read from <base>/latest/download/<asset> or
                         <base>/download/<version>/<asset>
USAGE
}

info() { echo "==> $*"; }
warn() { echo "logember install: warning: $*" >&2; }
die() {
  echo "logember install: error: $*" >&2
  exit 1
}
die_usage() {
  echo "logember install: $*" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# JSON string literal, escaped by hand so the script needs nothing beyond coreutils and curl.
json_str() {
  local s=$1 i c
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  for ((i = 1; i < 32; i++)); do
    printf -v c '%b' "\\0$(printf '%03o' "$i")"
    if [[ $s == *"$c"* ]]; then
      s=${s//"$c"/$(printf '\\u%04x' "$i")}
    fi
  done
  printf '"%s"' "$s"
}

need_value() {
  [[ $# -ge 2 && -n $2 ]] || die_usage "$1 needs a value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --token) need_value "$@"; TOKEN=$2; shift 2 ;;
      --version) need_value "$@"; VERSION=$2; shift 2 ;;
      --hub) need_value "$@"; HUB=$2; shift 2 ;;
      --ingest) need_value "$@"; INGEST=$2; shift 2 ;;
      --env) need_value "$@"; ENV_NAME=$2; shift 2 ;;
      --reenroll) REENROLL=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die_usage "unknown option: $1" ;;
    esac
  done
  if [[ $VERSION != latest && ! $VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    die_usage "--version must look like v1.2.3 or v1.2.3-rc.1 (or be 'latest'), got: $VERSION"
  fi
  if [[ -n $TOKEN && ! $TOKEN =~ ^[A-Za-z0-9][A-Za-z0-9._~+/=-]{7,255}$ ]]; then
    die_usage "--token does not look like an enrollment token; copy it again from the hub"
  fi
}

check_host() {
  [[ $(id -u) -eq 0 ]] || die "run as root, e.g.: curl -fsSL https://get.logember.com | sudo bash -s -- --token <ENROLLMENT_TOKEN>"
  [[ $(uname -s) == Linux ]] || die "only Linux is supported, this is $(uname -s)"
  if ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then
    die "systemd is required and must be running as PID 1"
  fi
  local cmd
  for cmd in curl sha256sum install useradd usermod getent hostname; do
    command -v "$cmd" >/dev/null || die "$cmd is required but not installed"
  done
  case $(uname -m) in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "unsupported architecture: $(uname -m) (supported: amd64, arm64)" ;;
  esac
}

# Values from a previous install are the defaults for this run.
load_previous() {
  local -A old=()
  local k v
  if [[ -f $ENV_FILE ]]; then
    while IFS='=' read -r k v || [[ -n $k ]]; do
      if [[ $k =~ ^[A-Z_]+$ ]]; then
        old[$k]=$v
      fi
    done <"$ENV_FILE"
  fi
  HUB=${HUB:-${old[LOGEMBER_HUB_URL]:-$DEFAULT_HUB}}
  INGEST=${INGEST:-${old[LOGEMBER_INGEST_URL]:-$DEFAULT_INGEST}}
  ENV_NAME=${ENV_NAME:-${old[LOGEMBER_ENV]:-$DEFAULT_ENV}}
  KEY=${old[LOGEMBER_INGEST_KEY]:-}
  HUB=${HUB%/}
  INGEST=${INGEST%/}

  # These end up in agent.env, which systemd parses: no quotes, spaces or backslashes.
  local url_re='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/+-]*)?$'
  [[ $HUB =~ $url_re ]] || die_usage "--hub must be an http(s) URL, got: $HUB"
  [[ $INGEST =~ $url_re ]] || die_usage "--ingest must be an http(s) URL, got: $INGEST"
  [[ $ENV_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    die_usage "--env may only contain letters, digits, '.', '_' and '-', got: $ENV_NAME"
}

needs_enrollment() {
  [[ -z $KEY || $REENROLL -eq 1 ]]
}

# --- download and verify -----------------------------------------------------------------

ASSET_URL=""
CURL=()

download() {
  local url=$ASSET_URL/$1 code
  code=$("${CURL[@]}" --retry 3 --max-time 300 --output "$TMP/$1" --write-out '%{http_code}' "$url") ||
    die "could not download $url (see the curl error above)"
  case $code in
    2?? | 000) ;; # 000: file:// URLs in tests
    404) die "$1 not found at $url: release $VERSION does not exist or does not have this asset (see https://github.com/$REPO/releases)" ;;
    *) die "could not download $url: HTTP $code" ;;
  esac
}

# The sha256 that checksums.txt lists for an asset ("<sha256>  <name>" lines, as sha256sum writes them).
expected_sum() {
  local sum name
  while read -r sum name || [[ -n $sum ]]; do
    if [[ ${name#\*} == "$1" && $sum =~ ^[0-9a-f]{64}$ ]]; then
      echo "$sum"
      return 0
    fi
  done <"$TMP/checksums.txt"
  return 1
}

verify() {
  local want got
  want=$(expected_sum "$1") || die "checksums.txt has no valid entry for $1; refusing to install"
  got=$(sha256sum "$TMP/$1")
  got=${got%% *}
  [[ $got == "$want" ]] || die "checksum mismatch for $1 (checksums.txt: $want, downloaded: $got); refusing to install"
}

# Fills $TMP with verified assets. Nothing outside $TMP is written before this passes.
download_release() {
  local base=${LOGEMBER_RELEASE_BASE:-https://github.com/$REPO/releases}
  base=${base%/}
  CURL=(curl --silent --show-error --location --connect-timeout 15)
  if [[ -z ${LOGEMBER_RELEASE_BASE:-} ]]; then
    CURL+=(--proto "=https" --tlsv1.2)
  else
    warn "LOGEMBER_RELEASE_BASE is set: downloading from $base (tests only)"
  fi
  if [[ $VERSION == latest ]]; then
    ASSET_URL=$base/latest/download
  else
    ASSET_URL=$base/download/$VERSION
  fi

  local asset assets=("logember-agent_linux_$ARCH" agent.yaml redaction.yaml docker.yaml logember-agent.service)
  info "Downloading logember-agent $VERSION (linux/$ARCH) from $ASSET_URL"
  download checksums.txt
  for asset in "${assets[@]}"; do
    download "$asset"
    verify "$asset"
  done
  info "Verified ${assets[*]} against checksums.txt"
}

# --- install -----------------------------------------------------------------------------

# Copies src to dest atomically (temp file + rename), so a running agent never sees a partial file.
put() {
  local src=$1 dest=$2 mode=$3 owner=$4
  install -m "$mode" -o "$owner" -g "$owner" "$src" "$dest.tmp"
  mv -f "$dest.tmp" "$dest"
}

install_files() {
  if ! id "$AGENT_USER" >/dev/null 2>&1; then
    info "Creating system user $AGENT_USER"
    useradd --system --user-group --no-create-home --home-dir "$STATE_DIR" --shell /usr/sbin/nologin "$AGENT_USER"
  fi
  local group
  for group in "${READ_GROUPS[@]}"; do
    if getent group "$group" >/dev/null; then
      usermod -a -G "$group" "$AGENT_USER"
    fi
  done
  install -d -m 0750 -o "$AGENT_USER" -g "$AGENT_USER" "$CONF_DIR" "$STATE_DIR" "$STATE_DIR/buffer"

  put "$TMP/logember-agent_linux_$ARCH" "$BIN" 0755 root
  put "$TMP/agent.yaml" "$CONF_DIR/agent.yaml" 0640 "$AGENT_USER"
  put "$TMP/docker.yaml" "$CONF_DIR/docker.yaml" 0640 "$AGENT_USER"
  # The host's own rules (the unit's second --config): only written if missing, never replaced.
  if [[ ! -f $CONF_DIR/redaction.yaml ]]; then
    put "$TMP/redaction.yaml" "$CONF_DIR/redaction.yaml" 0640 "$AGENT_USER"
  fi
  put "$TMP/logember-agent.service" "$UNIT_FILE" 0644 root

  # The binary prints "logember-agent version 0.1.0".
  local out
  out=$("$BIN" --version 2>&1) || die "$BIN --version failed: $out"
  AGENT_VERSION="v${out##* }"
  AGENT_VERSION=${AGENT_VERSION/#vv/v}
  if [[ $VERSION != latest && $AGENT_VERSION != "$VERSION" ]]; then
    die "the $VERSION release contains logember-agent $AGENT_VERSION"
  fi
  info "Installed logember-agent $AGENT_VERSION to $BIN"
}

# --- enroll ------------------------------------------------------------------------------

# POST /v1/enroll exchanges the one-time token for this host's ingest key ($KEY).
enroll() {
  local host os body resp code message
  host=$(hostname -f 2>/dev/null) || host=""
  [[ -n $host ]] || host=$(hostname)
  os="linux"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091 # plain KEY=value file, read in a subshell
    os=$(. /etc/os-release && echo "${PRETTY_NAME:-linux}")
  fi
  body="{\"token\":$(json_str "$TOKEN"),\"hostname\":$(json_str "$host"),\"os\":$(json_str "$os"),\"arch\":\"$ARCH\",\"agent_version\":$(json_str "$AGENT_VERSION")}"

  info "Enrolling $host with $HUB"
  # The body goes through stdin so the token never shows up in the process list.
  # No --retry: a retried POST could use up a second use of the token.
  resp=$(curl --silent --show-error --proto "=http,https" --connect-timeout 15 --max-time 60 \
    -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
    --data-binary @- --write-out $'\n%{http_code}' "$HUB/v1/enroll" <<<"$body") ||
    die "could not reach the hub at $HUB (see the curl error above)"
  code=${resp##*$'\n'}
  resp=${resp%$'\n'*}

  local key_re='"ingest_key"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._~+/=-]+)"'
  local message_re='"message"[[:space:]]*:[[:space:]]*"([^"]*)"'
  if [[ $code == 2?? ]]; then
    [[ $resp =~ $key_re ]] || die "the hub at $HUB answered HTTP $code without a usable ingest_key"
    KEY=${BASH_REMATCH[1]}
    return 0
  fi
  if [[ $resp =~ $message_re ]]; then
    message=${BASH_REMATCH[1]}
  else
    message=${resp:0:300}
  fi
  case $code in
    401) die "the hub at $HUB does not know this enrollment token; check --token and --hub" ;;
    404) die "$HUB/v1/enroll not found (HTTP 404); check --hub" ;;
    410) die "enrollment token rejected: $message" ;;
    *) die "enrollment failed: HTTP $code from $HUB: $message" ;;
  esac
}

# agent.env is read by systemd (EnvironmentFile=), so it holds plain KEY=value lines.
write_env() {
  (
    umask 077
    cat >"$TMP/agent.env" <<ENV
# Written by install.sh. LOGEMBER_INGEST_KEY identifies this host to LogEmber: keep it secret.
LOGEMBER_INGEST_URL=$INGEST
LOGEMBER_INGEST_KEY=$KEY
LOGEMBER_HUB_URL=$HUB
LOGEMBER_ENV=$ENV_NAME
ENV
  )
  put "$TMP/agent.env" "$ENV_FILE" 0600 "$AGENT_USER"
}

# --- start -------------------------------------------------------------------------------

# Active for 5 seconds in a row within 30 seconds; a crash-looping agent never gets there.
wait_active() {
  local i state stable=0
  for ((i = 0; i < 30; i++)); do
    state=$(systemctl is-active "$SERVICE" 2>/dev/null) || true
    if [[ $state == active ]]; then
      stable=$((stable + 1))
      if [[ $stable -ge 5 ]]; then
        return 0
      fi
    else
      stable=0
      if [[ $state == failed ]]; then
        return 1
      fi
    fi
    sleep 1
  done
  return 1
}

start_agent() {
  info "Starting $SERVICE"
  systemctl daemon-reload
  systemctl enable --quiet "$SERVICE"
  systemctl restart "$SERVICE"
  if ! wait_active; then
    echo "logember install: error: $SERVICE did not stay running. Last log lines:" >&2
    journalctl -u "$SERVICE" -n 30 --no-pager >&2 || true
    die "$SERVICE is $(systemctl is-active "$SERVICE" 2>/dev/null || true); see: journalctl -u $SERVICE"
  fi
}

main() {
  parse_args "$@"
  check_host
  load_previous
  if [[ $REENROLL -eq 1 && -z $TOKEN ]]; then
    die_usage "--reenroll needs --token (create a token in the hub: Settings → Keys → Enrollment token)"
  elif needs_enrollment && [[ -z $TOKEN ]]; then
    die_usage "--token is required: this host is not enrolled yet (create a token in the hub: Settings → Keys → Enrollment token)"
  elif ! needs_enrollment && [[ -n $TOKEN ]]; then
    info "This host is already enrolled; keeping the existing ingest key (pass --reenroll to enroll again)."
  fi

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  download_release
  install_files
  if needs_enrollment; then
    enroll
  fi
  write_env
  start_agent
  info "logember-agent $AGENT_VERSION is running. The host should appear in the hub ($HUB) within a minute."
}

main "$@"
