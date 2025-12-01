#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/install-docker-portainer.log
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date '+%F %T') START: optimize + install docker & portainer ==="

# must be run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root (use sudo)"; exit 1
fi

# --- Basic system update & utilities
echo "-- update apt and install essentials"
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release apt-transport-https unzip sudo net-tools iproute2

# --- timezone locale small sanity (optional: keep minimal)
# ensure tzdata doesn't prompt
export DEBIAN_FRONTEND=noninteractive

# --- Install/enable qemu-guest-agent (for Proxmox host <-> guest integration)
if ! dpkg -l | grep -qw qemu-guest-agent; then
  echo "-- installing qemu-guest-agent"
  apt install -y qemu-guest-agent || true
fi
systemctl enable --now qemu-guest-agent || true

# --- Disable unused services that commonly waste resources (safe defaults)
for svc in bluetooth avahi-daemon ModemManager; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    systemctl disable --now "${svc}" >/dev/null 2>&1 || true
  fi
done

# --- Add docker apt repository (idempotent)
DOCKER_KEYRING=/etc/apt/keyrings/docker.gpg
if [ ! -f "$DOCKER_KEYRING" ]; then
  echo "-- add docker gpg key"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o "$DOCKER_KEYRING"
  chmod a+r "$DOCKER_KEYRING"
fi

DOCKER_LIST=/etc/apt/sources.list.d/docker.list
ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
if [ ! -f "$DOCKER_LIST" ] || ! grep -q "download.docker.com" "$DOCKER_LIST" 2>/dev/null; then
  echo "deb [arch=${ARCH} signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/debian ${CODENAME} stable" > "$DOCKER_LIST"
fi

apt update -y

# --- Install Docker engine (or fallback to docker.io)
if ! command -v docker >/dev/null 2>&1; then
  echo "-- installing docker packages"
  apt install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || apt install -y docker.io
else
  echo "-- docker already installed: $(docker --version || true)"
fi

# --- Ensure docker + containerd enabled
systemctl enable --now docker || true
systemctl enable --now containerd || true

# --- Prepare Portainer data dir and Docker run (idempotent)
PORTAINER_DATA=/portainer_data
mkdir -p "$PORTAINER_DATA"
chown root:root "$PORTAINER_DATA"
chmod 755 "$PORTAINER_DATA"

# remove old non-running portainer container if exists
if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
  STATUS=$(docker inspect -f '{{.State.Status}}' portainer 2>/dev/null || echo "unknown")
  if [ "$STATUS" != "running" ]; then
    docker rm -f portainer 2>/dev/null || true
  fi
fi

# run portainer if not running
if ! docker ps --format '{{.Names}}' | grep -q '^portainer$'; then
  docker pull portainer/portainer-ce:latest || true
  docker run -d \
    -p 8000:8000 \
    -p 9443:9443 \
    --name portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${PORTAINER_DATA}":/data \
    portainer/portainer-ce:latest || true
else
  echo "-- portainer already running"
fi

# --- Optional: add SUDO_USER to docker group when script invoked with sudo
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  if id -nG "$SUDO_USER" | grep -qw docker; then
    echo "-- user $SUDO_USER already in docker group"
  else
    usermod -aG docker "$SUDO_USER" || true
    echo "-- user $SUDO_USER added to docker group (relogin required)"
  fi
fi

# --- Minimal firewall via ufw (optional: leave disabled if you manage ports via host)
if ! command -v ufw >/dev/null 2>&1; then
  apt install -y ufw || true
fi
# allow ssh + portainer https and portainer edge
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 9443/tcp >/dev/null 2>&1 || true
ufw allow 8000/tcp >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true

# --- Housekeeping: clean apt cache, rotate journal small
apt clean || true
journalctl --vacuum-size=50M || true

echo "=== $(date '+%F %T') DONE: optimize + install docker & portainer ==="
exit 0
