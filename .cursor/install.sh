#!/usr/bin/env bash
# Cloud Agent install for night-shift-engine.
#
# The engine is a zero-dependency bash project (no package.json). Its dev/CI
# gate is: shellcheck (version-pinned), node --check on the JS libs, jq for
# JSON, and the deterministic bash test layers. Node, jq, git and curl ship in
# the base image; the one tool the base image lacks is shellcheck, and CI pins
# it to a specific version so "green locally" matches "green in CI". This script
# installs exactly that pinned shellcheck and is idempotent: it re-installs only
# when the pinned version is not already present.
set -euo pipefail

# Keep in sync with .github/workflows/ci.yml (the pinned shellcheck version).
SC_VERSION="0.11.0"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[install] required tool missing from base image: $1" >&2
    return 1
  }
}

echo "[install] verifying base-image toolchain"
need bash
need git
need curl
need jq
need node
echo "[install] node $(node --version), jq $(jq --version), $(bash --version | head -1)"

current_sc=""
if command -v shellcheck >/dev/null 2>&1; then
  current_sc="$(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}')"
fi

if [ "$current_sc" = "$SC_VERSION" ]; then
  echo "[install] shellcheck $SC_VERSION already present; skipping download"
else
  echo "[install] installing pinned shellcheck $SC_VERSION (found: '${current_sc:-none}')"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL \
    "https://github.com/koalaman/shellcheck/releases/download/v${SC_VERSION}/shellcheck-v${SC_VERSION}.linux.x86_64.tar.xz" \
    | tar -xJ -C "$tmp"
  sudo install "$tmp/shellcheck-v${SC_VERSION}/shellcheck" /usr/local/bin/shellcheck
fi

echo "[install] shellcheck: $(shellcheck --version | awk '/^version:/ {print $2}')"
echo "[install] done"
