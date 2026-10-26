# logember-agent

The agent that ships your servers' logs to [LogEmber](https://logember.com). It is a thin wrapper around the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/): one binary, one config file, one systemd unit. Everything it sends and everything it redacts before sending is visible in `config/agent.yaml`; your own redaction rules go in `config/redaction.yaml`.

```bash
curl -fsSL https://get.logember.com | sudo bash -s -- --token <ENROLLMENT_TOKEN>
```

## What it does

1. On the first install, `install.sh` exchanges the one-time enrollment token for a per-host ingest key (`POST /v1/enroll`), stored as `LOGEMBER_INGEST_KEY` in `/etc/logember/agent.env` (mode 600, read by systemd as the unit's `EnvironmentFile`). Re-running the script upgrades the agent and keeps the key; `--help` lists the options.
2. It tails `journald`, `/var/log/*.log`, `/var/log/nginx/*.log` and Docker containers (see [Docker](#docker)). Files that rsyslog copies from journald (`/var/log/syslog`, `auth.log`, `kern.log`, ...) are skipped so nothing is sent twice. Extra paths come from the hub (`GET /v1/agent/config`, polled every 5 minutes).
3. Each line gets `host`, `service` (systemd unit, program name, file path, container name or short container ID; `unknown` if none), `env` and a `severity` (`trace`…`fatal`, from the journald priority, a JSON `level` field or the text of the line). JSON lines are unpacked into attributes (flattened, lowercase dotted keys, string values, at most 64).
4. Secrets are redacted on the host, before anything leaves it, in the log line and in every attribute: `Authorization` headers and bearer tokens, `password=…`, `api_key: …`, `"token":"…"` and similar (the key stays, the value becomes `****`), attributes named like a secret, AWS access key IDs, card numbers, email addresses, plus your own rules (see [Redaction](#redaction)).
5. Lines are batched (1 MB or 5 s) and sent over OTLP/HTTP with zstd to `https://ingest.logember.com/v1/logs`. If the network is down they are buffered on disk and retried with backoff.

## Docker

Container logs are read from the files of Docker's default `json-file` log driver, `/var/lib/docker/containers/<id>/<id>-json.log`. Each line is unpacked: the body is the line the container wrote, `stream` (`stdout`/`stderr`) becomes an attribute, the time comes from Docker, and JSON lines and severities are handled like any other source. Lines longer than 16 KiB, which Docker splits, are joined again.

- **Service name.** The log files do not name their container, so the agent asks the Docker API: when `/run/docker.sock` exists and the `logember` user may use it, the unit also loads `config/docker.yaml` (`docker_observer` + `receiver_creator`), and `service` is the container name, with `container.name` and `container.image.name` as attributes. Otherwise `service` is the short container ID. `install.sh` adds `logember` to the `docker` group when it exists; if you install Docker after the agent, re-run `install.sh` to get container names. Note that access to the Docker socket is root-equivalent; leave `logember` out of the `docker` group if you prefer container IDs over names.
- **File permissions.** `/var/lib/docker/containers` is `root` 0710 and the log files are `root` 0640, so no group can read them. The unit gives the agent `CAP_DAC_READ_SEARCH` (read and list any file, no write access, no other capability) and hides credential files (`/etc/shadow`, `/etc/gshadow`, `/etc/sudoers*`, `/etc/ssh`) from it, on top of `ProtectSystem=strict` and `ProtectHome=true`.
- **Without Docker** nothing changes: the glob matches no files and `docker.yaml` is not loaded.
- **Limits.** Lines a new container writes in the second before the agent starts following it are not read. Only the `json-file` driver under the default data root is read; `journald` and other log drivers, Kubernetes and Docker-only hosts are not covered.

## Layout

```
install.sh            the script behind get.logember.com: detects distro/arch, downloads the release, writes config, enables the unit
uninstall.sh          stops and removes the agent; --purge also removes its config, disk buffer and user
config/agent.yaml     OpenTelemetry Collector pipeline (receivers → processors → otlphttp exporter)
config/docker.yaml    overlay that names Docker containers through the Docker API (loaded when it is reachable)
config/redaction.yaml the host's own redaction rules (/etc/logember/redaction.yaml, kept on upgrade)
deploy/logember-agent.service   systemd unit
scripts/build.sh      builds the collector binary with ocb (only the components in config/)
```

## Redaction

The built-in rules live in `config/agent.yaml` (processors `transform/redact` and `redaction`) and are updated with the agent. Rules of your own go in `/etc/logember/redaction.yaml`, which the systemd unit passes to the agent as a second `--config` file. `install.sh` writes it on the first install only and never overwrites it, so your edits survive upgrades. Out of the box it masks email addresses; delete that rule if you need them.

Each rule is a regular expression ([RE2 syntax](https://github.com/google/re2/wiki/Syntax)); every match in the log line and in every attribute value is replaced with `****`. To add one:

```yaml
# /etc/logember/redaction.yaml
processors:
  redaction/local:
    blocked_values:
      - '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,6}\b'
      - '\bcus_[A-Za-z0-9]{14}\b'   # added: Stripe customer IDs
```

```bash
sudo bash -c 'set -a; . /etc/logember/agent.env; logember-agent validate \
  --config /etc/logember/agent.yaml --config /etc/logember/redaction.yaml'
sudo systemctl restart logember-agent
```

Use single quotes around each rule and write a literal `$` as `$$`. Card numbers are recognized by issuer prefix and length, without a Luhn check; Unix timestamps and snowflake IDs (which start with 1) are not touched.

## Uninstall

```bash
curl -fsSL https://github.com/overexposed-ltd/logember-agent/releases/latest/download/uninstall.sh | sudo bash
```

This stops and disables the unit and removes `/usr/local/bin/logember-agent` and the unit file. `/etc/logember` (config, your redaction rules, the ingest key) and `/var/lib/logember` (the disk buffer) are kept, so installing again picks up where it left off. Add `-s -- --purge` to remove them and the `logember` user as well. Running it again is harmless.

The script does not revoke the ingest key: remove the host in the hub to do that.

## Supported platforms

Linux amd64 / arm64 with systemd (Debian, Ubuntu, RHEL/Alma/Rocky, Fedora). Docker-only hosts: run the agent as a container with `/var/log` and the Docker socket mounted (compose example coming with the first release).

## Development

Requires Go (any version ≥ 1.21) and curl. `scripts/build.sh` downloads the pinned [ocb](https://opentelemetry.io/docs/collector/custom-collector/) release (checksum-verified), builds with the pinned Go toolchain via `GOTOOLCHAIN`, and produces `dist/logember-agent_linux_{amd64,arm64}` plus `dist/checksums.txt`. Set `VERSION` to override the version taken from `git describe --tags`. `scripts/test-config.sh` then runs the built binary in a Debian 12 container against the sample logs in `test/fixtures` and checks every record it sends against the record schema (needs Docker and jq). Releases are published on GitHub Releases; `install.sh` always fetches the latest tagged version unless `--version` is given.

The wire format and the record schema live in the main LogEmber repo under `proto/`.

## License

Apache-2.0 (see `LICENSE`).
