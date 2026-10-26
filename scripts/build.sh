#!/usr/bin/env bash
# Builds the collector binary with ocb, with only the components referenced in config/agent.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ocb >/dev/null || { echo "install ocb: go install go.opentelemetry.io/collector/cmd/builder@latest (binary name: builder/ocb)" >&2; exit 1; }
mkdir -p dist
for arch in amd64 arm64; do
  GOOS=linux GOARCH=$arch ocb --config builder-config.yaml --output-path "dist/build-$arch" --skip-compilation=false
  cp "dist/build-$arch/logember-agent" "dist/logember-agent_linux_$arch"
done
( cd dist && sha256sum logember-agent_linux_* > checksums.txt )
echo "built: $(ls dist/logember-agent_linux_*)"
