#!/usr/bin/env bash
set -euo pipefail

PRESET="APPS"
DRY_RUN=false
DATASET_FILE=""

log() {
  printf "[%s] %s\n" "$1" "$2";
}

show_error_and_exit() {
  log ERROR "$1"; exit 1;
}

show_help() {
cat <<EOF
Usage: $0 -d FILE [-p PRESET] [--dry-run]

Options:
  -d, --datasets   Dataset list file (required)
  -p, --preset     Dataset preset (default: APPS)
      --dry-run    Show only what actions will be performed
  -h, --help       Show help
EOF
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--datasets) DATASET_FILE="$2"; shift 2;;
      -p|--preset) PRESET="${2^^}"; shift 2;;
      --dry-run) DRY_RUN=true; shift;;
      -h|--help) show_help; exit 0;;
      *) show_error_and_exit "Unknown option: $1";;
    esac
  done
  [[ -n "$DATASET_FILE" ]] || show_error_and_exit "Missing required option --datasets"
}

validate(){
  command -v midclt >/dev/null || show_error_and_exit "'midclt' not found"
  command -v jq >/dev/null || show_error_and_exit "'jq' not found"
  [[ -f "$DATASET_FILE" ]] || show_error_and_exit "Dataset file not found"
  [[ -r "$DATASET_FILE" ]] || show_error_and_exit "Dataset file not readable"
  case "$PRESET" in APPS|GENERIC|SMB|MULTIPROTOCOL) ;; *) show_error_and_exit "Unsupported preset: $PRESET";; esac
}

normalize(){
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  while [[ "$s" == /* ]]; do s="${s#/}"; done
  while [[ "$s" == */ ]]; do s="${s%/}"; done
  printf "%s" "$s"
}

pool_exists(){
  midclt call pool.query | jq -e --arg n "$1" '.[]|select(.name==$n)' >/dev/null;
}

dataset_exists(){
  midclt call pool.dataset.query "[[\"name\",\"=\",\"$1\"]]"|jq -e 'length>0' >/dev/null;
}

create_dataset(){
  local dataset="$1"
  if $DRY_RUN; then log INFO "Would create $dataset (preset=$PRESET)"; return; fi
  midclt call pool.dataset.create "$(jq -n --arg n "$dataset" --arg p "$PRESET" '{name:$n,share_type:$p}')" >/dev/null \
  || show_error_and_exit "Failed creating dataset: $dataset"
  log INFO "Created $dataset"
}

create_tree(){
  local full="$1"
  IFS='/' read -r -a parts <<< "$full"
  local pool="${parts[0]}"
  pool_exists "$pool" || { log WARNING "Pool does not exist: $pool"; return; }
  local cur="$pool"
  for ((i=1;i<${#parts[@]};i++)); do
    cur+="/${parts[$i]}"
    if dataset_exists "$cur"; then
      log INFO "Dataset exists: $cur"
    else
      create_dataset "$cur"
    fi
  done
}

main(){
  parse_arguments "$@"
  validate
  while IFS= read -r line || [[ -n "$line" ]]; do
    dataset=$(normalize "$line")
    [[ -z "$dataset" ]] && continue
    create_tree "$dataset"
  done < "$DATASET_FILE"
  log INFO "Done."
}

main "$@"
