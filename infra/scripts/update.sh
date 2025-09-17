#!/usr/bin/env bash
set -euo pipefail
APP_DIR=/opt/wmx
cd "$APP_DIR/infra/docker"
docker compose up -d --build
