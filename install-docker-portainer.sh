#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/install-docker-portainer.log
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date '+%F %T') START install-docker-portainer ==="

# Yêu cầu chạy bằng root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run as root (use sudo)." >&2
  exit 1
fi

# Hệ điều hành kiểm tra (yêu cầu apt)
if ! command -v apt >/dev/null 2>&1; then
  echo "ERROR: This script requires apt (Debian/Ubuntu)." >&2
  exit 1
fi

echo "-- apt update"
apt update -y

echo "-- install common packages"
apt install -y ca-certificates curl gnupg lsb-release apt-transport-https || true

# Install qemu-guest-agent (so Proxmox guest exec hoạt động)
if ! dpkg -l | grep -qw qemu-guest-agent; then
  echo "-- installing qemu-guest-agent"
  apt install -y qemu-guest-agent
  systemctl enable --now qemu-guest-agent || true
else
  echo "-- qemu-guest-agent already installed"
  systemctl enable --now qemu-guest-agent || true
fi

# Setup Docker repo (idempotent)
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
  echo "-- add docker apt repository"
  cat > "$DOCKER_LIST" <<EOF
deb [arch=${ARCH} signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/debian ${CODENAME} stable
EOF
fi

apt update -y

# Install docker packages if missing
if ! command -v docker >/dev/null 2>&1; then
  echo "-- install docker packages"
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || apt install -y docker.io
else
  echo "-- docker present: $(docker --version || true)"
fi

echo "-- enable and start docker"
systemctl enable --now docker || true

# Prepare Portainer data dir
PORTAINER_DATA=/portainer_data
mkdir -p "$PORTAINER_DATA"
chown root:root "$PORTAINER_DATA"
chmod 755 "$PORTAINER_DATA"

# Ensure Portainer container running (idempotent)
if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
  STATUS=$(docker inspect -f '{{.State.Status}}' portainer 2>/dev/null || echo "unknown")
  echo "-- existing portainer status: $STATUS"
  if [ "$STATUS" != "running" ]; then
    echo "-- restarting portainer container"
    docker rm -f portainer 2>/dev/null || true
  else
    echo "-- portainer is already running"
  fi
fi

if ! docker ps --format '{{.Names}}' | grep -q '^portainer$'; then
  echo "-- pulling portainer image"
  docker pull portainer/portainer-ce:latest || true

  echo "-- running portainer container"
  docker run -d \
    -p 8000:8000 \
    -p 9443:9443 \
    --name portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${PORTAINER_DATA}":/data \
    portainer/portainer-ce:latest || true
fi

# Optional: add a non-root invoking user to docker group if run via sudo
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  if id -nG "$SUDO_USER" | grep -qw docker; then
    echo "-- user $SUDO_USER already in docker group"
  else
    usermod -aG docker "$SUDO_USER" || true
    echo "-- user $SUDO_USER added to docker group (relogin required)"
  fi
fi

echo "=== $(date '+%F %T') DONE install-docker-portainer ==="
