#!/usr/bin/env bash
# Hetzner VM bootstrap — idempotent. Run as root on a fresh Debian/Ubuntu VM.
# Installs the host prerequisites for a qm docker-target deploy with
# SANDBOX_BACKEND=local. qm itself is installed by cloning this fork and running
# the runbook (see README.md); this script only prepares the host.

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }

step "checking root"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

step "installing Docker Engine + Buildx"
if ! command -v docker >/dev/null 2>&1; then
	curl -fsSL https://get.docker.com | sh
	systemctl enable --now docker
else
	echo "docker present, skipping"
fi
docker buildx version >/dev/null 2>&1 || docker buildx install || true

step "installing Node 24"
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -dv -f2 | cut -d. -f1)" -lt 24 ]; then
	curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
	apt-get install -y nodejs
else
	echo "node $(node -v) present, skipping"
fi

step "installing openssl + git + jq + restic"
apt-get update -qq
apt-get install -y -qq openssl git jq restic curl

step "installing Caddy"
if ! command -v caddy >/dev/null 2>&1; then
	apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
	apt-get update -qq
	apt-get install -y -qq caddy
else
	echo "caddy present, skipping"
fi

step "host ready"
echo "next: clone the fork, run the README.md runbook"
