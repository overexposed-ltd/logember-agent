#!/usr/bin/env bash
# Network loss test for the disk buffer and retries of config/agent.yaml.
#
# Runs the built agent in a throwaway Debian 12 container (like scripts/test-config.sh) against
# test/otlp-sink.py, a local OTLP/HTTP sink that can be stopped or told to answer 429/503:
#   1. outage: sink stopped, 10,000 numbered marker lines written, the agent restarted twice
#      during the outage (SIGTERM, then SIGKILL), sink back after $OUTAGE seconds (default 600)
#      -> every marker arrives; duplicates are counted; the journald and file read positions
#      survive the restarts; the buffer directory stays under the cap
#   2. throttling: the sink answers 429 (Retry-After: 20) twice, then 503 twice
#      -> retried, nothing dropped, the next attempt after a 429 waits for Retry-After
#   3. full queue: with the queue cut down to 32 MiB (file cap 64 MiB), 150,000 lines (~50 MiB
#      of OTLP) are written during an outage -> the buffer stays under the cap, the receivers wait
#      instead of dropping, and every line arrives once the sink is back
#   4. the same, but the agent is restarted while the queue is full -> at most the one batch the
#      file receiver was waiting to enqueue (100 lines) is lost; this is the documented limit
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
  exec docker run --rm --platform "linux/${ARCH}" -e ARCH="$ARCH" -e OUTAGE="${OUTAGE:-600}" \
    -v "$PWD:/src:ro" -w /src "$IMAGE" test/buffering.sh --in-container
fi

# --- inside the container ---
bin="dist/logember-agent_linux_${ARCH}"
export LOGEMBER_ENV=production LOGEMBER_INGEST_URL=http://127.0.0.1:4318 LOGEMBER_INGEST_KEY=x
TEST_WORK=$(mktemp -d)
export TEST_WORK
buffer="$TEST_WORK/buffer"
out="$TEST_WORK/requests.jsonl"
plan="$TEST_WORK/plan"
access="$TEST_WORK/access.log"
agent_log="$TEST_WORK/agent.log"
sink=0 agent=0 sampler=0
trap 'kill $agent $sink $sampler 2>/dev/null || true' EXIT

# Agent logs at info, so retries ("Exporting failed. Will retry") show up in the agent log.
cat >"$TEST_WORK/info.yaml" <<'EOF'
service:
  telemetry:
    logs: { level: info }
EOF
# Phase 3: the same pipeline with a small queue and file cap, so the cap is reached quickly.
cat >"$TEST_WORK/small-cap.yaml" <<'EOF'
extensions:
  file_storage:
    max_size: 67108864   # 64 MiB
    compaction:
      rebound_needed_threshold_mib: 16
      rebound_trigger_threshold_mib: 1
exporters:
  otlphttp:
    sending_queue:
      queue_size: 33554432   # 32 MiB
EOF

rm -rf /var/log/*
mkdir -p /var/log/journal/fixture "$buffer"
/lib/systemd/systemd-journal-remote -o /var/log/journal/fixture/fixture.journal test/fixtures/journal.export 2>/dev/null
expected_journal=$(journalctl --directory=/var/log/journal/fixture --priority=info -q -o cat | grep -cv '^\s*$')

start_sink() {
  python3 test/otlp-sink.py 4318 "$out" "$LOGEMBER_INGEST_KEY" "$plan" "$access" &
  sink=$!
  sleep 0.5
  echo "$(date +%T) sink up"
}
stop_sink() {
  kill "$sink" && wait "$sink" 2>/dev/null || true
  echo "$(date +%T) sink down"
}
start_agent() {
  echo "--- $(date +%T) agent start $*" >>"$agent_log"
  "$bin" --config config/agent.yaml --config test/agent.test.yaml --config "$TEST_WORK/info.yaml" "$@" >>"$agent_log" 2>&1 &
  agent=$!
}
# stop_agent TERM|KILL: prints how long the agent took to exit
stop_agent() {
  local start=$SECONDS
  kill "-$1" "$agent"
  wait "$agent" 2>/dev/null || true
  echo "$(date +%T) agent stopped with SIG$1 in $((SECONDS - start))s"
}
bodies() { jq -r '.resourceLogs[].scopeLogs[].logRecords[].body.stringValue' "$out" 2>/dev/null || true; }
lines() { bodies | awk -v p="$1 " 'index($0, p) == 1'; }  # received lines starting with "PREFIX "
# wait_for PREFIX COUNT TIMEOUT: waits until COUNT distinct "PREFIX n" lines have arrived, or
# nothing has arrived for 120 s (longer than the largest retry interval), or TIMEOUT seconds have passed
wait_for() {
  local n=0 size=-1 idle_since=$SECONDS start=$SECONDS
  while (( SECONDS - start < $3 && SECONDS - idle_since < 120 )); do
    if (( $(stat -c %s "$out") != size )); then
      size=$(stat -c %s "$out")
      idle_since=$SECONDS
      n=$(lines "$1" | sort -u | wc -l)
      (( n >= $2 )) && break
    fi
    sleep 2
  done
  echo "$(date +%T) $n distinct '$1' lines arrived"
}
# Samples the buffer directory size (apparent bytes, so sparse bbolt files count in full) every
# 0.5 s; the largest value is kept in $TEST_WORK/max_buffer.
start_sampler() {
  echo 0 >"$TEST_WORK/max_buffer"
  ( while :; do
      size=$(du -sb "$buffer" | cut -f1)
      (( size > $(cat "$TEST_WORK/max_buffer") )) && echo "$size" >"$TEST_WORK/max_buffer"
      sleep 0.5
    done ) &
  sampler=$!
}
stop_sampler() { kill "$sampler" 2>/dev/null || true; wait "$sampler" 2>/dev/null || true; }
write_lines() {  # write_lines FILE PREFIX FROM TO [PADDING]
  local pad=${5:-}
  seq "$3" "$4" | sed "s/.*/$2 &${pad:+ $pad}/" >>"$1"
}

# "Exporting failed. Dropping data." is also logged for requests that were being sent when the agent
# stopped ("interrupted due to shutdown"); those stay in the disk queue and are sent after the restart.
dropped() { awk '/Dropping data/ && !/interrupted due to shutdown/ {found = 1} END {exit !found}' "$agent_log"; }
show_buffer() {
  du -sb "$buffer"/* | sed 's/^/  buffer: /'
  python3 -c 'import urllib.request; print(urllib.request.urlopen("http://localhost:8888/metrics").read().decode())' 2>/dev/null |
    grep -E '^otelcol_exporter_queue_(size|capacity)' | sed 's/{.*}//; s/^/  metric: /' || true
}
pad=$(printf 'x%.0s' $(seq 1 200))

fail=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

echo "== 1. outage of ${OUTAGE}s with two agent restarts"
start_sink
start_agent
for _ in $(seq 1 30); do
  (( $(bodies | wc -l) >= expected_journal )) && break
  sleep 1
done
journal_before=$(bodies | wc -l)
echo "$(date +%T) agent is shipping ($journal_before journal records)"
start_sampler
stop_sink
outage_start=$SECONDS
write_lines /var/log/markers.log marker 1 5000
sleep 15
stop_agent TERM
start_agent
write_lines /var/log/markers.log marker 5001 10000
sleep 15
stop_agent KILL
start_agent
show_buffer
remaining=$((OUTAGE - (SECONDS - outage_start)))
echo "$(date +%T) waiting ${remaining}s for the outage to end"
(( remaining > 0 )) && sleep "$remaining"
start_sink
wait_for marker 10000 300
stop_sampler
max1=$(cat "$TEST_WORK/max_buffer")
markers_total=$(lines marker | wc -l)
markers_unique=$(lines marker | sort -u | wc -l)
journal_total=$(bodies | awk '!/^marker /' | wc -l)
echo "  markers received: $markers_total ($markers_unique distinct, $((markers_total - markers_unique)) duplicates)"
echo "  journal records received: $journal_total (fixture has $expected_journal)"
echo "  largest buffer directory: $max1 bytes"
check "all 10000 markers arrived" "(( $markers_unique == 10000 ))"
check "no journald record sent twice (cursor survived both restarts)" "(( $journal_total == $expected_journal ))"
check "nothing dropped" "! dropped"
check "buffer directory stayed under the 1 GiB cap" "(( $max1 < 1073741824 ))"

echo "== 2. 429 with Retry-After, then 503"
# Retry-After: 20 is longer than the first two backoff intervals (5 s and 7.5 s, +-50 % jitter),
# so a gap of 20 s after each 429 shows the header was followed.
printf '429 20\n429 20\n503\n503\n' >"$plan"
: >"$access"
write_lines /var/log/markers.log throttle 1 2000
wait_for throttle 2000 120
awk 'NR==1{t=$1} {printf "  %+7.2fs %s\n", $1-t, $2}' "$access" | head -12
throttle_unique=$(lines throttle | sort -u | wc -l)
statuses=$(awk '{print $2}' "$access" | head -4 | tr '\n' ' ')
# shortest gap between a 429 and the request after it
min_gap=$(awk 'prev==429{g=$1-pt; if(min==""||g<min)min=g} {prev=$2; pt=$1} END{print min+0}' "$access")
check "sink answered 429 twice, then 503 twice" "[[ '$statuses' == '429 429 503 503 ' ]]"
check "all 2000 lines arrived after the 429s and 503s" "(( $throttle_unique == 2000 ))"
check "retry after a 429 waited for Retry-After: 20 (shortest gap ${min_gap}s)" "awk 'BEGIN{exit !($min_gap >= 19.9)}'"
check "nothing dropped" "! dropped"
check "markers were not sent again (file offsets survived)" "(( $(lines marker | wc -l) == $markers_total ))"

echo "== 3. full queue: 32 MiB queue, 64 MiB file cap, 150,000 lines"
stop_agent TERM
start_agent --config "$TEST_WORK/small-cap.yaml"
sleep 2
start_sampler
stop_sink
write_lines /var/log/cap.log cap 1 150000 "$pad"
sleep 30
show_buffer
start_sink
wait_for cap 150000 300
stop_sampler
sleep 10
echo "  after draining (rebound compaction gives the space back):"
show_buffer
max3=$(cat "$TEST_WORK/max_buffer")
cap_total=$(lines cap | wc -l)
cap_unique=$(lines cap | sort -u | wc -l)
echo "  cap lines received: $cap_total ($cap_unique distinct, $((cap_total - cap_unique)) duplicates)"
echo "  largest buffer directory: $max3 bytes"
check "buffer directory stayed under the 64 MiB file cap" "(( $max3 < 67108864 ))"
check "all 150000 lines arrived (receivers waited, nothing dropped)" "(( $cap_unique == 150000 ))"
check "nothing dropped" "! dropped"

echo "== 4. agent restarted while the queue is full"
stop_sink
write_lines /var/log/cap.log full 1 150000 "$pad"
sleep 30
show_buffer
stop_agent TERM
start_agent --config "$TEST_WORK/small-cap.yaml"
sleep 5
start_sink
wait_for full 150000 300
full_unique=$(lines full | sort -u | wc -l)
full_total=$(lines full | wc -l)
echo "  lines received: $full_total ($full_unique distinct, $((full_total - full_unique)) duplicates)"
echo "  lost: $((150000 - full_unique)) (the batch the file receiver was waiting to enqueue when it was stopped)"
check "at most one receiver batch (100 lines) lost" "(( 150000 - $full_unique <= 100 ))"

echo "== agent log (warnings and errors)"
# message of each warning/error line, counted (field 4 of the console log format)
awk -F'\t' '$2 == "warn" || $2 == "error" {print $2, $4}' "$agent_log" | sort | uniq -c | sort -rn
echo "== retries logged: $(grep -c 'Will retry' "$agent_log" || true)"

if (( fail )); then
  echo "-- agent log"; tail -50 "$agent_log"
  exit 1
fi
echo "all checks passed"
