# PLAN: v0.1.0

## Goal

`curl -fsSL https://get.logember.com | sudo bash -s -- --token X` on a clean Ubuntu 24.04 or Debian 12 host (amd64, arm64) installs the agent, enrolls it with the hub, ships journald, /var/log, nginx and Docker container logs over OTLP to ingest, buffers on disk while the network is down, and redacts secrets before anything leaves the host.

## Cards (in order)

Ready now (no dependencies):

1. [build] Pin Collector version in builder-config.yaml, first ocb build
2. [question] Default hub/ingest URLs and get.logember.com for v0.1.0
3. [question] .deb/.rpm in v0.1.0 or binaries + install.sh only
4. [question] Docker-only hosts: container image in v0.1.0?
5. [question] Hub config polling and heartbeat in v0.1.0?
6. [question] install.sh: sh (no pipefail) or bash one-liner
7. [question] Smoke test target: staging or mock hub/ingest

Backlog (starts when its dependencies are done):

8. [config] agent.yaml passes validate and matches log-schema.json (after 1)
9. [redaction] Redact secrets in body and attributes before export (after 8)
10. [docker] Container logs via filelog on /var/lib/docker/containers (after 8)
11. [config] Verify disk buffering and retry during network loss (after 8)
12. [install] Harden install.sh: shellcheck, verified assets, --version, idempotent (after 1, 2, 6)
13. [install] uninstall.sh (after 12)
14. [ci] GitHub Actions: build amd64/arm64, shellcheck, validate (after 1, 8)
15. [release] Release workflow on tag v* (after 14, 12, 3)
16. [ci] Smoke test: install on Ubuntu 24.04 / Debian 12, first line arrives (after 12, 15, 9, 7)
17. [docs] README: Docker-only hosts, self-hosted hub, v0.1.0 accuracy (after 12, 10, 4, 5)

v0.1.0 is tagged when 16 is green on all four distro/arch combinations.

## Decisions

Made 2026-10-26 on the owner's delegation; they answer the former open questions.

- Default URLs: hub https://app.logember.com, ingest https://ingest.logember.com. get.logember.com is hosted outside this repo and must serve the release asset install.sh.
- Packaging: raw binaries + checksums.txt + install.sh/uninstall.sh and config files as release assets. No .deb/.rpm, no tarball in v0.1.0.
- Docker-only hosts: no container image in v0.1.0. Install the agent on the host; container logs are collected from /var/lib/docker/containers.
- Hub config polling (GET /v1/agent/config) and heartbeat: as decided in the monorepo (logember/PLAN.md, Q2), a small POSIX shell script `logember-agent-sync` + systemd timer every 5 minutes, since no OTel component speaks this REST API (OpAMP supervisor is a Phase 1 candidate). Not part of the v0.1.0 scope on this board: it is the next step (v0.2.0, still Phase 0 in the monorepo). Redaction rules from the hub are not supported; they come only from /etc/logember/redaction.yaml.
- Shell: install.sh and uninstall.sh are bash with `set -euo pipefail` (`#!/usr/bin/env bash`, shellcheck -s bash); the one-liner is `curl -fsSL https://get.logember.com | sudo bash -s -- --token X`. Run via sh, the scripts stop with a "needs bash" message.
- Smoke test: self-contained mock in CI (mock POST /v1/enroll + OTLP sink container) on every run; a manual workflow_dispatch job against staging is optional and may stay a stub.

## After v0.1.0 (v0.2.0)

- [sync] Hub config polling and heartbeat: logember-agent-sync + logember-agent-sync.timer (every 5 minutes) fetch GET /v1/agent/config into /etc/logember/sources.yaml and send POST /v1/agent/heartbeat. Done.

## Log

- 2026-10-26: plan created; 17 cards on the Kanban board (11 work cards, 6 questions).
- 2026-10-26: [config] agent.yaml validates and maps journald and file logs onto log-schema.json; scripts/test-config.sh checks it against fixtures. journald is the source for system logs; rsyslog copies in /var/log are not read.
- 2026-10-26: [docker] Container logs from /var/lib/docker/containers (json-file), service = container name via docker_observer + receiver_creator (config/docker.yaml, loaded only when the Docker API is reachable), else the short container ID; files read with CAP_DAC_READ_SEARCH. The release workflow publishes config/docker.yaml as the `docker.yaml` asset.
- 2026-10-26: [docs] README matches v0.1.0: install options, files on the host, disk buffer (5000 requests, no byte cap), Docker-only hosts (install on the host, no image), self-hosted hub (--hub/--ingest/--env, POST /v1/enroll, OTLP /v1/logs, TLS via the system CA store), tested platforms (Ubuntu 24.04, Debian 12). Open questions moved to Decisions. Hub config sync is not documented yet; its card adds that.
- 2026-10-26: [ci] Smoke test (test/smoke/run.sh, .github/workflows/smoke.yml): real install in a privileged systemd container (Ubuntu 24.04, Debian 12; amd64 on ubuntu-24.04, arm64 on ubuntu-24.04-arm) against a mock POST /v1/enroll and an otelcol-contrib OTLP sink; checks the marker from /var/log and logger, then uninstall --purge. Runs on PRs touching install/config/build, after Release, and manually; the staging target is a stub.
- 2026-10-26: [sync] logember-agent-sync (POSIX sh) + timer every 5 minutes: GET /v1/agent/config with If-None-Match into /etc/logember/sources.yaml (one filelog receiver per hub file, own pipeline logs/hub, service from the hub), validated before the agent is restarted; then POST /v1/agent/heartbeat (version, systemctl is-active, buffer size). scripts/test-sync.sh tests it against a mock hub; tested end to end against the real hub on Debian 12 with systemd. README documents it; test/smoke/run.sh now also checks the first sync, the heartbeat and a line from a hub source.
