#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-webbox}"

echo "[*] Checking Docker service..."
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl enable docker >/dev/null 2>&1 || true
  sudo systemctl start docker
else
  echo "[!] systemctl not found — starting dockerd manually."
  sudo dockerd --host=unix:///var/run/docker.sock &
  sleep 5
fi

echo "[*] Verifying Docker is running..."
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon is not running. Please start it manually."
  exit 1
fi

echo "[*] Checking for container '${CONTAINER_NAME}'..."
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "[*] Container '${CONTAINER_NAME}' is already running."
  else
    echo "[*] Starting existing container '${CONTAINER_NAME}'..."
    docker start "${CONTAINER_NAME}"
  fi
else
  echo "[!] No container named '${CONTAINER_NAME}' found."
  echo "    To rebuild it, run: sudo ./setup_docker_web_from_github.sh"
  exit 1
fi

echo "[*] Done. Container status:"
docker ps --filter "name=${CONTAINER_NAME}"
