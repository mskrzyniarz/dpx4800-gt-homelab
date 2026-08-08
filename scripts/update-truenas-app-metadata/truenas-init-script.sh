#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="update-truenas-app-metadata-init"
SERVICE_NAME="update-truenas-app-metadata.service"
UNIT_SOURCE="/mnt/tank/apps/scripts/update-truenas-app-metadata/${SERVICE_NAME}"
UNIT_TARGET="/etc/systemd/system/${SERVICE_NAME}"

log() {
    printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

error() {
    printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
    exit 1
}

command -v install >/dev/null 2>&1 || error "Required command not found: install"
command -v systemctl >/dev/null 2>&1 || error "Required command not found: systemctl"

log "Installing systemd unit..."

[[ -f "$UNIT_SOURCE" ]] || error "Unit file not found: $UNIT_SOURCE"

install \
    -o root \
    -g root \
    -m 0644 \
    "$UNIT_SOURCE" \
    "$UNIT_TARGET"

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

log "Service enabled and started: $SERVICE_NAME"