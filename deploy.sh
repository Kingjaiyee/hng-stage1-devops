#!/usr/bin/env bash
# Deploy a Dockerized app to a remote Linux server with Nginx reverse proxy.
# POSIX-friendly Bash (no arrays required). Tested on Ubuntu 20.04+/Debian 11+.
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh              # interactive mode
#   ./deploy.sh --cleanup    # remove deployed resources on the remote host
#
# Requirements on local:
#   - git, ssh, rsync or scp, sed, awk
#
# Notes:
#   - This script is idempotent; safe to re-run. It will pull latest code and redeploy.
#   - It supports either docker-compose.yml or a Dockerfile.
#   - It sets up Nginx to proxy port 80 -> app's internal port.
#
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
START_TS="$(date +'%Y-%m-%d_%H-%M-%S')"
LOG_FILE="deploy_${START_TS}.log"

# ---------- Logging helpers ----------
log() { printf "[%s] %s\n" "$(date +"%F %T")" "$*" | tee -a "$LOG_FILE" ; }
fail() { log "ERROR: $*"; exit 1; }
trap 'fail "Unexpected error at line $LINENO."' ERR

# ---------- Globals (populated interactively) ----------
GIT_URL=""
GIT_PAT=""
GIT_BRANCH="main"
SSH_USER=""
SSH_HOST=""
SSH_KEY=""
APP_PORT=""         # internal container/app port (e.g., 8000)
REPO_DIR=""         # local repo directory name (derived)
PROJECT_NAME=""     # derived from repo name (alnum/hyphen only)
REMOTE_DIR=""       # relative to remote $HOME (e.g., apps/myapp)
CLEANUP_MODE="false"

# ---------- Helpers ----------
command_exists() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
  for c in git ssh rsync sed awk; do
    command_exists "$c" || fail "Required command not found: $c"
  done
}

prompt() {
  # prompt "Label" "VAR" "default" "is_secret(true/false)"
  label="$1"; var="$2"; def="${3-}"; secret="${4-false}"
  if [ -n "$def" ]; then
    prompt_text="$label [$def]: "
  else
    prompt_text="$label: "
  fi
  if [ "$secret" = "true" ]; then
    read -r -s -p "$prompt_text" input; echo
  else
    read -r -p "$prompt_text" input
  fi
  if [ -z "$input" ] && [ -n "$def" ]; then
    eval "$var=\"\$def\""
  else
    eval "$var=\"\$input\""
  fi
}

extract_repo_dir() {
  # turn https://github.com/user/repo.git -> repo
  # or git@github.com:user/repo.git -> repo
  b="$(printf "%s" "$1" | sed 's#\.git$##' | awk -F'/' '{print $NF}')"
  printf "%s" "$b"
}

normalize_project_name() {
  printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g'
}

embed_pat_in_url() {
  # Convert URL to https and inject PAT if not already provided in the URL.
  u="$1"; pat="$2"
  case "$u" in
    https://*)
      printf "%s" "$(printf "%s" "$u" | sed "s#https://#https://${pat}@#")"
      ;;
    http://*)
      printf "%s" "$(printf "%s" "$u" | sed "s#http://#http://${pat}@#")"
      ;;
    git@github.com:*)
      # transform SSH URL to HTTPS with PAT
      path="$(printf "%s" "$u" | sed 's#git@github.com:##')"
      printf "https://%s@github.com/%s" "$pat" "$path"
      ;;
    *)
      printf "%s" "$u"
      ;;
  esac
}

ssh_base() {
  printf "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i %s %s@%s" "$SSH_KEY" "$SSH_USER" "$SSH_HOST"
}

scp_base() {
  printf "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i %s" "$SSH_KEY"
}

rsync_base() {
  printf "rsync -az --delete -e 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i %s'" "$SSH_KEY"
}

# ---------- Input collection ----------
collect_inputs() {
  log "Collecting parameters..."

  prompt "Git repository URL" GIT_URL
  [ -n "$GIT_URL" ] || fail "Git repo URL is required."

  prompt "Personal Access Token (PAT) - scopes: repo, read:packages (hidden)" GIT_PAT "" "true"
  [ -n "$GIT_PAT" ] || fail "PAT is required."

  prompt "Branch name" GIT_BRANCH "main"
  prompt "Remote SSH username" SSH_USER
  [ -n "$SSH_USER" ] || fail "SSH username is required."

  prompt "Remote server IP / DNS" SSH_HOST
  [ -n "$SSH_HOST" ] || fail "SSH host is required."

  prompt "SSH private key path" SSH_KEY "$HOME/.ssh/id_rsa"
  [ -f "$SSH_KEY" ] || fail "SSH key not found at $SSH_KEY"

  prompt "Application INTERNAL port (container/app port, e.g., 8000)" APP_PORT "8000"
  case "$APP_PORT" in
    ''|*[!0-9]*) fail "App port must be numeric." ;;
  esac

  REPO_DIR="$(extract_repo_dir "$GIT_URL")"
  PROJECT_NAME="$(normalize_project_name "$REPO_DIR")"
  REMOTE_DIR="apps/${PROJECT_NAME}"   # relative path under remote $HOME

  log "Repo dir: $REPO_DIR"
  log "Project name: $PROJECT_NAME"
  log "Remote deploy dir: ~/$REMOTE_DIR"
}

# ---------- Git clone / update ----------
clone_or_update_repo() {
  log "Cloning or updating repository..."
  AUTH_URL="$(embed_pat_in_url "$GIT_URL" "$GIT_PAT")"

  if [ -d "$REPO_DIR/.git" ]; then
    log "Repo exists locally. Pulling latest..."
    ( cd "$REPO_DIR" && git fetch --all && git reset --hard "origin/${GIT_BRANCH}" && git checkout "$GIT_BRANCH" && git pull --ff-only ) || fail "Git pull failed."
  else
    git clone --branch "$GIT_BRANCH" "$AUTH_URL" "$REPO_DIR" || fail "Git clone failed."
  fi
  cd "$REPO_DIR"
  log "Now in $(pwd)"

  if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    log "Found docker-compose file."
  elif [ -f "Dockerfile" ]; then
    log "Found Dockerfile."
  else
    fail "Neither docker-compose.yml nor Dockerfile found in project."
  fi
}

# ---------- SSH connectivity ----------
check_connectivity() {
  log "Checking SSH connectivity to $SSH_USER@$SSH_HOST ..."
  $(ssh_base) "echo 'SSH OK from $(hostname)' >/dev/null" || fail "SSH connectivity failed."
  log "SSH connectivity OK."
}

# ---------- Remote preparation ----------
remote_prepare() {
  log "Preparing remote environment (Docker, Compose, Nginx)..."
  $(ssh_base) "bash -s" <<'REMOTE_EOF'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

# Packages & updates
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release gettext-base

# Install Docker (if missing)
if ! command -v docker >/dev/null 2>&1; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
  $(. /etc/os-release; echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
  sudo systemctl enable --now docker
fi

# Ensure docker-compose (v2 plugin) available; fallback to docker-compose v1 if needed
if ! docker compose version >/dev/null 2>&1; then
  if ! command -v docker-compose >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose || true
  fi
fi

# Install Nginx (if missing)
if ! command -v nginx >/dev/null 2>&1; then
  sudo apt-get install -y nginx
  sudo systemctl enable --now nginx
fi

# Print versions
docker --version || true
docker compose version || docker-compose --version || true
nginx -v || true

# Create apps dir
mkdir -p "$HOME/apps"
REMOTE_EOF
  log "Remote preparation complete."
}

# ---------- Transfer project ----------
transfer_project() {
  log "Transferring project files to remote: ~/${REMOTE_DIR} ..."
  $(ssh_base) "mkdir -p ~/${REMOTE_DIR}"
  log "DEBUG: will rsync to ${SSH_USER}@${SSH_HOST}:~/${REMOTE_DIR}/"
  eval "$(rsync_base)" . "${SSH_USER}@${SSH_HOST}:~/${REMOTE_DIR}/"
  log "Transfer complete."
}

# ---------- Remote deployment ----------
remote_deploy() {
  log "Deploying on remote host..."
  CONTAINER_NAME="${PROJECT_NAME}_app"
  NGINX_SITE="/etc/nginx/sites-available/${PROJECT_NAME}.conf"
  NGINX_LINK="/etc/nginx/sites-enabled/${PROJECT_NAME}.conf"
  APP_PORT_VAL="$APP_PORT"

  # Build the remote script (expand local vars like ${REMOTE_DIR}, keep remote vars escaped)
  RSCRIPT=$(cat <<EOF
set -Eeuo pipefail
cd ~/${REMOTE_DIR}

# Decide compose vs Dockerfile
USE_COMPOSE="no"
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  USE_COMPOSE="yes"
fi

# Stop existing containers cleanly (idempotent)
if [ "\$USE_COMPOSE" = "yes" ]; then
  (docker compose down || docker-compose down || true) >/dev/null 2>&1 || true
else
  if docker ps -a --format '{{"{{.Names}}"}}' | grep -q '^${CONTAINER_NAME}\$'; then
    docker rm -f '${CONTAINER_NAME}' || true
  fi
fi

# Build & run
if [ "\$USE_COMPOSE" = "yes" ]; then
  (docker compose up -d --build || docker-compose up -d --build)
else
  docker build -t ${PROJECT_NAME}:latest .
  docker run -d --restart unless-stopped --name ${CONTAINER_NAME} -p 127.0.0.1:${APP_PORT_VAL}:${APP_PORT_VAL} ${PROJECT_NAME}:latest
fi

# Simple health checks
sleep 3
docker ps --format 'table {{.Names}}\\t{{.Status}}'

# Nginx reverse proxy config (quoted heredoc + envsubst only for \$APP_PORT_VAL)
SITE_FILE="${NGINX_SITE}"
cat <<'NGINX_CONF' | APP_PORT_VAL=${APP_PORT_VAL} envsubst '\$APP_PORT_VAL' | sudo tee "\$SITE_FILE" >/dev/null
server {
    listen 80;
    server_name _;

    # Increase proxy limits as needed
    client_max_body_size 25m;
    proxy_read_timeout 90s;

    location / {
        proxy_pass http://127.0.0.1:\$APP_PORT_VAL;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Placeholder for SSL: replace with Certbot config later.
    # sudo apt-get install -y certbot python3-certbot-nginx
    # sudo certbot --nginx -d your.domain.com
}
NGINX_CONF

# Enable site
sudo ln -sf "${NGINX_SITE}" "${NGINX_LINK}"
sudo nginx -t
sudo systemctl reload nginx

# Validate locally on remote
curl -fsS "http://127.0.0.1" >/dev/null && echo "Local Nginx proxy OK" || echo "Local Nginx proxy FAILED"
curl -fsS "http://127.0.0.1:${APP_PORT_VAL}" >/dev/null && echo "App port OK" || echo "App port FAILED"
EOF
)
  $(ssh_base) "bash -s" <<< "$RSCRIPT"
  log "Remote deployment complete."
}

# ---------- Remote validation (external) ----------
validate_external() {
  log "Validating external HTTP (via Nginx on port 80)..."
  if command_exists curl; then
    if curl -fsS "http://${SSH_HOST}" >/dev/null; then
      log "Public endpoint reachable: http://${SSH_HOST}"
    else
      log "WARNING: Could not reach http://${SSH_HOST}. Check firewall or Nginx config."
    fi
  else
    log "curl not installed locally; skipping external check."
  fi
}

# ---------- Cleanup mode ----------
remote_cleanup() {
  log "Running CLEANUP on remote host for project ${PROJECT_NAME} ..."
  CONTAINER_NAME="${PROJECT_NAME}_app"
  NGINX_SITE="/etc/nginx/sites-available/${PROJECT_NAME}.conf"
  NGINX_LINK="/etc/nginx/sites-enabled/${PROJECT_NAME}.conf"

  $(ssh_base) "bash -s" <<REMOTE_EOF
set -Eeuo pipefail
cd ~/"${REMOTE_DIR}" 2>/dev/null || true
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  (docker compose down || docker-compose down) || true
fi
if docker ps -a --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}\$'; then
  docker rm -f '${CONTAINER_NAME}' || true
fi
sudo rm -f "${NGINX_LINK}" "${NGINX_SITE}" || true
sudo nginx -t && sudo systemctl reload nginx || true
rm -rf ~/"${REMOTE_DIR}" || true
echo "Cleanup complete."
REMOTE_EOF
  log "Cleanup finished."
}

# ---------- Main ----------
main() {
  require_cmds

  # Parse flags
  for arg in "$@"; do
    case "$arg" in
      --cleanup) CLEANUP_MODE="true" ;;
      *) ;;
    esac
  done

  collect_inputs
  if [ "$CLEANUP_MODE" = "true" ]; then
    check_connectivity
    remote_cleanup
    log "Done. (cleanup)"
    exit 0
  fi

  clone_or_update_repo
  check_connectivity
  remote_prepare
  transfer_project
  remote_deploy
  validate_external

  log "SUCCESS: Deployment finished."
  log "Log file: $LOG_FILE"
  log "Re-run this script any time to redeploy safely. Use --cleanup to remove."
}

main "$@"
