# PLAN: v0.1.0

## Goal

`curl -fsSL https://get.logember.com | sudo sh -s -- --token X` on a clean Ubuntu 24.04 or Debian 12 host (amd64, arm64) installs the agent, enrolls it with the hub, ships journald, /var/log, nginx and Docker container logs over OTLP to ingest, buffers on disk while the network is down, and redacts secrets before anything leaves the host.

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

## Open questions

- Default hub and ingest URLs, and whether /v1/enroll and /v1/logs are live there at release time; who serves get.logember.com.
- .deb/.rpm packages in v0.1.0, or binaries + install.sh only.
- Docker-only hosts: publish an agent container image, or document "install on the host".
- Hub config polling (GET /v1/agent/config) and heartbeat: in v0.1.0 or later. No ready OTel component for this API.
- install.sh shell: `set -euo pipefail` needs bash; `sh` on Debian/Ubuntu is dash.
- Smoke test target: staging hub/ingest or a mock in CI.

## Log

- 2026-10-26: plan created; 17 cards on the Kanban board (11 work cards, 6 questions).
- 2026-10-26: [config] agent.yaml validates and maps journald and file logs onto log-schema.json; scripts/test-config.sh checks it against fixtures. journald is the source for system logs; rsyslog copies in /var/log are not read.
- 2026-10-26: [docker] Container logs from /var/lib/docker/containers (json-file), service = container name via docker_observer + receiver_creator (config/docker.yaml, loaded only when the Docker API is reachable), else the short container ID; files read with CAP_DAC_READ_SEARCH. The release workflow publishes config/docker.yaml as the `docker.yaml` asset.
