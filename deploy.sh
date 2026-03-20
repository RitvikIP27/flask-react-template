#!/bin/bash
set -e

echo "Starting deployment..."

APP_DIR=~/app
FRONTEND_DIR=$APP_DIR/src/apps/frontend         # package.json is at repo root
BACKEND_DIR=$APP_DIR/src/apps/backend
NGINX_DIR=/var/www/html

START=$(date +%s) #time of process

#pull altest code
echo "Pulling latest code..."
cd $APP_DIR
git pull origin main

#frontend building
echo "Building frontend..."
cd $FRONTEND_DIR
npm ci
npm run build

echo "Deploying frontend..."
sudo rm -rf $NGINX_DIR/*
sudo cp -r build/* $NGINX_DIR/ #update and rebuild nginx server 

#Backend
echo "Setting up backend..."
cd $BACKEND_DIR

if [ ! -d "venv" ]; then
  python3 -m venv venv
fi

source venv/bin/activate
pip install -r requirements.txt

nohup venv/bin/gunicorn --bind unix:/tmp/app.sock server:app > app.log 2>&1 &

#Restarting abckend
echo "Restarting backend..."

pkill -f gunicorn || true # checking if there is no availbe running process

nohup venv/bin/gunicorn --bind unix:/tmp/app.sock app:app > gunicorn.log 2>&1 &

# REload nginx
echo "Reloading Nginx..."
sudo nginx -t
sudo systemctl reload nginx

END=$(date +%s)
echo "Deployment done in $((END-START)) seconds!"