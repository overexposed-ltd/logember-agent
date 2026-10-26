#!/usr/bin/env bash
# Smoke test: a real install on a systemd host, and the first lines arriving.
#
# Boots the distro with systemd as PID 1 in a privileged container (test/smoke/Dockerfile) and
# runs the README one-liner in it as a sudo user, against a mock hub (test/smoke/mock-hub.py:
# POST /v1/enroll, GET /v1/agent/config with one file source, POST /v1/agent/heartbeat, and the
# release assets) and an OTLP sink standing in for ingest (test/smoke/sink.yaml). Checks the first
# logember-agent-sync run (sources.yaml, heartbeat). Then writes a unique marker line with a fake
# secret to /var/log, to the hub's file source and through logger (journald), and checks that all
# three arrive with logember.service, logember.env, a valid severity, host.name and the secret
# redacted. Finally runs uninstall.sh --purge and checks
# that nothing is left.
#
#   test/smoke/run.sh --distro debian-12 [--arch arm64]          # assets from dist/ (scripts/build.sh)
#   test/smoke/run.sh --distro ubuntu-24.04 --release v0.1.0-rc.1  # install.sh and assets from the GitHub Release
#
# --distro: ubuntu-24.04 or debian-12. --arch: amd64 or arm64 (default: the Docker host's; the
# other one runs emulated, if Docker can). Needs docker and jq. KEEP=1 leaves the containers
# running for a look inside (docker exec -it <host> bash).
set -euo pipefail
cd "$(dirname "$0")/../.."

REPO=overexposed-ltd/logember-agent
SINK_IMAGE=otel/opentelemetry-collector-contrib:0.163.2@sha256:7f22d2a6748110ffb6a59bc0df448bccbf501cdb667d610ede4c61d3863d5849
HUB_IMAGE=python:3.13-alpine@sha256:bf12ecc0bea3f171d55145dd02c78b5eeb09f30ee2ac9cc2b4c9e4e8f5e30741
SERVICE=logember-agent
# The assets release.yml publishes; install.sh and uninstall.sh download from this set.
ASSETS=(dist/logember-agent_linux_amd64 dist/logember-agent_linux_arm64
  config/agent.yaml config/redaction.yaml config/docker.yaml deploy/logember-agent.service
  deploy/logember-agent-sync deploy/logember-agent-sync.service deploy/logember-agent-sync.timer
  install.sh uninstall.sh)

DISTRO=""
ARCH=""
RELEASE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --distro) DISTRO=${2:-}; shift 2 ;;
    --arch) ARCH=${2:-}; shift 2 ;;
    --release) RELEASE=${2:-}; shift 2 ;;
    *) echo "usage: $0 --distro ubuntu-24.04|debian-12 [--arch amd64|arm64] [--release vX.Y.Z]" >&2; exit 2 ;;
  esac
done
case $DISTRO in
  ubuntu-24.04) BASE=ubuntu:24.04 OS_NAME="Ubuntu 24.04" ;;
  debian-12) BASE=debian:12 OS_NAME="Debian GNU/Linux 12" ;;
  *) echo "--distro must be ubuntu-24.04 or debian-12" >&2; exit 2 ;;
esac
ARCH=${ARCH:-$(docker version --format '{{.Server.Arch}}')}
[[ $ARCH == amd64 || $ARCH == arm64 ]] || { echo "--arch must be amd64 or arm64, got: $ARCH" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ID=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
NAME=logember-smoke-$ID
HOST=$NAME-host
HOSTNAME_=smoke-${DISTRO//./}-$ARCH
TOKEN=smoke-enroll-$ID$ID
INGEST_KEY=smoke-ingest-$ID$ID$ID
MARKER=logember-smoke-marker-$ID
SECRET=smoke-secret-$ID
# In the checkout, not /tmp: the containers bind-mount it, and when this script itself runs in a
# container (act) only the checkout is the same path for the Docker daemon.
mkdir -p .smoke
WORK=$(mktemp -d "$PWD/.smoke/run.XXXXXX")
mkdir -p "$WORK/www" "$WORK/hub" "$WORK/sink"
chmod 0777 "$WORK/sink"

fail=0
step() { echo; echo "== $*"; }
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
die() { echo "FAIL $*"; exit 1; }
if command -v sha256sum >/dev/null; then
  sha256() { sha256sum "$@"; }
else
  sha256() { shasum -a 256 "$@"; }
fi
# A command on the host as root, or as the sudo user "smoke" through bash with pipefail.
on_host() { docker exec "$HOST" "$@"; }
as_user() { docker exec -u smoke -w /home/smoke "$HOST" bash -o pipefail -c "$1"; }

cleanup() {
  local code=$?
  if [[ $code -ne 0 || $fail -ne 0 ]]; then
    echo
    if docker container inspect "$HOST" >/dev/null 2>&1; then
      echo "-- journalctl -u $SERVICE"
      on_host journalctl -u "$SERVICE" --no-pager -n 50 || true
    fi
    local c
    for c in "$NAME-hub" "$NAME-sink"; do
      if docker container inspect "$c" >/dev/null 2>&1; then
        echo "-- docker logs $c"
        docker logs "$c" 2>&1 | tail -30
      fi
    done
  fi
  if [[ ${KEEP:-0} == 1 ]]; then
    echo "KEEP=1: left $HOST, $NAME-hub, $NAME-sink and network $NAME running; work dir $WORK"
  else
    docker rm -f "$HOST" "$NAME-hub" "$NAME-sink" >/dev/null 2>&1 || true
    docker network rm "$NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK"
    rmdir .smoke 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- release assets ------------------------------------------------------------------------

if [[ -n $RELEASE ]]; then
  VERSION=$RELEASE
  ASSET_BASE=https://github.com/$REPO/releases/download/$VERSION
  RELEASE_ENV=""
  step "Testing the published release $VERSION ($ASSET_BASE)"
else
  step "Staging the release assets from dist/ (as release.yml publishes them)"
  mkdir "$WORK/assets"
  for f in "${ASSETS[@]}"; do
    [[ -f $f ]] || die "$f is missing (run scripts/build.sh first)"
    cp "$f" "$WORK/assets/"
  done
  chmod 0755 "$WORK"/assets/logember-agent_linux_* "$WORK/assets/install.sh" "$WORK/assets/uninstall.sh"
  (cd "$WORK/assets" && sha256 -- * >"$WORK/checksums.txt") && mv "$WORK/checksums.txt" "$WORK/assets/"
  # The version the binary reports is the one install.sh --version must match.
  docker pull -q --platform "linux/$ARCH" "$BASE" >/dev/null
  out=$(docker run --rm --platform "linux/$ARCH" -v "$WORK/assets:/assets:ro" "$BASE" "/assets/logember-agent_linux_$ARCH" --version 2>&1) ||
    die "cannot run the linux/$ARCH binary here (no emulation for $ARCH in Docker?): $out"
  VERSION="v${out##* }"
  VERSION=${VERSION/#vv/v}
  mkdir -p "$WORK/www/releases/download"
  mv "$WORK/assets" "$WORK/www/releases/download/$VERSION"
  ASSET_BASE=http://hub:8080/releases/download/$VERSION
  RELEASE_ENV=LOGEMBER_RELEASE_BASE=http://hub:8080/releases
  ok "$out, staged at $ASSET_BASE"
fi

# --- environment ---------------------------------------------------------------------------

step "Starting $DISTRO ($ARCH) with systemd, the mock hub and the OTLP sink"
docker build -q --platform "linux/$ARCH" --build-arg "BASE=$BASE" -t "logember-smoke-host:$DISTRO-$ARCH" test/smoke >/dev/null
docker network create "$NAME" >/dev/null
docker run -d --name "$NAME-hub" --network "$NAME" --network-alias hub \
  -v "$PWD/test/smoke:/smoke:ro" -v "$WORK/www:/www:ro" -v "$WORK/hub:/hub" \
  "$HUB_IMAGE" python3 -u /smoke/mock-hub.py 8080 /www "$TOKEN" "$INGEST_KEY" /hub/enroll.jsonl >/dev/null
docker run -d --name "$NAME-sink" --network "$NAME" --network-alias sink --user "$(id -u):$(id -g)" \
  -e INGEST_KEY="$INGEST_KEY" -v "$PWD/test/smoke/sink.yaml:/etc/otelcol-contrib/config.yaml:ro" \
  -v "$WORK/sink:/out" "$SINK_IMAGE" --config /etc/otelcol-contrib/config.yaml >/dev/null
docker run -d --name "$HOST" --hostname "$HOSTNAME_" --network "$NAME" --platform "linux/$ARCH" \
  --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock \
  "logember-smoke-host:$DISTRO-$ARCH" >/dev/null

# Polled: right after `docker run` systemd is not listening yet, and --wait would give up.
for _ in $(seq 1 120); do
  state=$(on_host systemctl is-system-running 2>/dev/null) || true
  [[ $state == running || $state == degraded ]] && break
  sleep 1
done
[[ $state == running || $state == degraded ]] || die "systemd did not come up: ${state:-no answer}"
[[ $state == running ]] || on_host systemctl --failed --no-pager || true
# shellcheck disable=SC2016 # expanded on the host
ok "systemd is $state ($(on_host bash -c '. /etc/os-release && echo "$PRETTY_NAME"'), $(on_host uname -m))"
# Up when they answer: the hub serves checksums.txt, the sink refuses a request without the key.
for _ in $(seq 1 30); do
  hub=$(on_host curl -s -o /dev/null -w '%{http_code}' "http://hub:8080/releases/download/$VERSION/checksums.txt" || true)
  sink=$(on_host curl -s -o /dev/null -w '%{http_code}' -X POST http://sink:4318/v1/logs || true)
  [[ ($hub == 200 || -n $RELEASE) && $sink == 401 ]] && break
  sleep 1
done
[[ $sink == 401 ]] || die "the OTLP sink does not answer (HTTP $sink)"
ok "mock hub at http://hub:8080, OTLP sink at http://sink:4318"

# --- install -------------------------------------------------------------------------------

step "install.sh through sh refuses with a clear message"
if out=$(as_user "curl -fsSL $ASSET_BASE/install.sh | sudo sh -s -- --token $TOKEN" 2>&1); then
  bad "sh ran install.sh: $out"
elif [[ $out == *"needs bash"* ]]; then
  ok "${out%%$'\n'*}"
else
  bad "unexpected output: $out"
fi

# The hub's file source exists before the install, as an application log would; its old line
# must not be sent (new sources are read from their end).
on_host bash -c "mkdir -p /srv/smoke && echo 'smoke-old-line-$ID written before the install' >/srv/smoke/app.log"

install_cmd="curl -fsSL $ASSET_BASE/install.sh | sudo $RELEASE_ENV bash -s -- --token $TOKEN --version $VERSION --hub http://hub:8080 --ingest http://sink:4318 --env smoke"
step "$install_cmd"
as_user "$install_cmd" || die "install.sh failed"

step "systemctl is-active $SERVICE"
state=$(on_host systemctl is-active "$SERVICE" 2>/dev/null) || true
echo "$state"
[[ $state == active ]] || die "$SERVICE is ${state:-unknown}"
on_host systemctl status "$SERVICE" --no-pager -n 0 || true

step "CPU and disk limits of $SERVICE"
limits=$(on_host systemctl show -p CPUQuotaPerSecUSec -p Nice -p IOSchedulingClass -p IOSchedulingPriority "$SERVICE" | sort | tr '\n' ' ')
echo "$limits"
# IOSchedulingClass is shown as a number: 2 is best-effort.
want="CPUQuotaPerSecUSec=500ms IOSchedulingClass=2 IOSchedulingPriority=7 Nice=19 "
if [[ $limits == "$want" ]]; then ok "unit limits"; else bad "unit limits: want $want"; fi
pid=$(on_host systemctl show -p MainPID --value "$SERVICE")
# Field 19 of /proc/<pid>/stat is the nice value (Debian 12 has no ps); comm in ( ) may hold spaces.
nice=$(on_host sh -c "sed 's/.*) //' /proc/$pid/stat | cut -d' ' -f17") || nice=""
if [[ $nice == 19 ]]; then ok "agent process runs at nice 19"; else bad "agent process nice is ${nice:-unknown}, want 19"; fi

step "Enrollment"
enroll=$(tail -n 1 "$WORK/hub/enroll.jsonl" 2>/dev/null) || enroll=""
if jq -e --arg arch "$ARCH" --arg v "$VERSION" --arg host "$HOSTNAME_" --arg os "$OS_NAME" \
  '.arch == $arch and .agent_version == $v and .hostname == $host and (.os | startswith($os))' <<<"$enroll" >/dev/null; then
  ok "POST /v1/enroll $(jq -c 'del(.token)' <<<"$enroll")"
else
  bad "POST /v1/enroll body: $enroll"
fi
if on_host grep -qxF "LOGEMBER_INGEST_KEY=$INGEST_KEY" /etc/logember/agent.env; then
  ok "ingest key written to /etc/logember/agent.env ($(on_host stat -c '%a %U' /etc/logember/agent.env))"
else
  bad "/etc/logember/agent.env does not hold the ingest key from the hub"
fi

step "First sync with the hub (install.sh runs logember-agent-sync once)"
result=$(on_host systemctl show -p Result --value logember-agent-sync.service 2>/dev/null) || result=""
if [[ $result == success ]]; then ok "logember-agent-sync.service: $result"; else bad "logember-agent-sync.service: ${result:-unknown}"; fi
timer=$(on_host systemctl is-active logember-agent-sync.timer 2>/dev/null) || timer=""
if [[ $timer == active ]]; then ok "logember-agent-sync.timer is active"; else bad "logember-agent-sync.timer is ${timer:-unknown}"; fi
if on_host grep -qxF "    include: ['/srv/smoke/app.log']" /etc/logember/sources.yaml; then
  ok "/etc/logember/sources.yaml has the hub's source /srv/smoke/app.log"
else
  bad "/etc/logember/sources.yaml does not have /srv/smoke/app.log"
fi
heartbeat=$(tail -n 1 "$WORK/hub/heartbeat.jsonl" 2>/dev/null) || heartbeat=""
if jq -e --arg v "$VERSION" '.agent_version == $v and .status == "active" and (.buffer_bytes | type == "number")' <<<"$heartbeat" >/dev/null; then
  ok "POST /v1/agent/heartbeat $heartbeat"
else
  bad "POST /v1/agent/heartbeat body: ${heartbeat:-none}"
fi

# The sync restarted the agent with the hub's receiver; lines written before that receiver has
# opened its file would be skipped (start_at: end), so wait for its file_storage entry.
for _ in $(seq 1 30); do
  on_host sh -c 'ls /var/lib/logember/buffer | grep -q filelog_hub_' && break
  sleep 1
done
sleep 2

# --- first lines -----------------------------------------------------------------------------

step "Writing the marker $MARKER (with a fake secret) to /var/log, the hub's source and through logger"
file_line="WARN $MARKER from /var/log password=$SECRET"
hub_line="ERROR $MARKER from the hub source password=$SECRET"
journal_line="$MARKER from journald password=$SECRET"
as_user "echo '$file_line' | sudo tee -a /var/log/logember-smoke.log >/dev/null"
as_user "echo '$hub_line' | sudo tee -a /srv/smoke/app.log >/dev/null"
as_user "logger -t logember-smoke -p user.err '$journal_line'"

# One line per record, as in scripts/test-config.sh.
flatten() {
  jq -c '.resourceLogs[] | .resource as $res | .scopeLogs[].logRecords[] | {
      host: ([$res.attributes[]? | select(.key == "host.name") | .value.stringValue] | first),
      body: .body.stringValue,
      severity_text: .severityText,
      severity_number: .severityNumber,
      time: (.timeUnixNano // "0"),
      attrs: ([.attributes[]? | {(.key): (.value.stringValue // {nonstring: .value})}] | add // {})
    }' "$WORK/sink/logs.jsonl" 2>/dev/null || true
}
for _ in $(seq 1 90); do
  [[ $(flatten | grep -cF "$MARKER") -ge 3 ]] && break
  sleep 1
done
flatten >"$WORK/records.jsonl"
on_host systemctl is-active "$SERVICE" >/dev/null || bad "$SERVICE stopped while the lines were sent"

step "Received marker records ($(wc -l <"$WORK/records.jsonl" | tr -d ' ') records in the sink)"
jq -c --arg m "$MARKER" 'select(.body | contains($m))' "$WORK/records.jsonl"

check() {
  local name=$1 filter=$2
  if jq -se --arg m "$MARKER" --arg host "$HOSTNAME_" "$filter" "$WORK/records.jsonl" >/dev/null; then
    ok "$name"
  else
    bad "$name"
  fi
}
# shellcheck disable=SC2016 # $m, $host are jq variables
{
  check "the /var/log line arrived once: service, env, warn, host.name, secret redacted" \
    'map(select(.body | contains($m)) | select(.attrs["log.file.path"] == "/var/log/logember-smoke.log"))
     | length == 1 and (.[0] | .body == "WARN \($m) from /var/log password=****"
       and .attrs["logember.service"] == "logember-smoke" and .attrs["logember.env"] == "smoke"
       and .severity_text == "warn" and (.severity_number == 13 or .severity_number == "13") and .host == $host)'
  check "the hub source line arrived once: service from the hub, env, error, host.name, secret redacted" \
    'map(select(.body | contains($m)) | select(.attrs["log.file.path"] == "/srv/smoke/app.log"))
     | length == 1 and (.[0] | .body == "ERROR \($m) from the hub source password=****"
       and .attrs["logember.service"] == "smoke-app" and .attrs["logember.env"] == "smoke"
       and .severity_text == "error" and .host == $host and .attrs["logember.source.service"] == null)'
  check "the logger line arrived once via journald: service, env, error, host.name, secret redacted" \
    'map(select(.body | contains($m)) | select(.attrs["log.file.path"] == null))
     | length == 1 and (.[0] | .body == "\($m) from journald password=****"
       and .attrs["logember.service"] == "logember-smoke" and .attrs["logember.env"] == "smoke"
       and .attrs["syslog.identifier"] == "logember-smoke"
       and .severity_text == "error" and (.severity_number == 17 or .severity_number == "17") and .host == $host)'
  check "every record: logember.service set, logember.env = smoke, severity in the schema enum and matching" \
    'length > 0 and all(
       (.attrs["logember.service"] | type == "string" and length > 0)
       and .attrs["logember.env"] == "smoke" and .time != "0"
       and ({"trace":1,"debug":5,"info":9,"warn":13,"error":17,"fatal":21}[.severity_text] as $n
            | $n != null and (.severity_number == $n or .severity_number == ($n | tostring))))'
}
if grep -qF -- "smoke-old-line-$ID" "$WORK/sink/logs.jsonl" 2>/dev/null; then
  bad "the line written to the hub's source before the install was sent"
else
  ok "the line written to the hub's source before the install was not sent"
fi
if grep -qF -- "$SECRET" "$WORK/sink/logs.jsonl" 2>/dev/null; then
  bad "the fake secret $SECRET reached the sink"
else
  ok "the fake secret $SECRET did not reach the sink"
fi

# --- uninstall -------------------------------------------------------------------------------

uninstall_cmd="curl -fsSL $ASSET_BASE/uninstall.sh | sudo bash -s -- --purge"
step "$uninstall_cmd"
as_user "$uninstall_cmd" || die "uninstall.sh failed"
state=$(on_host systemctl is-active "$SERVICE" 2>/dev/null) || true
echo "systemctl is-active $SERVICE: $state"
[[ $state != active ]] || bad "$SERVICE is still active"
for path in /usr/local/bin/logember-agent /usr/local/bin/logember-agent-sync /etc/systemd/system/$SERVICE.service \
  /etc/systemd/system/$SERVICE-sync.service /etc/systemd/system/$SERVICE-sync.timer /etc/logember /var/lib/logember; do
  if on_host test -e "$path"; then bad "$path is still there"; else ok "$path removed"; fi
done
if on_host id logember >/dev/null 2>&1; then bad "user logember is still there"; else ok "user logember removed"; fi

echo
if [[ $fail -ne 0 ]]; then
  echo "smoke test FAILED on $DISTRO ($ARCH)"
  exit 1
fi
echo "smoke test passed on $DISTRO ($ARCH), logember-agent $VERSION"
