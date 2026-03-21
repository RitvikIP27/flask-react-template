# One-Click Auto-Deploy — React + Flask CI/CD Pipeline

> **Goal:** Build automation so that pushing code to GitHub auto-deploys a React frontend + Python (Flask) backend to a server.
>
> **Forked from:** [jalantechnologies/flask-react-template](https://github.com/jalantechnologies/flask-react-template)

---

## 📌 Table of Contents

1. [What This Does](#what-this-does)
2. [Architecture](#architecture)
3. [deploy.sh](#1-deploysh)
4. [GitHub Actions Workflow](#2-github-actions-workflow)
5. [Nginx Proxy Config](#3-nginx-reverse-proxy)
6. [Setup Steps](#4-setup-steps)
7. [⭐ Local Testing (How I Tested This)](#-local-testing--how-i-tested-this)
8. [Troubleshooting](#troubleshooting)

---

## What This Does

This project adds a **complete CI/CD pipeline** to a full-stack React + Python application.

```
Push to main
     │
     ▼
GitHub Actions triggers
     │
     ▼
SSH into server → run deploy.sh
     │
     ├── Build React frontend  →  dist/public/  →  /var/www/html
     │
     ├── Setup Python venv  →  pip install  →  start Gunicorn
     │
     └── Nginx reloads  →  serves React + proxies /api/ → Flask
```

---

## Architecture

```
Browser
   │
   ▼
Nginx (:80)
   ├── /          →  React SPA  (/var/www/html)
   └── /api/      →  Gunicorn  (unix:/tmp/app.sock)
                            │
                            ▼
                      Flask Backend
                   (src/apps/backend/server.py)
```

---

## 1. `deploy.sh`

> Write a bash script that pulls code, builds frontend, sets up backend, and reloads nginx.

```bash
#!/bin/bash
set -e
echo "Starting deployment..."

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR=$APP_DIR/src/apps/backend
NGINX_DIR=/var/www/html
START=$(date +%s)

# ── Pull latest code ──────────────────────────────────────────────
echo "Pulling latest code..."
cd $APP_DIR
git pull origin main

# ── Build frontend ────────────────────────────────────────────────
echo "Building frontend..."
cd $APP_DIR
npm ci
npm run build

echo "Deploying frontend..."
sudo rm -rf $NGINX_DIR/*
sudo cp -r $APP_DIR/dist/public/* $NGINX_DIR/

# ── Setup backend ─────────────────────────────────────────────────
echo "Setting up backend..."
cd $BACKEND_DIR
if [ ! -d "venv" ]; then
  python3 -m venv venv
fi
source venv/bin/activate
pip install -r requirements.txt

# ── Restart backend ───────────────────────────────────────────────
echo "Restarting backend..."
pkill -f gunicorn || true
nohup venv/bin/gunicorn --bind unix:/tmp/app.sock server:app > gunicorn.log 2>&1 &

# ── Reload Nginx ──────────────────────────────────────────────────
echo "Reloading Nginx..."
sudo nginx -t
sudo systemctl reload nginx

END=$(date +%s)
echo "Deployment done in $((END-START)) seconds!"
```

### Why each line is written this way

| Line | Reason |
|------|--------|
| `set -e` | Abort immediately on any error — no silent failures |
| `$(cd "$(dirname "$0")" && pwd)` | Resolves `APP_DIR` to wherever the script lives — works on any machine |
| `if [ ! -d "venv" ]` | Only creates venv if it doesn't exist — makes script **idempotent** |
| `pkill -f gunicorn \|\| true` | `\|\| true` prevents `set -e` aborting on first deploy when nothing is running yet |
| `sudo nginx -t` before reload | Tests config for errors **before** reloading — a bad config won't take down the site |
| Full absolute path on `cp` | Script may have `cd`'d into a subdirectory — relative paths would break |

---

## 2. GitHub Actions Workflow

> Trigger on push to main. SSH into server. Run deploy.sh. Store credentials as secrets.

**`.github/workflows/deploy.yml`**

```yaml
name: Deploy App

on:
  push:
    branches:
      - main

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.SERVER_IP }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          script: |
            cd ~/app
            bash deploy.sh
```

### GitHub Secrets Setup

Go to your repo → **Settings → Secrets and variables → Actions → New repository secret**

| Secret Name | Value |
|-------------|-------|
| `SERVER_IP` | Your server's public IP address |
| `SERVER_USER` | Linux username on the server (e.g. `ubuntu`) |
| `SSH_PRIVATE_KEY` | Full contents of your private key file |

```bash
# Generate a dedicated deploy key pair (run on your local machine)
ssh-keygen -t ed25519 -C "github-deploy" -f ~/.ssh/deploy_key -N ""

# Copy public key to server
ssh-copy-id -i ~/.ssh/deploy_key.pub USER@YOUR_SERVER_IP

# Print private key → paste this into the SSH_PRIVATE_KEY secret
cat ~/.ssh/deploy_key
```

> Include the full `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END-----` lines when pasting.

---

## 3. Nginx Reverse Proxy

> Serve frontend static files. Proxy `/api/` calls to the Flask backend socket.

**`nginx-config/flask-react.conf`**

```nginx
upstream flask_backend {
    server unix:/tmp/flask_app.sock fail_timeout=0;
}

server {
    listen 80;
    server_name YOUR_DOMAIN_OR_IP;

    root /var/www/html;
    index index.html;

    # React SPA — fallback to index.html for client-side routing
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Reverse proxy: /api/ → Gunicorn → Flask
    location /api/ {
        proxy_pass         http://flask_backend;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
    }
}
```

```bash
# Install and enable
sudo cp nginx-config/flask-react.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/flask-react.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo nginx -s reload
```

> UNIX socket (`unix:/tmp/app.sock`) is used over TCP — faster for local process-to-process communication.

---

## 4. Setup Steps

### Server Preparation

```bash
# Install dependencies
sudo apt update && sudo apt install -y git nginx python3 python3-venv nodejs npm

# Clone your forked repo
git clone https://github.com/YOUR_USERNAME/flask-react-template.git ~/app

# Make deploy script executable
chmod +x ~/app/deploy.sh

# Allow deploy script to use sudo without password prompt
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/nginx,/bin/systemctl,/bin/cp,/bin/rm" \
  | sudo tee /etc/sudoers.d/deploy-script
```
---

## ⭐ Local Testing — How I Tested This

> **Context:** This pipeline was built and verified entirely on a **local Linux machine** — no cloud VPS was used.
> The GitHub Actions SSH step is correctly written for a real server. Since a local machine has no public IP,
> the script was validated by running it directly. Here is the full account of what was tested, what broke, and how it was fixed.

---

### ✅ Running the Script

```bash
cd ~/Desktop/flask-react-template
bash deploy.sh
```

### 🔍 Bugs Hit During Testing & How They Were Fixed

Every one of these was a real error encountered and debugged during development:

| # | Error | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | `cd: /home/user/app: No such file or directory` | `APP_DIR` was hardcoded to `~/app` but the repo was cloned elsewhere | Changed `APP_DIR` to dynamic `$(cd "$(dirname "$0")" && pwd)` — resolves to wherever the script lives |
| 2 | `cp: cannot stat 'build/*'` | Assumed CRA-style `build/` output but template uses webpack → `dist/public/` | Found actual path via `cat package.json` → fixed to `dist/public/*` |
| 3 | `cp: cannot stat 'dist/public*'` | Missing `/` in glob — `dist/public*` matched nothing | Fixed to `dist/public/*` with the slash |
| 4 | `[sudo] password for user:` mid-script | No passwordless sudo configured | Added `NOPASSWD` sudoers rule for nginx and cp |
| 5 | Gunicorn module `app:app` not found | Entry file is `server.py`, not `app.py` | Found via `grep "Flask(__name__)"` → fixed module string to `server:app` |
| 6 | Script ran inside active `(venv)` | Terminal session had a venv already activated | Ran `deactivate` first — the script manages its own venv internally |

---


- ✔ Frontend built and deployed to nginx web root
- ✔ Python venv created, all dependencies installed
- ✔ Gunicorn running on UNIX socket
- ✔ Nginx config passes syntax check and reloads cleanly
- ✔ Script completed in **63 seconds**
- ✔ Script is **idempotent** — re-ran multiple times with no errors

---

###  Why GitHub Actions Wasn't Live-Triggered

The `deploy.yml` workflow is **correctly structured** for a real server. It wasn't live-triggered because:

- A local machine has no static public IP
- Port 22 is not exposed to the internet from a home network
- GitHub's cloud runner has no route to `localhost`

The workflow was still validated by:
- Pushing it to the forked repo and confirming it appears in the **Actions** tab
- Verifying the YAML is syntactically correct
- Confirming it would trigger automatically on the next push to `main`

**To go live:** add 3 GitHub secrets → push → done. The pipeline runs automatically.



---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `cp: cannot stat dist/public/*` | Run `npm run build` first, or check webpack `output-path` in `package.json` |
| `502 Bad Gateway` | Gunicorn not running — check `gunicorn.log` or `journalctl -u flask-app` |
| `sudo` password prompt | Add NOPASSWD sudoers rule (see Setup above) |
| `pkill` exits with error | Expected on first run — `\|\| true` handles this safely |
| Actions SSH timeout | Port 22 not open in server firewall / security group |
| Blank page in browser | Confirm `dist/public/` contains `index.html`, check `NGINX_DIR` |
| `set -e` aborts mid-script | A command failed — line number in error output tells you exactly where |

---

<div align="center">

Built on [jalantechnologies/flask-react-template](https://github.com/jalantechnologies/flask-react-template)

`deploy.sh` is idempotent — safe to re-run as many times as needed
ALL the files have been added to this workflow w

</div>
# deployed
