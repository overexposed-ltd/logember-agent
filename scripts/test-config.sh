#!/usr/bin/env bash
# Runs the built agent with config/agent.yaml and config/redaction.yaml (as the unit does) against
# the fixtures in test/fixtures and checks every record it sends against the record schema
# (proto/log-schema.json in the main repo), and that no secret from the redaction fixtures leaves it.
#
# The agent runs in a throwaway Debian 12 container: the fixtures are copied into the real
# /var/log there (so the include/exclude paths of agent.yaml are tested as they are), the journal
# export is turned into a journal file for the journald receiver, and test/agent.test.yaml points
# the exporter at test/otlp-sink.py, which writes the OTLP/JSON requests to a file for jq.
#
# Needs: docker, jq, and dist/logember-agent_linux_${ARCH:-amd64} from scripts/build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH=${ARCH:-amd64}
IMAGE=logember-agent-test:debian12

if [[ "${1:-}" != "--in-container" ]]; then
  bin="dist/logember-agent_linux_${ARCH}"
  [[ -x "$bin" ]] || { echo "$bin not found: run scripts/build.sh first" >&2; exit 1; }
  docker build -q --platform "linux/${ARCH}" -t "$IMAGE" - >/dev/null <<'EOF'
FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-journal-remote python3 jq \
 && rm -rf /var/lib/apt/lists/*
EOF
  exec docker run --rm --platform "linux/${ARCH}" -e ARCH="$ARCH" -v "$PWD:/src:ro" -w /src "$IMAGE" \
    scripts/test-config.sh --in-container
fi

# --- inside the container ---
bin="dist/logember-agent_linux_${ARCH}"
export LOGEMBER_ENV=production LOGEMBER_INGEST_URL=http://127.0.0.1:4318 LOGEMBER_INGEST_KEY=x
TEST_WORK=$(mktemp -d)
export TEST_WORK
out="$TEST_WORK/requests.jsonl"
records="$TEST_WORK/records.jsonl"

echo "== validate"
"$bin" validate --config config/agent.yaml
"$bin" validate --config config/agent.yaml --config config/redaction.yaml

echo "== fixtures"
# the image's own apt/dpkg logs would be read too: start from an empty /var/log
rm -rf /var/log/*
cp -r test/fixtures/var/log/. /var/log/
mkdir -p /var/log/journal/fixture "$TEST_WORK/buffer"
/lib/systemd/systemd-journal-remote -o /var/log/journal/fixture/fixture.journal test/fixtures/journal.export 2>/dev/null
journalctl --directory=/var/log/journal/fixture --priority=info -q -o cat | grep -c . | sed 's/^/journal entries (priority <= info, incl. empty): /'

# Expected record count: non-empty lines of the files agent.yaml reads (auth.log is excluded)
# plus journal entries at priority info or higher with a non-empty MESSAGE.
expected_files=$(find test/fixtures/var/log -name '*.log' ! -name auth.log -exec cat {} + | grep -cv '^\s*$')
expected_journal=$(journalctl --directory=/var/log/journal/fixture --priority=info -q -o cat | grep -cv '^\s*$')
expected=$((expected_files + expected_journal))

echo "== run (expecting $expected records)"
python3 test/otlp-sink.py 4318 "$out" "$LOGEMBER_INGEST_KEY" &
sink=$!
"$bin" --config config/agent.yaml --config config/redaction.yaml --config test/agent.test.yaml >"$TEST_WORK/agent.log" 2>&1 &
agent=$!
trap 'kill $agent $sink 2>/dev/null || true' EXIT

flatten() {
  # One line per log record: body, severity, times (ns, kept as strings), attributes as {key: value};
  # non-string attribute values are tagged so the checks below catch them.
  jq -c '.resourceLogs[] | .resource as $res | .scopeLogs[].logRecords[] | {
      host: ([$res.attributes[]? | select(.key == "host.name") | .value.stringValue] | first),
      body: .body.stringValue,
      severity_text: .severityText,
      severity_number: .severityNumber,
      time: (.timeUnixNano // "0"),
      observed: (.observedTimeUnixNano // "0"),
      attrs: ([.attributes[]? | {(.key): (.value.stringValue // {nonstring: .value})}] | add // {})
    }' "$out" 2>/dev/null || true
}
count=0
for _ in $(seq 1 60); do
  sleep 1
  [[ -s "$out" ]] || continue
  count=$(flatten | wc -l)
  (( count >= expected )) && break
done
sleep 2  # anything beyond the expected count would show up now
flatten >"$records"
count=$(wc -l <"$records")
kill $agent 2>/dev/null || true

fail=0
check() {
  local name=$1 filter=$2
  if jq -se "$filter" "$records" >/dev/null; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    fail=1
  fi
}
rec() { printf '(map(select(.body | %s)) | if length == 1 then .[0] else error("expected one record") end)' "$1"; }
ns() { echo "\"$(date -u -d "$1" +%s)$2\""; }  # expected timeUnixNano as a jq string literal

echo "== checks ($count records)"
check "record count is $expected" "length == $expected"
# Schema rules for every record
check "every record: logember.service non-empty, <= 128 chars" 'all(.attrs["logember.service"] | type == "string" and length > 0 and length <= 128)'
check "every record: logember.env = production" 'all(.attrs["logember.env"] == "production")'
check "every record: severity_text in the schema enum" 'all(.severity_text | IN("trace","debug","info","warn","error","fatal"))'
# shellcheck disable=SC2016 # $n is a jq variable
check "every record: severity_number matches severity_text" 'all({"trace":1,"debug":5,"info":9,"warn":13,"error":17,"fatal":21}[.severity_text] as $n | (.severity_number == $n or .severity_number == ($n|tostring)))'
check "every record: body is a non-empty string" 'all(.body | type == "string" and test("\\S"))'
check "every record: timestamp set" 'all(.time != "0")'
check "every record: host.name set" 'all(.host | type == "string" and length > 0)'
check "every record: attribute values are strings <= 2 KB" 'all(.attrs[] | type == "string" and length <= 2048)'
check "every record: attribute keys lowercase, <= 64 keys" 'all(.attrs | keys | length <= 64 and all(. == ascii_downcase))'

# Files
check "auth.log (rsyslog copy of journald) is not read" 'all(.body | test("Accepted publickey for root") | not)'
check "nginx files -> service nginx" 'map(select(.attrs["log.file.path"] // "" | startswith("/var/log/nginx/"))) | length == 6 and all(.attrs["logember.service"] == "nginx")'
check "nginx access 200 -> info, fields, time from line" "$(rec 'contains("/api/orders")') | .severity_text == \"info\" and .attrs[\"http.response.status_code\"] == \"200\" and .attrs[\"http.request.method\"] == \"GET\" and .attrs[\"client.address\"] == \"203.0.113.10\" and .time == $(ns 2026-10-26T12:00:00Z 000000000)"
check "nginx access 404 -> warn" "$(rec 'contains("/missing")') | .severity_text == \"warn\""
check "nginx access 502 -> error, +0200 offset" "$(rec 'contains("POST /api/pay HTTP/2.0\" 502")') | .severity_text == \"error\" and .time == $(ns 2026-10-26T12:00:02Z 000000000)"
check "nginx error [error] -> error" "$(rec 'contains("connect() failed")') | .severity_text == \"error\""
check "nginx error [warn] -> warn" "$(rec 'contains("buffered to a temporary file")') | .severity_text == \"warn\""
check "nginx error [notice] -> info" "$(rec 'contains("signal process started")') | .severity_text == \"info\""
check "syslog line -> service from program, ERROR -> error" "$(rec 'contains("payment provider timed out")') | .attrs[\"logember.service\"] == \"myapp\" and .severity_text == \"error\" and .attrs[\"process.pid\"] == \"4242\""
check "syslog RFC3339 line -> service, warning: -> warn, time from line" "$(rec 'contains("disk /dev/sda1")') | .attrs[\"logember.service\"] == \"backup\" and .severity_text == \"warn\" and .time == $(ns 2026-10-26T12:00:06Z 123456000)"
check "syslog line without level -> info" "$(rec 'contains("order 1234 shipped")') | .severity_text == \"info\""
check "plain text -> service from file name, info" "$(rec 'startswith("Deploy started")') | .attrs[\"logember.service\"] == \"deploy\" and .severity_text == \"info\" and .time == .observed"
check "plain text WARN -> warn" "$(rec 'startswith("WARN cache")') | .severity_text == \"warn\""

# JSON
check "JSON level=warning -> warn, fields as flattened lowercase string attributes" "$(rec 'contains("slow query")') | .severity_text == \"warn\" and .attrs[\"logember.service\"] == \"app\" and .attrs.msg == \"slow query\" and .attrs[\"db.name\"] == \"orders\" and .attrs[\"db.durationms\"] == \"1234\" and .attrs[\"tags.0\"] == \"db\" and .attrs.cached == \"false\""
check "JSON RFC3339 with ms and Z -> time from line" "$(rec 'contains("slow query")') | .time == $(ns 2026-10-26T12:00:10Z 250000000)"
check "JSON severity=ERR, RFC3339 +02:00 -> error, time from line" "$(rec 'contains("payment failed")') | .severity_text == \"error\" and .attrs.order_id == \"1234\" and .time == $(ns 2026-10-26T12:00:11Z 000000000)"
check "JSON pino level 50, epoch seconds -> error" "$(rec 'contains("pino error")') | .severity_text == \"error\" and .time == $(ns 2026-10-26T12:00:12Z 500000000)"
check "JSON pino level 30, epoch ms -> info" "$(rec 'contains("pino info")') | .severity_text == \"info\" and .time == $(ns 2026-10-26T12:00:13Z 000000000)"
check "JSON crit, unparsable time -> error, observed time" "$(rec 'contains("unparsable time")') | .severity_text == \"error\" and .time == .observed"
check "JSON levelname CRITICAL -> fatal" "$(rec 'contains("python critical")') | .severity_text == \"fatal\""
check "JSON level panic -> fatal" "$(rec 'contains("go panic")') | .severity_text == \"fatal\""
check "JSON log.level debug -> debug" "$(rec 'contains("ecs debug")') | .severity_text == \"debug\""
check "JSON without a level field -> guessed from the line" "$(rec 'contains("no level field")') | .severity_text == \"error\" and .attrs.detail == \"ERROR budget exceeded\""
check "invalid JSON -> plain line" "$(rec 'startswith("{\"broken\"")') | .severity_text == \"info\" and .attrs[\"logember.service\"] == \"app\""
check "JSON with 82 fields -> 64 attributes incl. logember.*" "$(rec 'contains("\"wide\"")') | (.attrs | length) == 64 and .attrs[\"logember.service\"] == \"app\" and .attrs[\"logember.env\"] == \"production\""

# journald
check "journald nginx.service -> nginx, PRIORITY 3 -> error" "$(rec 'contains("bind() to 0.0.0.0:80")') | .attrs[\"logember.service\"] == \"nginx\" and .severity_text == \"error\" and .attrs[\"systemd.unit\"] == \"nginx.service\" and .time == $(ns 2026-10-26T12:00:20Z 000000000)"
check "journald ssh.service -> ssh, info" "$(rec 'contains("Accepted publickey for deploy")') | .attrs[\"logember.service\"] == \"ssh\" and .severity_text == \"info\""
check "journald kernel (no unit) -> identifier, PRIORITY 4 -> warn" "$(rec 'startswith("EXT4-fs")') | .attrs[\"logember.service\"] == \"kernel\" and .severity_text == \"warn\""
check "journald session scope -> identifier, notice -> info" "$(rec 'contains("COMMAND=/usr/bin/systemctl")') | .attrs[\"logember.service\"] == \"sudo\" and .severity_text == \"info\""
check "journald template unit postgresql@16-main.service -> postgresql" "$(rec 'contains("orders_archive")') | .attrs[\"logember.service\"] == \"postgresql\" and .severity_text == \"error\" and .attrs[\"systemd.unit\"] == \"postgresql@16-main.service\""
check "journald nothing derivable -> unknown, PRIORITY 0 -> fatal" "$(rec 'contains("without unit")') | .attrs[\"logember.service\"] == \"unknown\" and .severity_text == \"fatal\""
check "journald debug entry dropped by the priority filter" 'all(.body | contains("below the info priority") | not)'

# Redaction: none of these raw values may appear anywhere in what was sent (bodies, attributes).
secrets=(
  eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyLTQyIn0.c2lnbmF0dXJlLXNlY3JldA # bearer token
  dXNlcjpodW50ZXIy                                                   # basic auth
  hunter2                                                            # password=
  sk_live_51HxQe2KZvq8Rk3pTn9                                        # api_key:
  AKIAABCDEFGHIJKLMNOP                                               # AWS access key ID
  "4111 1111 1111 1111" 4111-1111-1111-1111 4111111111111111 "3782 822463 10005"
  jane.doe@example.com                                               # email (config/redaction.yaml)
  Zt9fQw2mX8pL4rB7aQ                                                 # ?token= in an access log
)
for secret in "${secrets[@]}"; do
  if grep -qF -- "$secret" "$out"; then
    echo "FAIL redaction: $secret was sent"
    fail=1
  else
    echo "ok   redaction: $secret not sent"
  fi
done
check "redaction keeps the key: Authorization: Bearer ****" "$(rec 'startswith("INFO calling billing")') | .body == \"INFO calling billing with Authorization: Bearer ****\""
check "redaction keeps the key: Authorization: Basic ****" "$(rec 'startswith("curl -H")') | .body == \"curl -H \\\"Authorization: Basic ****\\\" https://api.example.com/v1/charges\""
check "redaction keeps the key: password=****" "$(rec 'contains("login failed for admin")') | .body == \"WARN login failed for admin password=**** from 203.0.113.7\" and .severity_text == \"warn\""
check "redaction keeps the key: api_key: ****" "$(rec 'startswith("loaded settings")') | .body == \"loaded settings api_key: **** region=eu-west-1\""
check "redaction: AWS access key ID -> ****" "$(rec 'startswith("uploading backups")') | .body == \"uploading backups with AWS key ****\""
check "redaction: card numbers with spaces, dashes, none, Amex grouping" "$(rec 'startswith("retried card")') | .body == \"retried card ****, then ****, then amex ****\""
check "redaction: email via config/redaction.yaml" "$(rec 'startswith("password reset mail")') | .body == \"password reset mail sent to ****\""
check "redaction: ?token= in the body and in url.path" "$(rec 'contains("GET /reset")') | (.body | contains(\"/reset?token=**** HTTP\")) and .attrs[\"url.path\"] == \"/reset?token=****\""
check "redaction: JSON line body keeps its structure" "$(rec 'contains("outgoing request")') | .body == \"{\\\"level\\\":\\\"info\\\",\\\"msg\\\":\\\"outgoing request\\\",\\\"headers\\\":{\\\"Authorization\\\":\\\"Bearer ****\\\"},\\\"user\\\":{\\\"email\\\":\\\"****\\\",\\\"password\\\":\\\"****\\\"},\\\"api_key\\\":\\\"****\\\",\\\"aws_access_key_id\\\":\\\"****\\\",\\\"card\\\":\\\"****\\\",\\\"note\\\":\\\"retry with password=****\\\"}\""
check "redaction: JSON fields as attributes" "$(rec 'contains("outgoing request")') | .attrs.msg == \"outgoing request\" and .attrs[\"headers.authorization\"] == \"****\" and .attrs[\"user.password\"] == \"****\" and .attrs[\"user.email\"] == \"****\" and .attrs.api_key == \"****\" and .attrs.aws_access_key_id == \"****\" and .attrs.card == \"****\" and .attrs.note == \"retry with password=****\""
# ...and lines that only look like secrets pass through unchanged.
while IFS= read -r line; do
  if jq -se --arg line "$line" 'map(select(.body == $line)) | length == 1' "$records" >/dev/null; then
    echo "ok   unchanged: ${line:0:60}"
  else
    echo "FAIL changed: $line"
    fail=1
  fi
done <test/fixtures/var/log/redaction-clean.log
check "unchanged: timestamp and request id in url.path" "$(rec 'contains("/api/invoices/1793016013123")') | .attrs[\"url.path\"] == \"/api/invoices/1793016013123?trace=4821-1793016000123\""
check "unchanged: JSON ms timestamp, trace id, UUID, max_tokens" "$(rec 'contains("\"completion\"")') | .attrs.sent_at_ms == \"1793016013123\" and .attrs.trace_id == \"4bf92f3577b34da6a3ce929d0e0e4736\" and .attrs.request_id == \"8f14e45f-ceea-4672-9123-456789012345\" and .attrs.max_tokens == \"4096\" and .attrs.tokens_used == \"1200\""

if (( fail )); then
  echo "-- agent log"; cat "$TEST_WORK/agent.log"
  echo "-- records"; cat "$records"
  exit 1
fi
echo "all checks passed"
