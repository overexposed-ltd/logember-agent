# logember-agent

The agent that ships your servers' logs to [LogEmber](https://logember.com). It is a thin wrapper around the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/): one binary, one config file, one systemd unit. Everything it sends is visible in `config/agent.yaml`, and everything it redacts before sending is visible in `config/redaction.yaml`.

```bash
curl -fsSL https://get.logember.com | sudo bash -s -- --token <ENROLLMENT_TOKEN>
```

## What it does

1. On the first install, `install.sh` exchanges the one-time enrollment token for a per-host ingest key (`POST /v1/enroll`), stored as `LOGEMBER_INGEST_KEY` in `/etc/logember/agent.env` (mode 600, read by systemd as the unit's `EnvironmentFile`). Re-running the script upgrades the agent and keeps the key; `--help` lists the options.
2. It tails `journald`, `/var/log/*.log`, `/var/log/nginx/*.log` and Docker containers (when `/var/run/docker.sock` exists). Files that rsyslog copies from journald (`/var/log/syslog`, `auth.log`, `kern.log`, ...) are skipped so nothing is sent twice. Extra paths come from the hub (`GET /v1/agent/config`, polled every 5 minutes).
3. Each line gets `host`, `service` (systemd unit, program name, file path or container name; `unknown` if none), `env` and a `severity` (`trace`…`fatal`, from the journald priority, a JSON `level` field or the text of the line). JSON lines are unpacked into attributes (flattened, lowercase dotted keys, string values, at most 64).
4. Secrets are redacted on the host, before anything leaves it: bearer tokens, `password=…`, AWS keys, card numbers, plus your own rules.
5. Lines are batched (1 MB or 5 s) and sent over OTLP/HTTP with zstd to `https://ingest.logember.com/v1/logs`. If the network is down they are buffered on disk and retried with backoff.

## Layout

```
install.sh            the script behind get.logember.com: detects distro/arch, downloads the release, writes config, enables the unit
config/agent.yaml     OpenTelemetry Collector pipeline (receivers → processors → otlphttp exporter)
config/redaction.yaml default redaction rules (merged with rules from the hub)
deploy/logember-agent.service   systemd unit
scripts/build.sh      builds the collector binary with ocb (only the components in config/)
```

## Supported platforms

Linux amd64 / arm64 with systemd (Debian, Ubuntu, RHEL/Alma/Rocky, Fedora). Docker-only hosts: run the agent as a container with `/var/log` and the Docker socket mounted (compose example coming with the first release).

## Development

Requires Go (any version ≥ 1.21) and curl. `scripts/build.sh` downloads the pinned [ocb](https://opentelemetry.io/docs/collector/custom-collector/) release (checksum-verified), builds with the pinned Go toolchain via `GOTOOLCHAIN`, and produces `dist/logember-agent_linux_{amd64,arm64}` plus `dist/checksums.txt`. Set `VERSION` to override the version taken from `git describe --tags`. `scripts/test-config.sh` then runs the built binary in a Debian 12 container against the sample logs in `test/fixtures` and checks every record it sends against the record schema (needs Docker and jq). Releases are published on GitHub Releases; `install.sh` always fetches the latest tagged version unless `--version` is given.

The wire format and the record schema live in the main LogEmber repo under `proto/`.

## License

Apache-2.0 (see `LICENSE`).
