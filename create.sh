#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (env-overridable)
# =========================
REPO_URL="${REPO_URL:-https://github.com/NickCarreiro/CYBR428-ICA.git}"
BRANCH="${BRANCH:-main}"
ZIP_FILE="${ZIP_FILE:-html.zip}"        # zip name (local or repo)
PORT="${PORT:-8080}"
CONTAINER_NAME="${CONTAINER_NAME:-webbox}"
IMAGE_NAME="${IMAGE_NAME:-ubuntu-web:latest}"
DOCKERFILE_PATH="/tmp/ubuntu-web.dockerfile"
UBUNTU_BASE_URL="${UBUNTU_BASE_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04-base-amd64.tar.gz}"

# =========================
# Docker install
# =========================
if [[ -z "${SUDO_USER-}" && "$EUID" -ne 0 ]]; then
  echo "ERROR: Run as root or with sudo."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends docker.io docker-cli curl unzip git ca-certificates xz-utils

systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker || true
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker CLI missing after install."
  exit 1
fi

# =========================
# Base image check/fallback
# =========================
BASE_IMAGE="ubuntu:24.04"
if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  echo "[*] Pulling $BASE_IMAGE from Docker Hub..."
  if ! timeout 45s docker pull "$BASE_IMAGE" >/dev/null 2>&1; then
    echo "[!] Docker Hub blocked, using local fallback..."
    if ! docker image inspect local-ubuntu:24.04 >/dev/null 2>&1; then
      TMPDIR="$(mktemp -d)"
      ROOTFS="${TMPDIR}/ubuntu-base.tar.gz"
      curl -fSL -o "$ROOTFS" "$UBUNTU_BASE_URL"
      gzip -dc "$ROOTFS" | docker import - local-ubuntu:24.04
      rm -rf "$TMPDIR"
    fi
    BASE_IMAGE="local-ubuntu:24.04"
  fi
fi

# =========================
# Build image
# =========================
cat > "$DOCKERFILE_PATH" <<EOF
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \\
    apache2 libapache2-mod-php php-cli php-mbstring php-xml php-curl php-zip php-gd php-mysql \\
 && a2dismod autoindex mpm_event || true \\
 && a2enmod mpm_prefork php8.3 rewrite headers \\
 && echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf \\
 && a2enconf servername \\
 && sed -i 's/DirectoryIndex .*/DirectoryIndex index.php index.html index.htm/' /etc/apache2/mods-available/dir.conf \\
 && printf "\\nServerTokens Prod\\nServerSignature Off\\n" >> /etc/apache2/conf-available/security.conf \\
 && a2enconf security || true \\
 && rm -rf /var/lib/apt/lists/*
EXPOSE 80
CMD ["bash","-lc","apache2ctl -D FOREGROUND"]
EOF

docker build -t "$IMAGE_NAME" -f "$DOCKERFILE_PATH" /tmp
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER_NAME" -p "$PORT":80 "$IMAGE_NAME"

# =========================
# Fetch or use local html.zip
# =========================
WORKDIR="$(mktemp -d)"
ZIP_DST="${WORKDIR}/site.zip"
EXTRACT_DIR="${WORKDIR}/unzipped"
mkdir -p "$EXTRACT_DIR"

if [[ -f "./${ZIP_FILE}" ]]; then
  echo "[*] Found local ${ZIP_FILE}, skipping GitHub download."
  cp "./${ZIP_FILE}" "$ZIP_DST"
else
  echo "[*] No local ${ZIP_FILE} found — downloading from GitHub..."
  OWNER_REPO="$(echo "$REPO_URL" | sed -E 's#(.*github\.com[:/])([^/]+/[^/.]+)(\.git)?#\2#')"
  OWNER="${OWNER_REPO%%/*}"
  REPO="${OWNER_REPO##*/}"
  RAW_MAIN_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/${ZIP_FILE}"
  RAW_MASTER_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/master/${ZIP_FILE}"
  if curl -fsSL -o "$ZIP_DST" "$RAW_MAIN_URL"; then
    echo "[*] Downloaded from branch '${BRANCH}'."
  elif curl -fsSL -o "$ZIP_DST" "$RAW_MASTER_URL"; then
    echo "[*] Downloaded from fallback 'master'."
  else
    echo "ERROR: Unable to fetch ${ZIP_FILE} from GitHub."
    exit 1
  fi
fi

# =========================
# Deploy content
# =========================
unzip -q "$ZIP_DST" -d "$EXTRACT_DIR"
TOP_LIST=( "$EXTRACT_DIR"/* )
if [[ ${#TOP_LIST[@]} -eq 1 && -d "${TOP_LIST[0]}" ]]; then
  WEB_CONTENT_DIR="${TOP_LIST[0]}"
else
  WEB_CONTENT_DIR="$EXTRACT_DIR"
fi

echo "[*] Copying site content to container..."
docker cp "${WEB_CONTENT_DIR}/." "${CONTAINER_NAME}:/var/www/html/"
docker exec "$CONTAINER_NAME" bash -lc 'chown -R www-data:www-data /var/www/html && chmod -R 755 /var/www/html'

echo "[*] Restarting Apache..."
if ! docker exec "$CONTAINER_NAME" bash -lc 'apache2ctl -k graceful' >/dev/null 2>&1; then
  docker restart "$CONTAINER_NAME" >/dev/null
fi

IP_HINT="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "============================================================"
echo "Webserver ready!"
echo "Open: http://localhost:${PORT}/"
[[ -n "$IP_HINT" ]] && echo "Or:  http://${IP_HINT}:${PORT}/"
echo "============================================================"
