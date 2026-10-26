# logember-agent

The agent that ships your servers' logs to [LogEmber](https://logember.com). It is a thin wrapper around the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/): one binary, one config file, one systemd unit. Everything it sends is visible in `config/agent.yaml`, and everything it redacts before sending is visible in `config/redaction.yaml`.

```bash
curl -fsSL https://get.logember.com | sudo sh -s -- --token <ENROLLMENT_TOKEN>
```

## What it does

1. On first start it exchanges the one-time enrollment token for a per-host ingest key (`POST /v1/enroll`), stored in `/etc/logember/credentials` (mode 600).
2. It tails `journald`, `/var/log/*.log`, `/var/log/nginx/*.log` and Docker containers (when `/var/run/docker.sock` exists). Extra paths come from the hub (`GET /v1/agent/config`, polled every 5 minutes).
3. Each line gets `host`, `service` (from the file path or container name), `env` and a parsed `severity`. JSON lines are unpacked into attributes.
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

Requires Go (any version ≥ 1.21) and curl. `scripts/build.sh` downloads the pinned [ocb](https://opentelemetry.io/docs/collector/custom-collector/) release (checksum-verified), builds with the pinned Go toolchain via `GOTOOLCHAIN`, and produces `dist/logember-agent_linux_{amd64,arm64}` plus `dist/checksums.txt`. Set `VERSION` to override the version taken from `git describe --tags`. Releases are published on GitHub Releases; `install.sh` always fetches the latest tagged version unless `--version` is given.

The wire format and the record schema live in the main LogEmber repo under `proto/`.

## License

Apache-2.0 (see `LICENSE`).
