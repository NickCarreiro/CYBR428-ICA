#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (env-overridable)
# =========================
REPO_URL="${REPO_URL:-https://github.com/NickCarreiro/CYBR428-ICA.git}"
BRANCH="${BRANCH:-main}"                # fallback to master if main fails
ZIP_FILE="${ZIP_FILE:-html.zip}"        # zip name inside repo
PORT="${PORT:-8080}"                    # host port -> container :80
CONTAINER_NAME="${CONTAINER_NAME:-webbox}"
IMAGE_NAME="${IMAGE_NAME:-ubuntu-web:latest}"
DOCKERFILE_PATH="/tmp/ubuntu-web.dockerfile"

# =========================
# Pre-flight
# =========================
if [[ -z "${SUDO_USER-}" && "$EUID" -ne 0 ]]; then
  echo "ERROR: Please run as root or with sudo."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[*] Installing prerequisites (docker.io curl unzip git)..."
apt-get update -y
apt-get install -y --no-install-recommends docker.io curl unzip git ca-certificates

echo "[*] Enabling & starting Docker..."
systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker
docker --version || true

# =========================
# Build Apache + PHP image
# =========================
echo "[*] Writing Dockerfile -> ${DOCKERFILE_PATH}"
cat > "${DOCKERFILE_PATH}" <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# Apache + PHP (mod_php on prefork), common PHP extensions, rewrite, tidy config
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      apache2 \
      libapache2-mod-php php-cli php-mbstring php-xml php-curl php-zip php-gd php-mysql \
 && a2dismod autoindex mpm_event || true \
 && a2enmod mpm_prefork php8.3 rewrite headers \
 && echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf \
 && a2enconf servername \
 && sed -i 's/DirectoryIndex .*/DirectoryIndex index.php index.html index.htm/' /etc/apache2/mods-available/dir.conf \
 && printf "\n# Hardening: don’t expose versions\nServerTokens Prod\nServerSignature Off\n" >> /etc/apache2/conf-available/security.conf \
 && a2enconf security || true \
 && rm -rf /var/lib/apt/lists/*

# Reasonable upload limits for CTF-ish uploads (tweak as needed)
RUN { \
      echo 'upload_max_filesize = 16M'; \
      echo 'post_max_size = 16M'; \
      echo 'memory_limit = 256M'; \
      echo 'expose_php = Off'; \
    } > /etc/php/8.3/apache2/conf.d/zzz-local.ini || true

EXPOSE 80
CMD ["bash","-lc","apache2ctl -D FOREGROUND"]
EOF

echo "[*] Building image ${IMAGE_NAME}..."
docker build -t "${IMAGE_NAME}" -f "${DOCKERFILE_PATH}" /tmp

# Recreate container cleanly if it already exists
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  echo "[*] Removing existing container ${CONTAINER_NAME}..."
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

echo "[*] Starting container ${CONTAINER_NAME} : host ${PORT} -> container 80 ..."
docker run -d --name "${CONTAINER_NAME}" -p "${PORT}:80" "${IMAGE_NAME}"

# =========================
# Fetch html.zip from GitHub
# =========================
WORKDIR="$(mktemp -d -t websrc-XXXXXX)"
cleanup() { rm -rf "${WORKDIR}" || true; }
trap cleanup EXIT

echo "[*] Deriving owner/repo from REPO_URL..."
REPO_STRIPPED="${REPO_URL%.git}"
REPO_PATH="${REPO_STRIPPED#*github.com[:/]}"
if [[ "${REPO_PATH}" != */* ]]; then
  echo "ERROR: Could not parse owner/repo from REPO_URL='${REPO_URL}'"; exit 1
fi
OWNER="${REPO_PATH%%/*}"
REPO="${REPO_PATH##*/}"

RAW_MAIN_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/${ZIP_FILE}"
RAW_MASTER_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/master/${ZIP_FILE}"

ZIP_DST="${WORKDIR}/site.zip"
EXTRACT_DIR="${WORKDIR}/unzipped"
mkdir -p "${EXTRACT_DIR}"

echo "[*] Attempting direct download of ${ZIP_FILE} from branch '${BRANCH}'..."
if curl -fsSL -o "${ZIP_DST}" "${RAW_MAIN_URL}"; then
  echo "[*] Downloaded ${ZIP_FILE} from '${BRANCH}'."
elif curl -fsSL -o "${ZIP_DST}" "${RAW_MASTER_URL}"; then
  echo "[*] Downloaded ${ZIP_FILE} from fallback 'master'."
else
  echo "[!] Direct raw download failed. Falling back to shallow clone..."
  GIT_DIR="${WORKDIR}/repo"
  git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${GIT_DIR}" 2>/dev/null || \
  git clone --depth 1 --branch master "${REPO_URL}" "${GIT_DIR}"
  if [[ ! -f "${GIT_DIR}/${ZIP_FILE}" ]]; then
    echo "ERROR: Could not find '${ZIP_FILE}' in repo '${REPO_URL}'"; exit 1
  fi
  cp -f "${GIT_DIR}/${ZIP_FILE}" "${ZIP_DST}"
fi

echo "[*] Unzipping site archive..."
unzip -q "${ZIP_DST}" -d "${EXTRACT_DIR}"

# If zip expands to a single top-level folder, use it; otherwise use all files
TOP_LIST=( "${EXTRACT_DIR}"/* )
if [[ ${#TOP_LIST[@]} -eq 1 && -d "${TOP_LIST[0]}" ]]; then
  WEB_CONTENT_DIR="${TOP_LIST[0]}"
else
  WEB_CONTENT_DIR="${EXTRACT_DIR}"
fi

if ! find "${WEB_CONTENT_DIR}" -maxdepth 1 -type f \( -iname "index.php" -o -iname "index.html" -o -iname "index.htm" \) | grep -q . ; then
  echo "[!] Warning: No index.* at top of extracted content. Proceeding anyway."
fi

echo "[*] Copying web content into container:/var/www/html/ ..."
docker cp "${WEB_CONTENT_DIR}/." "${CONTAINER_NAME}:/var/www/html/"

echo "[*] Fixing permissions inside container..."
docker exec "${CONTAINER_NAME}" bash -lc 'chown -R www-data:www-data /var/www/html && \
  find /var/www/html -type d -exec chmod 0755 {} \; && \
  find /var/www/html -type f -exec chmod 0644 {} \;'

echo "[*] Enabling .htaccess overrides (AllowOverride All) for /var/www/html ..."
docker exec "${CONTAINER_NAME}" bash -lc '
  APACHE_CONF="/etc/apache2/sites-available/000-default.conf"
  if ! grep -q "AllowOverride All" "$APACHE_CONF"; then
    awk '\''
      BEGIN {inblock=0}
      /<Directory \/var\/www\/>/ {inblock=1}
      {print}
      inblock==1 && /AllowOverride/ {inblock=2}
    '\'' "$APACHE_CONF" >/dev/null 2>&1 || true
    # Append a directory block if none exists
    if ! grep -q "<Directory /var/www/html>" "$APACHE_CONF"; then
      printf "\n<Directory /var/www/html>\n    AllowOverride All\n    Require all granted\n</Directory>\n" >> "$APACHE_CONF"
    fi
  fi
  a2enmod rewrite >/dev/null 2>&1 || true
'

echo "[*] Graceful reload (or restart fallback)..."
if ! docker exec "${CONTAINER_NAME}" bash -lc 'apache2ctl -k graceful' >/dev/null 2>&1; then
  docker restart "${CONTAINER_NAME}" >/dev/null
fi

IP_HINT="$(hostname -I 2>/dev/null | awk "{print \$1}")"
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
echo "Logs:     docker logs -f ${CONTAINER_NAME}"
echo "Remove:   docker rm -f ${CONTAINER_NAME} && docker rmi ${IMAGE_NAME}"
echo "============================================================"
