# logember-agent

The agent that ships your servers' logs to [LogEmber](https://logember.com). It is a thin wrapper around the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/): one binary, one config file, one systemd unit (plus a timer that syncs with the hub). Everything it sends and everything it redacts before sending is visible in `config/agent.yaml`; your own redaction rules go in `config/redaction.yaml`.

```bash
curl -fsSL https://get.logember.com | sudo bash -s -- --token <ENROLLMENT_TOKEN>
```

Create the enrollment token in the hub under Settings → Keys → Enrollment token. The script needs bash: piped into `sh` (dash on Debian and Ubuntu) it stops with a "needs bash" message and changes nothing.

## What it does

1. `install.sh` downloads the release from GitHub Releases and checks every file against the release's `checksums.txt` before writing anything. On the first install it exchanges the one-time enrollment token for a per-host ingest key (`POST /v1/enroll` on the hub) and stores it in `/etc/logember/agent.env` (see [Files on the host](#files-on-the-host)). It also creates the `logember` system user, enables the `logember-agent` systemd unit, waits until the agent stays running, and starts `logember-agent-sync.timer` (see [Sources from the hub and heartbeat](#sources-from-the-hub-and-heartbeat)).
2. The agent reads `journald` (priority `info` and above), `/var/log/*.log`, `/var/log/nginx/*.log` and Docker containers (see [Docker](#docker)), starting at the end of each source, so older lines are not sent. Files that rsyslog copies from journald (`/var/log/syslog`, `auth.log`, `kern.log`, ...) are skipped so nothing is sent twice. Files you add in the hub are read too, within 5 minutes and without a restart by hand.
3. Each record gets the attributes `logember.service` (systemd unit, program name, file name, container name or short container ID; `unknown` if none) and `logember.env` (`--env`), the resource attribute `host.name`, and a severity (`trace`…`fatal`, from the journald priority, a JSON `level` field or the text of the line). JSON lines are unpacked into attributes (flattened, lowercase dotted keys, string values, at most 64). The schema is `proto/log-schema.json` in the main LogEmber repo.
4. Secrets are redacted on the host, before anything leaves it, in the log line and in every attribute: `Authorization` headers and bearer tokens, `password=…`, `api_key: …`, `"token":"…"` and similar (the key stays, the value becomes `****`), attributes named like a secret, AWS access key IDs, card numbers, email addresses, plus your own rules (see [Redaction](#redaction)).
5. Records are batched (8192 records or 5 s, at most 16384 per request) and sent over OTLP/HTTP (protobuf, zstd) to `https://ingest.logember.com/v1/logs`. If ingest cannot be reached they wait in a queue on disk and are retried with backoff (see [Disk buffer](#disk-buffer)).

The hub is contacted by `install.sh`, for enrollment, and every 5 minutes by `logember-agent-sync`, for the sources and a heartbeat; the collector itself talks to ingest only. Nothing listens on a network port except the collector's own metrics endpoint on `localhost:8888`.

## Install options

| Option | Default | |
|---|---|---|
| `--token TOKEN` | | Enrollment token. Required on the first install and with `--reenroll`. |
| `--version vX.Y.Z` | `latest` | Release to install, e.g. `v0.1.0`. `latest` is the newest release that is not a pre-release. |
| `--hub URL` | `https://api.logember.com` | Hub to enroll with (see [Self-hosted hub](#self-hosted-hub)). |
| `--ingest URL` | `https://ingest.logember.com` | Where logs are sent. |
| `--env NAME` | `production` | Value of `logember.env` on every record. Letters, digits, `.`, `_`, `-`. |
| `--reenroll` | | Enroll again even though the host already has an ingest key. |

Re-running the script upgrades the agent: the binary, `logember-agent-sync`, `/etc/logember/agent.yaml`, `docker.yaml` and the units are replaced, then the agent restarts. The ingest key is kept, so no token is needed:

```bash
curl -fsSL https://get.logember.com | sudo bash
```

`--hub`, `--ingest` and `--env` default to the values already in `agent.env`, so an upgrade keeps them; pass one to change it (for example `-s -- --env staging`). `/etc/logember/redaction.yaml` is never replaced.

Check that the agent runs and see its own log:

```bash
systemctl status logember-agent
journalctl -u logember-agent -n 50 --no-pager
```

## Files on the host

| Path | What | Upgrade | Uninstall |
|---|---|---|---|
| `/usr/local/bin/logember-agent` | the collector binary | replaced | removed |
| `/usr/local/bin/logember-agent-sync` | sources from the hub and heartbeat (POSIX sh) | replaced | removed |
| `/etc/systemd/system/logember-agent.service` | systemd unit | replaced | removed |
| `/etc/systemd/system/logember-agent-sync.{service,timer}` | runs `logember-agent-sync` every 5 minutes | replaced | removed |
| `/etc/logember/agent.yaml` | pipeline (`config/agent.yaml`) | replaced | kept, `--purge` removes |
| `/etc/logember/docker.yaml` | Docker container names (`config/docker.yaml`) | replaced | kept, `--purge` removes |
| `/etc/logember/redaction.yaml` | your redaction rules | **kept** | kept, `--purge` removes |
| `/etc/logember/agent.env` | `LOGEMBER_INGEST_KEY`, `LOGEMBER_INGEST_URL`, `LOGEMBER_HUB_URL`, `LOGEMBER_ENV` | rewritten with the same values | kept, `--purge` removes |
| `/etc/logember/sources.yaml` | files added in the hub, written by `logember-agent-sync` | kept, rewritten on the next change in the hub | kept, `--purge` removes |
| `/var/lib/logember/sources.etag` | ETag of the last `GET /v1/agent/config` | removed (the next sync fetches again) | kept, `--purge` removes |
| `/var/lib/logember/buffer/` | disk queue and read positions | kept | kept, `--purge` removes |

`/etc/logember` is owned by `logember` with mode 0750; `agent.env` is mode 0600 and is read by systemd as the unit's `EnvironmentFile`. The ingest key identifies the host to LogEmber: treat `agent.env` as a secret.

## Disk buffer

The exporter queue lives on disk in `/var/lib/logember/buffer` (the collector's `file_storage` extension), together with the read position of every file and the journal, so lines survive both a network outage and a restart of the agent. While ingest is unreachable or answers 429, 502, 503 or 504, requests are retried with backoff (5 s, growing to 60 s) for as long as it takes.

The cap is 5000 requests (`sending_queue.queue_size` in `config/agent.yaml`), not a size in bytes. A request holds up to 16384 records, so on a busy host a long outage can fill several GB; once the queue is full, new records are dropped until it drains. Requests that ingest rejects with any other status (for example 401 for a revoked key) are dropped, not retried. The agent's memory is limited to 256 MiB by `memory_limiter` and to 512 MiB by the unit (`MemoryMax=`).

## Docker

Container logs are read from the files of Docker's default `json-file` log driver, `/var/lib/docker/containers/<id>/<id>-json.log`. Each line is unpacked: the body is the line the container wrote, `stream` (`stdout`/`stderr`) becomes an attribute, the time comes from Docker, and JSON lines and severities are handled like any other source. Lines longer than 16 KiB, which Docker splits, are joined again.

- **Service name.** The log files do not name their container, so the agent asks the Docker API: when `/run/docker.sock` exists and the `logember` user may use it, the unit also loads `/etc/logember/docker.yaml` (`docker_observer` + `receiver_creator`), and `logember.service` is the container name, with `container.name` and `container.image.name` as attributes. Otherwise it is the short container ID. `install.sh` adds `logember` to the `docker` group when it exists; if you install Docker after the agent, re-run `install.sh` to get container names. Note that access to the Docker socket is root-equivalent; leave `logember` out of the `docker` group if you prefer container IDs over names.
- **File permissions.** `/var/lib/docker/containers` is `root` 0710 and the log files are `root` 0640, so no group can read them. The unit gives the agent `CAP_DAC_READ_SEARCH` (read and list any file, no write access, no other capability) and hides credential files (`/etc/shadow`, `/etc/gshadow`, `/etc/sudoers*`, `/etc/ssh`) from it, on top of `ProtectSystem=strict` and `ProtectHome=true`.
- **Without Docker** nothing changes: the glob matches no files and `docker.yaml` is not loaded.
- **Limits.** Lines a new container writes in the second before the agent starts following it are not read. Only the `json-file` driver under the default data root is read; the `journald`, `local` and other log drivers and Kubernetes are not covered.

### Docker-only hosts

There is no container image of the agent in v0.1.0. On a host where everything else runs in containers, install the agent on the host itself with the same one-liner: it runs under systemd next to `dockerd` and collects every container's logs from `/var/lib/docker/containers`, plus the host's journal. The host needs systemd and bash (see [Supported platforms](#supported-platforms)); hosts that cannot run systemd services, such as Docker Desktop or a container-only OS without systemd, are not supported in v0.1.0.

## Sources from the hub and heartbeat

Every 5 minutes `logember-agent-sync.timer` runs `/usr/local/bin/logember-agent-sync`, a short POSIX shell script, as root. `install.sh` also runs it once right after the agent starts.

1. `GET /v1/agent/config` on the hub with the host's ingest key and the ETag of the last answer (`If-None-Match`). When the files added in the hub have changed, it writes them to `/etc/logember/sources.yaml`, one `filelog` receiver per path in a pipeline of their own (`logs/hub`, with the same processors and redaction as everything else), checks the result with `logember-agent validate` and restarts `logember-agent`. `logember.service` on those lines is the service name set in the hub. A new file is read from its end, like the default sources, so lines written to it before the agent has restarted with it are not sent; files that appear later are read from the start.
2. `POST /v1/agent/heartbeat` with the agent version, the state of the agent (`systemctl is-active logember-agent`) and the size of the disk buffer in bytes. The hub updates the host's last-seen time and agent version.

- **Paths** must be absolute; globs work (`/var/www/*/storage/logs/*.log`). Sources that are not files, relative paths and paths the default sources already read (`/var/log/*.log`, `/var/log/nginx/*.log`) are skipped, with a warning in the journal. The agent can read any file regardless of permissions (`CAP_DAC_READ_SEARCH`, see [Docker](#docker)), but nothing under `/home` and `/root` (`ProtectHome=true`).
- **When something fails**, nothing changes on the host: if the hub cannot be reached or answers with an error, the agent keeps its current sources, and if the new sources do not pass `validate`, `sources.yaml` is kept as it is. The next run is 5 minutes later. The heartbeat is sent either way.
- **Do not edit `sources.yaml`**: it is replaced on the next change in the hub.
- **Logs**: `journalctl -u logember-agent-sync` (a line only when the sources change or something fails). `sudo systemctl start logember-agent-sync` syncs now; `systemctl list-timers logember-agent-sync.timer` shows the next run.

## Self-hosted hub

By default the agent enrolls with `https://api.logember.com` and sends to `https://ingest.logember.com`. To use your own hub and ingest, pass both URLs on the first install:

```bash
curl -fsSL https://get.logember.com | sudo bash -s -- --token <ENROLLMENT_TOKEN> \
  --hub https://logember.example.com --ingest https://ingest.example.com --env staging
```

The URLs are stored in `/etc/logember/agent.env` and kept on upgrade. To move an enrolled host to another hub, run the same command with `--reenroll` and a token from the new hub; without `--reenroll` the existing ingest key is kept and only the URLs change.

What has to be reachable from the host, all outbound HTTPS (nothing connects to the host):

- **github.com**, at install and upgrade time, for the release download (GitHub redirects it to a `githubusercontent.com` host).
- **The hub**, at install time: `POST <hub>/v1/enroll` with `Content-Type: application/json` and the body `{"token", "hostname", "os", "arch", "agent_version"}`. A 2xx answer must be JSON with an `ingest_key` string (letters, digits and `._~+/=-`). Errors: 401 means an unknown token and 410 a token that is used up or expired; for 410 and any other error status, the `message` field of a JSON answer is shown to whoever runs the script. The request is sent once, without retries, so a token is never used twice.
- **The hub**, every 5 minutes (`logember-agent-sync`): `GET <hub>/v1/agent/config` with `Authorization: Bearer <ingest_key>` and `If-None-Match`, answered with `304` or `200` and `{"sources": [{"type": "file", "path", "service_name"}]}` plus an `ETag`; then `POST <hub>/v1/agent/heartbeat` with `{"agent_version", "status", "buffer_bytes"}`, answered with any 2xx.
- **Ingest**, all the time: OTLP/HTTP `POST <ingest>/v1/logs` (the exporter appends `/v1/logs` to `--ingest`), protobuf, `Content-Encoding: zstd`, `Authorization: Bearer <ingest_key>`. Retries and drops are described under [Disk buffer](#disk-buffer).

TLS: both URLs should be `https://`. Certificates are checked against the host's system CA bundle by `curl` (enrollment, `logember-agent-sync`) and by the agent (ingest), and there is no option to skip the check. For a private CA, add it to the system store before installing:

```bash
sudo cp my-ca.crt /usr/local/share/ca-certificates/my-ca.crt
sudo update-ca-certificates
```

`http://` URLs are accepted for local testing, but then the enrollment token and the ingest key travel in clear text.

`--env` sets `logember.env` on every record (default `production`); use it to tell staging and production hosts apart in the hub.

## Redaction

The built-in rules live in `config/agent.yaml` (processors `transform/redact` and `redaction`) and are updated with the agent. Rules of your own go in `/etc/logember/redaction.yaml`, which the systemd unit passes to the agent as a second `--config` file. `install.sh` writes it on the first install only and never overwrites it, so your edits survive upgrades. Out of the box it masks email addresses; delete that rule if you need them. Rules from the hub are not supported in v0.1.0: the rules are the ones in this file.

Each rule is a regular expression ([RE2 syntax](https://github.com/google/re2/wiki/Syntax)); every match in the log line and in every attribute value is replaced with `****`. To add one, append it under `blocked_values`:

```yaml
# /etc/logember/redaction.yaml
processors:
  redaction/local:
    blocked_values:
      - '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,6}\b'
      - '\bcus_[A-Za-z0-9]{14}\b'   # added: Stripe customer IDs
```

Then check the config and restart the agent:

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

This stops and disables the units and removes `/usr/local/bin/logember-agent`, `/usr/local/bin/logember-agent-sync` and the unit files. `/etc/logember` (config, your redaction rules, the ingest key) and `/var/lib/logember` (the disk buffer) are kept, so installing again picks up where it left off. To remove them and the `logember` user as well:

```bash
curl -fsSL https://github.com/overexposed-ltd/logember-agent/releases/latest/download/uninstall.sh | sudo bash -s -- --purge
```

Running it again is harmless. The script does not revoke the ingest key: remove the host in the hub to do that.

## Supported platforms

v0.1.0 is tested on **Ubuntu 24.04** and **Debian 12**, on amd64 and arm64.

The installer runs on any Linux amd64 or arm64 host with systemd as PID 1, bash, curl and coreutils, so other systemd distributions (RHEL/Alma/Rocky, Fedora, ...) may work, but they are not tested for v0.1.0. Not supported: hosts without systemd (Alpine, most containers), macOS, Windows, other CPU architectures, and running the agent as a container (see [Docker-only hosts](#docker-only-hosts)). There are no .deb or .rpm packages; a release is the raw binaries, `checksums.txt`, `install.sh`, `uninstall.sh` and the config files.

## Layout

```
install.sh            the script behind get.logember.com: checks the host (root, systemd, amd64/arm64), downloads and verifies the release, enrolls, writes config, enables the unit
uninstall.sh          stops and removes the agent; --purge also removes its config, disk buffer and user
config/agent.yaml     OpenTelemetry Collector pipeline (receivers → processors → otlphttp exporter)
config/docker.yaml    overlay that names Docker containers through the Docker API (loaded when it is reachable)
config/redaction.yaml the host's own redaction rules (/etc/logember/redaction.yaml, kept on upgrade)
deploy/logember-agent.service   systemd unit
deploy/logember-agent-sync      sources from the hub and heartbeat (POSIX sh), with its .service and .timer (every 5 minutes)
scripts/build.sh      builds the collector binary with ocb (only the components in config/)
scripts/test-config.sh runs the built binary against test/fixtures and checks the records it sends
scripts/test-sync.sh  runs logember-agent-sync against test/hub-mock.py, then the agent on the sources.yaml it wrote
```

## Development

Requires Go (any version ≥ 1.21) and curl. `scripts/build.sh` downloads the pinned [ocb](https://opentelemetry.io/docs/collector/custom-collector/) release (checksum-verified), builds with the pinned Go toolchain via `GOTOOLCHAIN`, and produces `dist/logember-agent_linux_{amd64,arm64}` plus `dist/checksums.txt`. Set `VERSION` to override the version taken from `git describe --tags`. `scripts/test-config.sh` then runs the built binary in a Debian 12 container against the sample logs in `test/fixtures` and checks every record it sends against the record schema (needs Docker and jq). `scripts/test-sync.sh` runs `logember-agent-sync` against a mock of the hub's agent API (`test/hub-mock.py`), with mawk, gawk and busybox awk, and then the agent on the `sources.yaml` it wrote (needs Docker). `test/smoke/run.sh --distro ubuntu-24.04|debian-12 [--arch amd64|arm64]` is the end-to-end check: it boots the distro with systemd in a privileged container, runs the one-liner as a sudo user against a mock hub and an OTLP sink, checks the first sync with the hub and that a marker line written to `/var/log`, to a file source from the hub and through `logger` arrives with `logember.service`, `logember.env`, a valid severity and its fake secret redacted, then uninstalls (needs Docker and jq; `--release vX.Y.Z` tests a published release instead of `dist/`). CI runs it on all four distro/arch combinations (`.github/workflows/smoke.yml`). Pushing a tag `v*` publishes a GitHub Release (`.github/workflows/release.yml`); tags with a suffix such as `v0.1.0-rc.1` become pre-releases, which `install.sh` installs only with `--version`.

The wire format and the record schema live in the main LogEmber repo under `proto/`.

## License

Apache-2.0 (see `LICENSE`).
