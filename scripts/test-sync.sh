#!/usr/bin/env bash
# Runs deploy/logember-agent-sync against test/hub-mock.py and checks what it does: sources.yaml
# from the hub's sources, If-None-Match/304, a restart only when the sources change, bad answers
# from the hub rejected without touching sources.yaml, the heartbeat body. The same sync is then
# repeated with gawk and busybox awk (RHEL and minimal hosts). Last, the built agent runs on the
# sources.yaml the sync wrote, and a line written to a hub source must arrive with its service.
#
# Everything runs in a throwaway Debian 12 container: /bin/sh is dash, awk is mawk, and
# systemctl is a stub that logs its arguments (the units themselves need a real systemd host).
#
# Needs: docker and dist/logember-agent_linux_${ARCH:-amd64} from scripts/build.sh.
# The checks are strings that check() evals, so their $vars are meant to expand late.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH=${ARCH:-amd64}
IMAGE=logember-agent-test-sync:debian12

if [[ "${1:-}" != "--in-container" ]]; then
  bin="dist/logember-agent_linux_${ARCH}"
  [[ -x "$bin" ]] || { echo "$bin not found: run scripts/build.sh first" >&2; exit 1; }
  docker build -q --platform "linux/${ARCH}" -t "$IMAGE" - >/dev/null <<'EOF'
FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends systemd python3 jq curl gawk busybox \
 && rm -rf /var/lib/apt/lists/*
EOF
  exec docker run --rm --platform "linux/${ARCH}" -e ARCH="$ARCH" -v "$PWD:/src:ro" -w /src "$IMAGE" \
    scripts/test-sync.sh --in-container
fi

# --- inside the container ---
KEY=test-ingest-key-0123456789
W=$(mktemp -d)
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Installed the way install.sh does it.
useradd --system --user-group --no-create-home logember
install -d -m 0750 -o logember -g logember /etc/logember /var/lib/logember /var/lib/logember/buffer
install -m 0755 "dist/logember-agent_linux_${ARCH}" /usr/local/bin/logember-agent
install -m 0755 deploy/logember-agent-sync /usr/local/bin/logember-agent-sync
install -m 0640 -o logember -g logember config/agent.yaml config/redaction.yaml /etc/logember/
echo "# Written by logember-agent-sync from GET /v1/agent/config: no sources from the hub yet." >/etc/logember/sources.yaml
cat >/etc/logember/agent.env <<ENV
LOGEMBER_INGEST_URL=http://127.0.0.1:4318
LOGEMBER_INGEST_KEY=$KEY
LOGEMBER_HUB_URL=http://127.0.0.1:8080/
LOGEMBER_ENV=production
ENV
head -c 3000 /dev/zero >/var/lib/logember/buffer/queue
cat >/usr/local/sbin/systemctl <<'EOF'
#!/bin/sh
echo "$*" >>/tmp/systemctl.log
case $1 in
  is-active) cat /tmp/agent-state 2>/dev/null || echo active ;;
esac
EOF
chmod +x /usr/local/sbin/systemctl
: >/tmp/systemctl.log

python3 test/hub-mock.py 8080 "$W" "$KEY" &
hub=$!
trap 'kill $hub ${sink:-} ${agent:-} 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:8080/ && break; sleep 0.1; done

# One sync as the timer runs it (no inherited environment); output in $W/out, exit code in $rc.
run_sync() {
  rc=0
  env -i PATH="${SYNC_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}" \
    /usr/local/bin/logember-agent-sync >"$W/out" 2>&1 || rc=$?
}
restarts() { grep -c '^try-restart logember-agent$' /tmp/systemctl.log || true; }
nreq() { [[ -f $W/requests.jsonl ]] && wc -l <"$W/requests.jsonl" || echo 0; }
# The requests of the last sync (those after line $1 of requests.jsonl).
since() { tail -n +"$(($1 + 1))" "$W/requests.jsonl"; }
receivers() { sed -n 's/^      receivers: \[\(.*\)\]$/\1/p' "$1"; }

two_sources='{"sources":[
  {"type":"file","path":"\/srv\/app\/storage\/logs\/laravel.log","service_name":"apo365"},
  {"type":"file","path":"\/srv\/jobs\/*.log","service_name":"jobs"},
  {"type":"docker","path":"web","service_name":"web"},
  {"type":"file","path":"storage\/logs\/x.log","service_name":"relative"},
  {"type":"file","path":"\/var\/log\/nginx\/access.log","service_name":"nginx"}
]}'

echo "== agent.yaml and the sync script agree on the logs pipeline"
pipeline_list() { awk -v k="$1" '/^service:/ { s = 1 } s && $1 == k ":" { sub(/.*\[/, ""); sub(/\].*/, ""); print; exit }' config/agent.yaml; }
script_list() { sed -n "s/^$1='\(.*\)'$/\1/p" deploy/logember-agent-sync; }
check "PROCESSORS = processors of agent.yaml's logs pipeline ($(pipeline_list processors))" '[[ $(script_list PROCESSORS) == "$(pipeline_list processors)" ]]'
check "EXPORTERS = exporters of agent.yaml's logs pipeline ($(pipeline_list exporters))" '[[ $(script_list EXPORTERS) == "$(pipeline_list exporters)" ]]'

echo "== first sync after install, no sources in the hub"
printf '%s' '{"sources":[]}' >"$W/config.json"
n0=$(nreq)
run_sync
check "exit 0, nothing logged" '[[ $rc -eq 0 && ! -s $W/out ]]'
check "GET /v1/agent/config without If-None-Match, with the ingest key" \
  "since $n0 | jq -se '.[0] | .method == \"GET\" and .path == \"/v1/agent/config\" and .headers[\"if-none-match\"] == null and .headers.authorization == \"Bearer $KEY\"' >/dev/null"
check "install.sh's placeholder replaced (only comments differ), no restart" \
  'grep -q "^# Replaced whenever they change there" /etc/logember/sources.yaml && ! grep -qv "^#" /etc/logember/sources.yaml && [[ $(restarts) -eq 0 ]]'

echo "== two file sources added in the hub (plus three this agent cannot use)"
printf '%s' "$two_sources" >"$W/config.json"
n0=$(nreq)
run_sync
check "exit 0" '[[ $rc -eq 0 ]]'
check "GET /v1/agent/config with If-None-Match, answered 200" \
  "since $n0 | jq -se '.[0] | .path == \"/v1/agent/config\" and .headers[\"if-none-match\"] != null' >/dev/null"
check "sources.yaml: two filelog/hub_* receivers" '[[ $(grep -c "^  filelog/hub_[0-9]*:$" /etc/logember/sources.yaml) -eq 2 ]]'
check "sources.yaml: paths and services" "grep -qxF \"    include: ['/srv/app/storage/logs/laravel.log']\" /etc/logember/sources.yaml && grep -qxF \"      logember.source.service: 'jobs'\" /etc/logember/sources.yaml"
check "sources.yaml: pipeline logs/hub with the two, agent.yaml's processors and exporters" \
  'grep -qx "    logs/hub:" /etc/logember/sources.yaml && [[ $(receivers /etc/logember/sources.yaml) =~ ^filelog/hub_[0-9]+,\ filelog/hub_[0-9]+$ ]] && grep -qxF "      processors: [$(script_list PROCESSORS)]" /etc/logember/sources.yaml'
check "sources.yaml: owner logember, mode 640 ($(stat -c '%U:%G %a' /etc/logember/sources.yaml))" '[[ $(stat -c "%U:%G %a" /etc/logember/sources.yaml) == "logember:logember 640" ]]'
check "agent restarted once (try-restart)" '[[ $(restarts) -eq 1 ]]'
check "ETag saved" 'grep -q "^\"[0-9a-f]\{16\}\"$" /var/lib/logember/sources.etag'
check "skipped sources logged: docker type, relative path, default path" \
  'grep -q "source 3 skipped: type \"docker\"" "$W/out" && grep -q "source 4 skipped: path must be an absolute path" "$W/out" && grep -q "source 5 skipped: /var/log/nginx/access.log is already read" "$W/out"'
check "change logged" 'grep -q "the files from the hub changed (now 2, in /etc/logember/sources.yaml); restarted logember-agent" "$W/out"'
version="v$(/usr/local/bin/logember-agent --version | awk '{ print $NF }')"
version=${version/#vv/v}
check "heartbeat: agent_version $version, status active, buffer_bytes >= 3000" \
  "since $n0 | jq -se '.[1] | .method == \"POST\" and .path == \"/v1/agent/heartbeat\" and .headers.authorization == \"Bearer $KEY\" and .headers[\"content-type\"] == \"application/json\" and (.body | fromjson | .agent_version == \"$version\" and .status == \"active\" and .buffer_bytes >= 3000)' >/dev/null"
check "validate passes with sources.yaml, also with docker.yaml after it" \
  '( set -a; . /etc/logember/agent.env; c="--config /etc/logember/agent.yaml --config /etc/logember/redaction.yaml --config /etc/logember/sources.yaml"
     logember-agent validate $c && logember-agent validate $c --config config/docker.yaml )'
cp /etc/logember/sources.yaml "$W/sources.mawk.yaml"

echo "== second sync: unchanged in the hub"
n0=$(nreq)
run_sync
check "exit 0, nothing logged" '[[ $rc -eq 0 && ! -s $W/out ]]'
check "GET with If-None-Match = saved ETag, answered 304" \
  "since $n0 | jq -se --arg etag \"\$(cat /var/lib/logember/sources.etag)\" '.[0].headers[\"if-none-match\"] == \$etag' >/dev/null"
check "no restart" '[[ $(restarts) -eq 1 ]]'
check "heartbeat sent" "since $n0 | jq -se '.[1].path == \"/v1/agent/heartbeat\"' >/dev/null"

echo "== new body, same sources (key order, whitespace)"
etag_before=$(cat /var/lib/logember/sources.etag)
jq -c '.sources |= map({service_name, path, type})' <<<"$two_sources" >"$W/config.json"
run_sync
check "exit 0, nothing logged" '[[ $rc -eq 0 && ! -s $W/out ]]'
check "no restart" '[[ $(restarts) -eq 1 ]]'
check "new ETag saved" '[[ $(cat /var/lib/logember/sources.etag) != "$etag_before" ]]'

echo "== invalid JSON from the hub"
cp /etc/logember/sources.yaml "$W/sources.before"
printf '{"sources":[{"type":"file","path":"/srv/x.log"' >"$W/config.json"
n0=$(nreq)
run_sync
check "exit 1, error logged" '[[ $rc -eq 1 ]] && grep -q "error: GET /v1/agent/config: the hub sent invalid JSON" "$W/out"'
check "sources.yaml kept, no restart" 'cmp -s /etc/logember/sources.yaml "$W/sources.before" && [[ $(restarts) -eq 1 ]]'
check "heartbeat still sent" "since $n0 | jq -se '.[1].path == \"/v1/agent/heartbeat\"' >/dev/null"
printf '%s' '{"data":[]}' >"$W/config.json"
run_sync
check "no sources array -> exit 1, kept" '[[ $rc -eq 1 ]] && grep -q "no \"sources\" array" "$W/out" && cmp -s /etc/logember/sources.yaml "$W/sources.before"'

echo "== sources that do not pass logember-agent validate"
cp /etc/logember/redaction.yaml "$W/redaction.good"
printf 'processors:\n  redaction/local:\n    no_such_option: true\n' >/etc/logember/redaction.yaml
printf '%s' '{"sources":[{"type":"file","path":"/srv/other.log","service_name":"other"}]}' >"$W/config.json"
run_sync
check "exit 1, validate output logged" '[[ $rc -eq 1 ]] && grep -q "do not pass logember-agent validate" "$W/out"'
check "sources.yaml kept, no restart" 'cmp -s /etc/logember/sources.yaml "$W/sources.before" && [[ $(restarts) -eq 1 ]]'
cp "$W/redaction.good" /etc/logember/redaction.yaml

echo "== hub errors"
echo 500 >"$W/config.status"
n0=$(nreq)
run_sync
check "HTTP 500 -> exit 1, message from the body" '[[ $rc -eq 1 ]] && grep -q "HTTP 500 from http://127.0.0.1:8080: Mock hub error." "$W/out"'
check "heartbeat still sent" "since $n0 | jq -se '.[1].path == \"/v1/agent/heartbeat\"' >/dev/null"
rm "$W/config.status"
cp /etc/logember/agent.env "$W/agent.env.good"
sed -i 's/^LOGEMBER_INGEST_KEY=.*/LOGEMBER_INGEST_KEY=revoked-key-0123456789/' /etc/logember/agent.env
run_sync
check "revoked key -> exit 1, 401 named for both requests" '[[ $rc -eq 1 && $(grep -c "rejected this host.s ingest key (HTTP 401)" "$W/out") -eq 2 ]]'
cp "$W/agent.env.good" /etc/logember/agent.env
sed -i 's|^LOGEMBER_HUB_URL=.*|LOGEMBER_HUB_URL=http://127.0.0.1:9|' /etc/logember/agent.env
run_sync
check "hub unreachable -> exit 1" '[[ $rc -eq 1 ]] && grep -q "could not reach the hub at http://127.0.0.1:9" "$W/out"'
cp "$W/agent.env.good" /etc/logember/agent.env
echo inactive >/tmp/agent-state
printf '%s' '{"sources":[]}' >"$W/config.json"
n0=$(nreq)
run_sync
rm /tmp/agent-state
check "agent stopped -> heartbeat status inactive" "since $n0 | jq -se '.[1].body | fromjson | .status == \"inactive\"' >/dev/null"

echo "== all sources removed in the hub"
check "exit 0" '[[ $rc -eq 0 ]]'
check "sources.yaml has no receivers, restarted" '! grep -q "^receivers:" /etc/logember/sources.yaml && [[ $(restarts) -eq 2 ]]'

echo "== escaping: quotes, \$, \\u escapes, EXPR("
printf '%s' '{"sources":[
  {"type":"file","path":"\/srv\/o'"'"'neil\/${env:LOGEMBER_INGEST_KEY}\/café\/😀.log","service_name":"it'"'"'s $HOME"},
  {"type":"file","path":"\/srv\/a.log","service_name":"EXPR(env(\"LOGEMBER_INGEST_KEY\"))"},
  {"type":"file","path":"\/srv\/b\n.log","service_name":"b"}
]}' >"$W/config.json"
run_sync
check "exit 0" '[[ $rc -eq 0 ]]'
check "path: quote doubled, \$ doubled, UTF-8 decoded" "grep -qxF \"    include: ['/srv/o''neil/\\\$\\\${env:LOGEMBER_INGEST_KEY}/café/😀.log']\" /etc/logember/sources.yaml"
check "service: quote doubled, \$ doubled" "grep -qxF \"      logember.source.service: 'it''s \\\$\\\$HOME'\" /etc/logember/sources.yaml"
check "EXPR( and control characters skipped" 'grep -q "source 2 skipped: EXPR(" "$W/out" && grep -q "source 3 skipped: control characters" "$W/out" && [[ $(grep -c "^  filelog/hub_" /etc/logember/sources.yaml) -eq 1 ]]'
cp /etc/logember/sources.yaml "$W/escape.mawk.yaml"
cp "$W/config.json" "$W/escape.json"

echo "== gawk and busybox awk write the same sources.yaml"
for impl in gawk busybox; do
  mkdir -p "$W/$impl"
  if [[ $impl == busybox ]]; then
    printf '#!/bin/sh\nexec busybox awk "$@"\n' >"$W/$impl/awk"
    chmod +x "$W/$impl/awk"
  else
    ln -sf "$(command -v gawk)" "$W/$impl/awk"
  fi
  for case in "two_sources:sources.mawk.yaml" "escape:escape.mawk.yaml"; do
    name=${case%%:*}
    if [[ $name == two_sources ]]; then printf '%s' "$two_sources" >"$W/config.json"; else cp "$W/escape.json" "$W/config.json"; fi
    rm -f /var/lib/logember/sources.etag
    echo "# placeholder" >/etc/logember/sources.yaml
    SYNC_PATH="$W/$impl:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" run_sync
    check "$impl: $name" '[[ $rc -eq 0 ]] && cmp -s /etc/logember/sources.yaml "$W/${case#*:}"'
  done
done

echo "== the agent reads the hub's sources"
rm -rf /var/log/* && mkdir -p /var/log/journal/fixture /srv/app/storage/logs /srv/jobs
: >/srv/app/storage/logs/laravel.log
: >/var/log/app.log
chmod -R a+rX /srv
printf '%s' "$two_sources" >"$W/config.json"
rm -f /var/lib/logember/sources.etag
run_sync
check "sync exit 0" '[[ $rc -eq 0 ]]'
export TEST_WORK=$W
mkdir -p "$W/buffer"
python3 test/otlp-sink.py 4318 "$W/requests-otlp.jsonl" "$KEY" &
sink=$!
(
  set -a
  # shellcheck disable=SC1091 # written above
  . /etc/logember/agent.env
  exec /usr/local/bin/logember-agent --config /etc/logember/agent.yaml --config /etc/logember/redaction.yaml \
    --config /etc/logember/sources.yaml --config test/agent.test.yaml
) >"$W/agent.log" 2>&1 &
agent=$!
sleep 3 # the hub receivers start at the end of their files
echo 'ERROR payment failed password=hunter2' >>/srv/app/storage/logs/laravel.log
echo '{"level":"warn","msg":"job slow","service":"from-json"}' >/srv/jobs/import.log
echo 'INFO app started' >>/var/log/app.log
records() {
  jq -c '.resourceLogs[].scopeLogs[].logRecords[] | {body: .body.stringValue, severity: .severityText,
    attrs: ([.attributes[]? | {(.key): .value.stringValue}] | add // {})}' "$W/requests-otlp.jsonl" 2>/dev/null || true
}
for _ in $(seq 1 30); do
  [[ $(records | wc -l) -ge 3 ]] && break
  sleep 1
done
records >"$W/records.jsonl"
rec() { jq -se --arg f "$1" "map(select(.attrs[\"log.file.path\"] == \$f)) | length == 1 and (.[0] | $2)" "$W/records.jsonl" >/dev/null; }
check "laravel.log -> service apo365, error, redacted" "rec /srv/app/storage/logs/laravel.log '.attrs[\"logember.service\"] == \"apo365\" and .severity == \"error\" and .body == \"ERROR payment failed password=****\"'"
check "/srv/jobs/*.log (glob) -> service jobs, not the JSON field" "rec /srv/jobs/import.log '.attrs[\"logember.service\"] == \"jobs\" and .severity == \"warn\" and .attrs.msg == \"job slow\"'"
check "/var/log/app.log (default source) -> service app" "rec /var/log/app.log '.attrs[\"logember.service\"] == \"app\"'"
check "logember.source.service is not sent" "jq -se 'all(.attrs[\"logember.source.service\"] == null)' \"\$W/records.jsonl\" >/dev/null"

if ((fail)); then
  echo "-- last sync output"; cat "$W/out"
  echo "-- sources.yaml"; cat /etc/logember/sources.yaml
  echo "-- agent log"; cat "$W/agent.log"
  echo "-- records"; cat "$W/records.jsonl" 2>/dev/null || true
  exit 1
fi
echo "all checks passed"
