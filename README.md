# HNG Stage 1 DevOps — One-Click Remote Docker Deployment

A single Bash script (`deploy.sh`) that automates **setup → deploy → proxy → validate** of a Dockerized app on a remote Ubuntu/Debian server.

## What this does

- Collects inputs (repo, PAT, branch, SSH, app internal port)
- Installs **Docker CE + Compose v2** and **Nginx** on the remote host
- Transfers your project to `~/apps/<repo-name>`
- Deploys with **docker compose** _or_ **Dockerfile**
- Configures Nginx to proxy **80 → APP_PORT**
- Validates locally & externally; full logging
- Idempotent & **--cleanup** supported

## Quickstart

```bash
# 1) Make the script executable
chmod +x deploy.sh

# 2) Run interactively and follow prompts
./deploy.sh

# (optional) Remove everything later
./deploy.sh --cleanup
```

### Inputs you will be asked for
- Git repository URL (supports `https://` and `git@github.com:`)
- Personal Access Token (hidden input; scope: `repo`)
- Branch name (default: `main`)
- Remote SSH username, server IP/DNS, SSH key path
- **Application INTERNAL port** (the port inside the container, e.g., `8080` for your Stage-0 site)

### Using with your Stage-0 repo
If you deploy **https://github.com/Kingjaiyee/hng13-stage0-devops**, enter **8080** as the internal port. The script binds the container to `127.0.0.1:8080` and Nginx serves on `:80`.

## Requirements (local)
- `git`, `ssh`, `rsync`, `sed`, `awk`, `curl`

## Open firewall
- Cloud SG/NSG: allow TCP/80
- On server (if using ufw): `sudo ufw allow 80/tcp`

## Submission
Verify endpoint works from multiple networks. Then in Slack:
- `/stage-one-devops`
- Submit your **full name** and your **GitHub repo URL** (this repo).

---

### Troubleshooting
- Wrong APP_PORT → 502/timeout: ensure it matches the container’s listen port
- Nginx conflict → remove default site or ensure only one site listens on 80
- Compose missing → script installs v2 plugin; falls back to v1 if needed
- Docker permissions → first install may require a re-login; script uses `sudo` where needed