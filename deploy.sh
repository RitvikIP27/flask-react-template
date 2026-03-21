#!/bin/bash
set -e
echo "Starting deployment..."
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR=$APP_DIR/src/apps/backend
NGINX_DIR=/var/www/html
START=$(date +%s)

echo "Pulling latest code..."
cd $APP_DIR
git pull origin main

echo "Building frontend..."
cd $APP_DIR
npm ci
npm run build

echo "Deploying frontend..."
sudo rm -rf $NGINX_DIR/*
sudo cp -r $APP_DIR/dist/public/* $NGINX_DIR/

echo "Setting up backend..."
cd $BACKEND_DIR
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate
pip install -r requirements.txt

echo "Restarting backend..."
pkill -f gunicorn || true
nohup venv/bin/gunicorn --bind unix:/tmp/app.sock server:app > gunicorn.log 2>&1 &

# -------------------------
# Update Nginx config
# -------------------------
echo "Updating Nginx config..."
sudo cp "$APP_DIR/nginx.conf" /etc/nginx/sites-available/default

# -------------------------
# Reload Nginx
# -------------------------
echo " Reloading Nginx..."
sudo nginx -t
sudo systemctl reload nginx

END=$(date +%s)
echo "Deployment done in $((END-START)) seconds!"