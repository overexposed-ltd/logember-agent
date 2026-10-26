#!/usr/bin/env bash
# Builds the collector binary with ocb, with only the components listed in builder-config.yaml.
# Output: dist/logember-agent_linux_{amd64,arm64} and dist/checksums.txt.
# Needs: go (any version >= 1.21; the exact toolchain below is fetched by go itself), curl.
# Version: $VERSION, else `git describe --tags`, else 0.0.0-dev+<commit>.
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep OCB_VERSION on the same Collector release as the gomod lines in builder-config.yaml.
OCB_VERSION=0.163.2
GO_VERSION=1.27.3
ARCHES=(amd64 arm64)

if command -v sha256sum >/dev/null; then
  sha256() { sha256sum "$@"; }
else
  sha256() { shasum -a 256 "$@"; }
fi

ocb_sha256() {
  case "$1" in
    darwin_amd64) echo 3478afaf5eb3d00da6abe6a62f36aaab8e49195686369fa641183427b470f2ed ;;
    darwin_arm64) echo 5bb9e985f7dc4b8eec4b2555e5ded996fbceda04c07b36b7710b5876b873e61f ;;
    linux_amd64) echo 2aea100793a07cdf396972ca6ab3b137163367399045a2052bd89ba92362a4d5 ;;
    linux_arm64) echo d8c9453a5eb95131441eca1678cb3e925d12e8a14848ceb19b7c0f41e973caf3 ;;
    *) echo "no pinned ocb build for $1" >&2; return 1 ;;
  esac
}

# Pinned ocb release binary, cached in .tools/ and verified against the checksum above.
# Set OCB=/path/to/ocb to use another binary (it must report v${OCB_VERSION%.*}.x).
if [[ -z "${OCB:-}" ]]; then
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  platform="${os}_${arch}"
  want=$(ocb_sha256 "$platform")
  OCB=".tools/ocb_${OCB_VERSION}_${platform}"
  if [[ ! -x "$OCB" ]]; then
    mkdir -p .tools
    url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/cmd%2Fbuilder%2Fv${OCB_VERSION}/ocb_${OCB_VERSION}_${platform}"
    echo "downloading ocb v${OCB_VERSION} (${platform})"
    curl -fsSL -o "$OCB.tmp" "$url"
    echo "$want  $OCB.tmp" | sha256 -c - >/dev/null || { echo "ocb checksum mismatch" >&2; rm -f "$OCB.tmp"; exit 1; }
    chmod +x "$OCB.tmp"
    mv "$OCB.tmp" "$OCB"
  fi
fi
ocb_version=$("$OCB" version 2>&1)  # ocb prints its version on stderr
[[ "$ocb_version" == *"v${OCB_VERSION%.*}."* ]] || { echo "ocb must be v${OCB_VERSION%.*}.x, got: $ocb_version" >&2; exit 1; }

command -v go >/dev/null || { echo "go not found: install Go (https://go.dev/dl/); go${GO_VERSION} is then fetched automatically" >&2; exit 1; }
export GOTOOLCHAIN="go${GO_VERSION}"
export CGO_ENABLED=0

if [[ -z "${VERSION:-}" ]]; then
  VERSION=$(git describe --tags --dirty 2>/dev/null || echo "0.0.0-dev+$(git rev-parse --short HEAD)")
fi
VERSION="${VERSION#v}"

build_dir=dist/build
rm -rf dist
mkdir -p dist
echo "building logember-agent ${VERSION} (ocb v${OCB_VERSION}, go${GO_VERSION})"

# ocb reads dist.* overrides from environment variables named after the config keys.
# The first architecture generates the sources and go.mod; the rest only recompile them.
skip=()
for arch in "${ARCHES[@]}"; do
  echo "linux/${arch}"
  env "dist.version=${VERSION}" "dist.output_path=${build_dir}" GOOS=linux GOARCH="$arch" \
    "$OCB" --config builder-config.yaml "${skip[@]+"${skip[@]}"}"
  cp "${build_dir}/logember-agent" "dist/logember-agent_linux_${arch}"
  skip=(--skip-generate --skip-get-modules)
done

( cd dist && sha256 logember-agent_linux_* > checksums.txt )
echo "built:"
sed 's/^/  /' dist/checksums.txt
