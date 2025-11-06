#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (env-overridable)
# =========================
REPO_URL="${REPO_URL:-https://github.com/NickCarreiro/CYBR428-ICA.git}"
BRANCH="${BRANCH:-main}"
ZIP_FILE="${ZIP_FILE:-html.zip}"
PORT="${PORT:-8080}"
CONTAINER_NAME="${CONTAINER_NAME:-webbox}"
IMAGE_NAME="${IMAGE_NAME:-ubuntu-web:latest}"
DOCKERFILE_PATH="/tmp/ubuntu-web.dockerfile"
UBUNTU_BASE_URL="${UBUNTU_BASE_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04-base-amd64.tar.gz}"

# Gobuster fallback release (used only if apt install fails)
GOBUSTER_FALLBACK_VERSION="${GOBUSTER_FALLBACK_VERSION:-3.6.0}"
GOBUSTER_FALLBACK_URL="${GOBUSTER_FALLBACK_URL:-https://github.com/OJ/gobuster/releases/download/v${GOBUSTER_FALLBACK_VERSION}/gobuster-linux-amd64-${GOBUSTER_FALLBACK_VERSION}.tar.gz}"

# =========================
# Pre-flight / privileges
# =========================
if [[ -z "${SUDO_USER-}" && "$EUID" -ne 0 ]]; then
  echo "ERROR: Run as root or with sudo."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[*] Updating apt and installing required packages..."
apt-get update -y
# remove misleading 'docker' GUI package if present
if dpkg -s docker >/dev/null 2>&1; then
  echo "[!] Detected 'docker' package (likely wmdocker). Removing to avoid confusion..."
  apt-get remove -y docker || true
fi

# Install core packages (docker + tools)
apt-get install -y --no-install-recommends docker.io docker-cli curl unzip git ca-certificates xz-utils

# -------------------------
# Ensure gobuster is installed
# -------------------------
install_gobuster_via_apt() {
  echo "[*] Trying to install gobuster via apt..."
  if apt-get install -y --no-install-recommends gobuster >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

install_gobuster_fallback() {
  echo "[*] Apt install failed or package unavailable. Attempting fallback download: ${GOBUSTER_FALLBACK_URL}"
  tmpd="$(mktemp -d)"
  trap 'rm -rf "${tmpd}"' RETURN
  archive="${tmpd}/gobuster.tar.gz"

  # Try to download fallback release tar.gz
  if curl -fsSL -o "${archive}" "${GOBUSTER_FALLBACK_URL}"; then
    mkdir -p "${tmpd}/usrbin"
    tar -xzf "${archive}" -C "${tmpd}/usrbin" || true

    # The tarball may contain a binary named 'gobuster' (or gobuster-linux-amd64-<ver>), find it
    bin_candidate="$(find "${tmpd}" -type f -name 'gobuster*' -perm /111 | head -n 1 || true)"
    if [[ -z "${bin_candidate}" ]]; then
      # try extracting without expecting executable bit
      tar -tzf "${archive}"
      bin_candidate="$(find "${tmpd}" -type f -name 'gobuster*' | head -n 1 || true)"
    fi

    if [[ -n "${bin_candidate}" && -f "${bin_candidate}" ]]; then
      install -m 0755 "${bin_candidate}" /usr/local/bin/gobuster
      echo "[*] Installed gobuster to /usr/local/bin/gobuster"
      return 0
    else
      echo "[!] Fallback tarball did not contain a usable gobuster binary."
      return 1
    fi
  else
    echo "[!] Failed to download fallback gobuster release from ${GOBUSTER_FALLBACK_URL}"
    return 1
  fi
}

# If gobuster already present, skip
if command -v gobuster >/dev/null 2>&1; then
  echo "[*] gobuster already installed: $(gobuster --version 2>/dev/null || echo '(version unknown)')"
else
  if install_gobuster_via_apt; then
    echo "[*] Successfully installed gobuster via apt."
  else
    if install_gobuster_fallback; then
      echo "[*] Successfully installed gobuster via fallback binary."
    else
      echo "[!] Could not install gobuster via apt or fallback. Continuing without gobuster."
    fi
  fi
fi

# Verify presence one last time (non-fatal)
if command -v gobuster >/dev/null 2>&1; then
  echo "[*] gobuster available at: $(command -v gobuster)"
  # Try to show version but don't fail if print fails
  gobuster --version 2>/dev/null || true
else
  echo "[!] Warning: gobuster not found. If you need it, install manually."
fi

# =========================
# Docker setup / ensure daemon running
# =========================
echo "[*] Enabling & starting docker.service (if using systemd)..."
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker || true
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: 'docker' CLI not found after install. Aborting."
  exit 1
fi

# Try to restart docker if info fails (non-fatal)
if ! docker info >/dev/null 2>&1; then
  echo "[!] docker info failed; attempting to restart docker.service"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart docker || true
  fi
  sleep 2
fi

echo "[*] Docker version: $(docker --version || true)"

# =========================
# Base image check/fallback (works if Docker Hub is blocked)
# =========================
BASE_IMAGE="ubuntu:24.04"
echo "[*] Ensuring base image: ${BASE_IMAGE}"
if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "[*] Attempting to pull ${BASE_IMAGE} from Docker Hub..."
  if ! timeout 45s docker pull "${BASE_IMAGE}" >/dev/null 2>&1; then
    echo "[!] Docker Hub pull failed or timed out. Using local import fallback."

    if docker image inspect local-ubuntu:24.04 >/dev/null 2>&1; then
      BASE_IMAGE="local-ubuntu:24.04"
      echo "[*] Using existing fallback image ${BASE_IMAGE}."
    else
      TMPDIR="$(mktemp -d -t ubrootfs-XXXXXX)"
      trap 'rm -rf "${TMPDIR}" || true' RETURN
      ROOTFS="${TMPDIR}/ubuntu-base-24.04-base-amd64.tar.gz"
      echo "[*] Downloading Ubuntu Base rootfs from: ${UBUNTU_BASE_URL}"
      curl -fSL --connect-timeout 20 --retry 3 -o "${ROOTFS}" "${UBUNTU_BASE_URL}"
      gzip -dc "${ROOTFS}" | docker import - local-ubuntu:24.04
      BASE_IMAGE="local-ubuntu:24.04"
      echo "[*] Imported fallback base image ${BASE_IMAGE}."
    fi
  else
    echo "[*] Successfully pulled ${BASE_IMAGE}."
  fi
else
  echo "[*] Base image ${BASE_IMAGE} present locally."
fi

# =========================
# Build Apache+PHP image (uses $BASE_IMAGE)
# =========================
echo "[*] Writing Dockerfile -> ${DOCKERFILE_PATH}"
cat > "${DOCKERFILE_PATH}" <<EOF
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \\
 && apt-get install -y --no-install-recommends \\
      apache2 \\
      libapache2-mod-php php-cli php-mbstring php-xml php-curl php-zip php-gd php-mysql \\
 && a2dismod autoindex mpm_event || true \\
 && a2enmod mpm_prefork php8.3 rewrite headers \\
 && echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf \\
 && a2enconf servername \\
 && sed -i 's/DirectoryIndex .*/DirectoryIndex index.php index.html index.htm/' /etc/apache2/mods-available/dir.conf \\
 && printf "\\n# Hardening: don’t expose versions\\nServerTokens Prod\\nServerSignature Off\\n" >> /etc/apache2/conf-available/security.conf \\
 && a2enconf security || true \\
 && rm -rf /var/lib/apt/lists/*

RUN { \\
      echo 'upload_max_filesize = 16M'; \\
      echo 'post_max_size = 16M'; \\
      echo 'memory_limit = 256M'; \\
      echo 'expose_php = Off'; \\
    } > /etc/php/8.3/apache2/conf.d/zzz-local.ini || true

EXPOSE 80
CMD ["bash","-lc","apache2ctl -D FOREGROUND"]
EOF

echo "[*] Building image ${IMAGE_NAME} (this may take several minutes)..."
docker build -t "${IMAGE_NAME}" -f "${DOCKERFILE_PATH}" /tmp

# Recreate container if exists
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  echo "[*] Removing existing container ${CONTAINER_NAME}..."
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

echo "[*] Starting container ${CONTAINER_NAME} (host ${PORT} -> container 80)..."
docker run -d --name "${CONTAINER_NAME}" -p "${PORT}:80" "${IMAGE_NAME}"

# =========================
# Use local html.zip if present, otherwise download from GitHub
# =========================
WORKDIR="$(mktemp -d -t websrc-XXXXXX)"
ZIP_DST="${WORKDIR}/site.zip"
EXTRACT_DIR="${WORKDIR}/unzipped"
mkdir -p "${EXTRACT_DIR}"

if [[ -f "./${ZIP_FILE}" ]]; then
  echo "[*] Found local ${ZIP_FILE}, skipping GitHub download."
  cp "./${ZIP_FILE}" "${ZIP_DST}"
else
  echo "[*] No local ${ZIP_FILE} found — attempting to download from GitHub raw..."
  # parse owner/repo from REPO_URL
  REPO_STRIPPED="${REPO_URL%.git}"
  REPO_PATH="${REPO_STRIPPED#*github.com[:/]}"
  if [[ "${REPO_PATH}" != */* ]]; then
    echo "ERROR: Could not parse owner/repo from REPO_URL='${REPO_URL}'"
    exit 1
  fi
  OWNER="${REPO_PATH%%/*}"
  REPO="${REPO_PATH##*/}"
  RAW_MAIN_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/${ZIP_FILE}"
  RAW_MASTER_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/master/${ZIP_FILE}"

  if curl -fsSL -o "${ZIP_DST}" "${RAW_MAIN_URL}"; then
    echo "[*] Downloaded ${ZIP_FILE} from branch '${BRANCH}'."
  elif curl -fsSL -o "${ZIP_DST}" "${RAW_MASTER_URL}"; then
    echo "[*] Downloaded ${ZIP_FILE} from fallback 'master'."
  else
    echo "ERROR: Unable to fetch ${ZIP_FILE} from GitHub."
    exit 1
  fi
fi

# =========================
# Unpack and deploy into container
# =========================
echo "[*] Unzipping site archive..."
unzip -q "${ZIP_DST}" -d "${EXTRACT_DIR}"

# choose web content dir
TOP_LIST=( "${EXTRACT_DIR}"/* )
if [[ ${#TOP_LIST[@]} -eq 1 && -d "${TOP_LIST[0]}" ]]; then
  WEB_CONTENT_DIR="${TOP_LIST[0]}"
else
  WEB_CONTENT_DIR="${EXTRACT_DIR}"
fi

if ! find "${WEB_CONTENT_DIR}" -maxdepth 1 -type f \( -iname "index.php" -o -iname "index.html" -o -iname "index.htm" \) | grep -q . ; then
  echo "[!] Warning: No index.* found at top of extracted content. Proceeding anyway."
fi

echo "[*] Copying web content into container:/var/www/html/ ..."
docker cp "${WEB_CONTENT_DIR}/." "${CONTAINER_NAME}:/var/www/html/"

echo "[*] Fixing permissions inside container..."
docker exec "${CONTAINER_NAME}" bash -lc 'chown -R www-data:www-data /var/www/html && \
  find /var/www/html -type d -exec chmod 0755 {} \; && \
  find /var/www/html -type f -exec chmod 0644 {} \;'

echo "[*] Enabling .htaccess overrides and rewrite..."
docker exec "${CONTAINER_NAME}" bash -lc '
  APACHE_CONF="/etc/apache2/sites-available/000-default.conf"
  if ! grep -q "<Directory /var/www/html>" "$APACHE_CONF"; then
    printf "\n<Directory /var/www/html>\n    AllowOverride All\n    Require all granted\n</Directory>\n" >> "$APACHE_CONF"
  else
    sed -i "/<Directory \\/var\\/www\\/html>/,/<\\/Directory>/ s/AllowOverride .*/AllowOverride All/" "$APACHE_CONF" || true
  fi
  a2enmod rewrite >/dev/null 2>&1 || true
'

echo "[*] Graceful reload (or restart fallback)..."
if ! docker exec "${CONTAINER_NAME}" bash -lc 'apache2ctl -k graceful' >/dev/null 2>&1; then
  docker restart "${CONTAINER_NAME}" >/dev/null
fi

IP_HINT="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "============================================================"
echo "Done!"
echo "Open: http://localhost:${PORT}/"
[[ -n "${IP_HINT}" ]] && echo "Or:  http://${IP_HINT}:${PORT}/ (LAN)"
echo
echo "Repo:     ${REPO_URL}"
echo "Branch:   ${BRANCH} (fallback to master supported)"
echo "Zip file: ${ZIP_FILE}"
echo "Image:    ${IMAGE_NAME}"
echo "Container:${CONTAINER_NAME}"
echo "Base:     ${BASE_IMAGE}"
echo "Logs:     docker logs -f ${CONTAINER_NAME}"
echo "Remove:   docker rm -f ${CONTAINER_NAME} && docker rmi ${IMAGE_NAME}"
echo "============================================================"

# Post-run tip (non-fatal)
if ! groups "${SUDO_USER:-$USER}" | grep -q docker; then
  echo "[*] Tip: to run docker without sudo later, add your user and re-login:"
  echo "    sudo usermod -aG docker \"${SUDO_USER:-$USER}\""
fi

exit 0
