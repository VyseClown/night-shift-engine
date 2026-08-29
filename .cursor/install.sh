#!/usr/bin/env bash
# shellcheck shell=bash
# Cloud Agent + CI install for night-shift-engine.
#
# The engine is a zero-dependency bash project (no package.json). Its dev/CI
# gate is: shellcheck (version-pinned), node --check on the JS libs, jq for
# JSON, and the deterministic bash test layers. Node, jq, git and curl ship in
# the base image; the one tool the base image lacks is shellcheck, and CI pins
# it to a specific version so "green locally" matches "green in CI". This script
# is the single source of that pin — `.github/workflows/ci.yml` calls it —
# and is idempotent: it re-installs only when the pinned version is not already
# present.
set -euo pipefail

# Bump deliberately, in sync with what the repo-root .shellcheckrc + inline
# pragmas were validated against. Ubuntu's apt shellcheck lags and reports
# findings newer versions don't.
SC_VERSION="0.11.0"
SC_DEST="/usr/local/bin/shellcheck"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[install] required tool missing from base image: $1" >&2
    return 1
  }
}

sc_version() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}'
}

install_file() {
  local src="$1" dest="$2" dest_dir
  dest_dir="$(dirname "$dest")"
  if [ -w "$dest_dir" ]; then
    install "$src" "$dest"
  else
    sudo install "$src" "$dest"
  fi
}

echo "[install] verifying base-image toolchain"
need bash
need git
need curl
need jq
need node
echo "[install] node $(node --version), jq $(jq --version), $(bash --version | head -1)"

current_sc="$(sc_version || true)"

if [ "$current_sc" = "$SC_VERSION" ]; then
  echo "[install] shellcheck $SC_VERSION already present; skipping download"
else
  echo "[install] installing pinned shellcheck $SC_VERSION (found: '${current_sc:-none}')"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL \
    "https://github.com/koalaman/shellcheck/releases/download/v${SC_VERSION}/shellcheck-v${SC_VERSION}.linux.x86_64.tar.xz" \
    | tar -xJ -C "$tmp"
  install_file "$tmp/shellcheck-v${SC_VERSION}/shellcheck" "$SC_DEST"
fi

got="$(sc_version || true)"
if [ "$got" != "$SC_VERSION" ]; then
  echo "[install] shellcheck version mismatch: expected $SC_VERSION, got '${got:-none}' (PATH=$(command -v shellcheck 2>/dev/null || echo none))" >&2
  exit 1
fi

echo "[install] shellcheck: $got ($(command -v shellcheck))"
echo "[install] done"
