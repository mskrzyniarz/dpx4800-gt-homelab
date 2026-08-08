#!/usr/bin/env bash

# update-truenas-app-metadata-daemon.sh
#
# Purpose:
#   Runs as a long-lived background daemon (typically under systemd) and listens
#   for Docker "container start" events. For each started container, it attempts
#   to locate a source metadata file based on SOURCE_METADATA_PATTERN and, when
#   found, executes update-truenas-app-metadata.sh in non-interactive mode.
#
# High-level flow:
#   1. Validate runtime dependencies and configuration patterns.
#   2. Ensure LOCK_DIR exists for per-container lock files.
#   3. Subscribe to Docker start events.
#   4. For each container event:
#      - resolve metadata source path from SOURCE_METADATA_PATTERN
#      - skip when source metadata file does not exist
#      - build optional env file list from SHARED_ENV and APP_ENV_PATTERN
#      - run update-truenas-app-metadata.sh with:
#          -s <source-metadata> [-e <env1,env2,...>] -y
#      - prevent duplicate parallel execution for the same container via flock
#   5. Reconnect to Docker events stream on disconnect.
#   6. Handle SIGTERM/SIGINT gracefully and wait for active child jobs.
#
# Notes:
#   - "{{CONTAINER_NAME}}" placeholder is replaced with runtime container name.
#   - DISPLAY_UPDATE_METADATA_SCRIPT_LOGS controls whether child script output is
#     forwarded to journald (true) or suppressed (false).

set -Eeuo pipefail

# Handles Docker "container start" events and triggers metadata updates.
SCRIPT_NAME="update-truenas-app-metadata-daemon"
BASE_DIR="/mnt/tank/apps/scripts/update-truenas-app-metadata"
UPDATE_METADATA_SCRIPT="${BASE_DIR}/update-truenas-app-metadata.sh"
LOCK_DIR="${BASE_DIR}/locks"
RECONNECT_DELAY=5

# Optional shared env file appended to -e when it exists.
SHARED_ENV="/mnt/tank/apps/compose/shared/.env"

# Replace {{CONTAINER_NAME}} with Docker container name from the event.
SOURCE_METADATA_PATTERN="/mnt/tank/apps/compose/{{CONTAINER_NAME}}/metadata.yaml"

# Optional pattern for per-container env file. Keep empty to disable.
APP_ENV_PATTERN="/mnt/tank/apps/compose/{{CONTAINER_NAME}}/.env"

# When true, forward child script output to journald.
DISPLAY_UPDATE_METADATA_SCRIPT_LOGS=false

SHUTDOWN=0
CURRENT_EVENT_PID=0

declare -A CHILD_PIDS=()

log() {
    local level="$1"
    shift

    printf '[%s] [%s] [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$SCRIPT_NAME" \
        "$level" \
        "$*"
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@" >&2
}

is_true() {
    local value="${1:-}"
    value="${value,,}"

    [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
}

validate_configuration() {
    [[ -x "$UPDATE_METADATA_SCRIPT" ]] || {
        log_error "Action script does not exist or is not executable: $UPDATE_METADATA_SCRIPT"
        exit 1
    }

    command -v docker >/dev/null 2>&1 || {
        log_error "docker command not found"
        exit 1
    }

    command -v flock >/dev/null 2>&1 || {
        log_error "flock command not found"
        exit 1
    }

    command -v mkfifo >/dev/null 2>&1 || {
        log_error "mkfifo command not found"
        exit 1
    }

    [[ "$SOURCE_METADATA_PATTERN" == *"{{CONTAINER_NAME}}"* ]] || {
        log_error "SOURCE_METADATA_PATTERN must include {{CONTAINER_NAME}}"
        exit 1
    }

    if [[ -n "$APP_ENV_PATTERN" && "$APP_ENV_PATTERN" != *"{{CONTAINER_NAME}}"* ]]; then
        log_error "APP_ENV_PATTERN must include {{CONTAINER_NAME}} when it is set"
        exit 1
    fi
}

prepare_lock_dir() {
    if ! mkdir -p "$LOCK_DIR"; then
        log_error "Cannot create lock directory: $LOCK_DIR"
        exit 1
    fi
}

render_pattern() {
    local pattern="$1"
    local container_name="$2"

    printf '%s' "${pattern//\{\{CONTAINER_NAME\}\}/$container_name}"
}

join_by_comma() {
    local -a values=("$@")
    local old_ifs="$IFS"

    IFS=,
    printf '%s' "${values[*]}"
    IFS="$old_ifs"
}

shutdown() {
    if [[ "$SHUTDOWN" -eq 1 ]]; then
        return
    fi

    SHUTDOWN=1
    log_info "Shutdown requested"

    if [[ "$CURRENT_EVENT_PID" -gt 0 ]] && kill -0 "$CURRENT_EVENT_PID" 2>/dev/null; then
        log_info "Stopping Docker event listener PID=$CURRENT_EVENT_PID"
        kill -TERM "$CURRENT_EVENT_PID" 2>/dev/null || true
    fi

    local pid
    for pid in "${!CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Sending SIGTERM to PID=$pid (container=${CHILD_PIDS[$pid]})"
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
}

trap shutdown SIGTERM SIGINT

run_action() {
    local container_name="$1"
    local source_file="$2"

    local lock_file="${LOCK_DIR}/${container_name}.lock"
    exec 200>"$lock_file"

    if ! flock -n 200; then
        log_warn "Action already running for container '$container_name'; skipping duplicate event"
        exec 200>&-
        return 0
    fi

    if [[ ! -f "$source_file" ]]; then
        log_info "Source metadata file not found for '$container_name'; skipping"
        flock -u 200
        exec 200>&-
        return 0
    fi

    if ! docker inspect "$container_name" >/dev/null 2>&1; then
        log_warn "Container '$container_name' no longer exists"
        flock -u 200
        exec 200>&-
        return 0
    fi

    local running
    running="$(docker inspect --format '{{.State.Running}}' "$container_name" 2>/dev/null || echo 'false')"

    if [[ "$running" != "true" ]]; then
        log_warn "Container '$container_name' is no longer running"
        flock -u 200
        exec 200>&-
        return 0
    fi

    local -a app_env_files=()
    if [[ -n "$SHARED_ENV" && -f "$SHARED_ENV" ]]; then
        app_env_files+=("$SHARED_ENV")
    fi

    if [[ -n "$APP_ENV_PATTERN" ]]; then
        local app_env_file
        app_env_file="$(render_pattern "$APP_ENV_PATTERN" "$container_name")"
        if [[ -f "$app_env_file" ]]; then
            app_env_files+=("$app_env_file")
        fi
    fi

    local -a cmd_args=("-s" "$source_file" "-y")
    if (( ${#app_env_files[@]} > 0 )); then
        cmd_args+=("-e" "$(join_by_comma "${app_env_files[@]}")")
    fi

    log_info "Executing '$UPDATE_METADATA_SCRIPT' for '$container_name' (source='$source_file')"

    local start_time
    local end_time
    local duration
    local exit_code

    start_time=$(date +%s)

    if is_true "$DISPLAY_UPDATE_METADATA_SCRIPT_LOGS"; then
        "$UPDATE_METADATA_SCRIPT" "${cmd_args[@]}"
        exit_code=$?
    else
        "$UPDATE_METADATA_SCRIPT" "${cmd_args[@]}" >/dev/null 2>&1
        exit_code=$?
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    if [[ "$exit_code" -eq 0 ]]; then
        log_info "Action completed successfully for '$container_name' in ${duration}s"
    else
        log_error "Action failed for '$container_name' (exit_code=$exit_code, duration=${duration}s)"
    fi

    flock -u 200
    exec 200>&-

    return "$exit_code"
}

start_action() {
    local container_name="$1"

    if [[ "$SHUTDOWN" -eq 1 ]]; then
        return
    fi

    local source_file
    source_file="$(render_pattern "$SOURCE_METADATA_PATTERN" "$container_name")"

    if [[ ! -f "$source_file" ]]; then
        log_info "No source metadata for '$container_name' at '$source_file'; nothing to do"
        return
    fi

    log_info "Docker start event received for '$container_name'"

    run_action "$container_name" "$source_file" &

    local pid=$!
    CHILD_PIDS["$pid"]="$container_name"

    log_info "Action process started for '$container_name' (PID=$pid)"
}

reap_children() {
    local pid
    local container_name
    local exit_code

    for pid in "${!CHILD_PIDS[@]}"; do
        container_name="${CHILD_PIDS[$pid]}"

        if kill -0 "$pid" 2>/dev/null; then
            continue
        fi

        if wait "$pid"; then
            exit_code=0
        else
            exit_code=$?
        fi

        if [[ "$exit_code" -eq 0 ]]; then
            log_info "Action process finished for '$container_name' (PID=$pid)"
        else
            log_error "Action process failed for '$container_name' (PID=$pid, exit_code=$exit_code)"
        fi

        unset 'CHILD_PIDS[$pid]'
    done
}

listen_for_events() {
    log_info "Connecting to Docker event stream..."

    local tmp_dir
    local fifo
    local event_pid

    tmp_dir="$(mktemp -d)"
    fifo="${tmp_dir}/docker-events.fifo"

    if ! mkfifo "$fifo"; then
        log_error "Cannot create FIFO: $fifo"
        rm -rf "$tmp_dir"
        return 1
    fi

    (
        docker events \
            --filter 'type=container' \
            --filter 'event=start' \
            --format '{{.Actor.Attributes.name}}' \
            > "$fifo"
    ) &

    event_pid=$!
    CURRENT_EVENT_PID=$event_pid

    log_info "Docker event listener PID=$event_pid"

    exec 201<"$fifo"
    rm -f "$fifo"
    rmdir "$tmp_dir" 2>/dev/null || true

    while [[ "$SHUTDOWN" -eq 0 ]]; do
        local container_name

        if IFS= read -r container_name <&201; then
            if [[ -z "$container_name" ]]; then
                log_warn "Received empty container name"
                continue
            fi

            if [[ ! "$container_name" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
                log_warn "Ignoring invalid container name: '$container_name'"
                continue
            fi

            start_action "$container_name"
            reap_children
        else
            break
        fi
    done

    exec 201<&-

    if kill -0 "$event_pid" 2>/dev/null; then
        log_info "Stopping Docker event listener PID=$event_pid"
        kill -TERM "$event_pid" 2>/dev/null || true
        wait "$event_pid" 2>/dev/null || true
    fi

    CURRENT_EVENT_PID=0

    if [[ "$SHUTDOWN" -eq 1 ]]; then
        return 0
    fi

    log_warn "Docker event stream disconnected"
    return 1
}

wait_for_children() {
    log_info "Waiting for active actions to finish..."

    local pid
    local container_name

    for pid in "${!CHILD_PIDS[@]}"; do
        container_name="${CHILD_PIDS[$pid]}"

        if kill -0 "$pid" 2>/dev/null; then
            log_info "Waiting for PID=$pid (container='$container_name')"
            wait "$pid" || true
        fi
    done
}

main() {
    validate_configuration
    prepare_lock_dir

    log_info "============================================================"
    log_info "Docker event daemon starting"
    log_info "Action script: $UPDATE_METADATA_SCRIPT"
    log_info "Lock directory: $LOCK_DIR"
    log_info "Source pattern: $SOURCE_METADATA_PATTERN"
    log_info "App env pattern: ${APP_ENV_PATTERN:-<disabled>}"
    log_info "Shared env file: ${SHARED_ENV:-<disabled>}"
    log_info "Display child logs: $DISPLAY_UPDATE_METADATA_SCRIPT_LOGS"
    log_info "Reconnect delay: ${RECONNECT_DELAY}s"
    log_info "============================================================"

    while [[ "$SHUTDOWN" -eq 0 ]]; do
        listen_for_events

        if [[ "$SHUTDOWN" -eq 1 ]]; then
            break
        fi

        log_warn "Docker event listener stopped"
        log_info "Reconnecting in ${RECONNECT_DELAY}s..."

        sleep "$RECONNECT_DELAY"
        reap_children
    done

    wait_for_children
    log_info "Docker event daemon stopped"
}

main "$@"
