#!/usr/bin/env bash

# update-truenas-app-metadata.sh
#
# Description:
#   A utility for TrueNAS SCALE that updates application metadata by recursively 
#   merging a source YAML file into an existing target metadata file.
#
# How it works:
#   1. Resolves local standalone yq executable from SCRIPT_DIR/yq.
#   2. Determines application name from --name or source .metadata.name.
#   3. Resolves target:
#      /mnt/.ix-apps/app_configs/<app-name>/metadata.yaml
#   4. Creates merged output in a temporary file using recursive merge:
#      target * source
#   5. Optionally overrides:
#      - .human_version
#      - .metadata.app_version
#   6. In normal mode, creates timestamped backup and asks for confirmation.
#   7. Saves merged result only after explicit user confirmation.
#
# Dependency:
#   This script requires Mike Farah yq (Go implementation) as a standalone
#   binary named "yq" placed in the same directory as this script.
#   System-installed yq is not used.
#
# Here is the link to Mike Farah yq repository:
#   https://github.com/mikefarah/yq
#
# Download and make yq executable:
#   cd "$(dirname "$0")"
#   curl -L -o yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
#   chmod +x yq
#
# Expected path:
#   ./yq
#
# Usage:
#   ./update-truenas-app-metadata.sh -f <source-yaml> [options]
#
# Arguments:
#   -h, --help
#       Show help and exit with code 0. If provided, all other arguments are
#       ignored.
#   -f, --file <path>
#       Source YAML metadata file used for merge. Required unless help is
#       requested.
#   -n, --name <app-name>
#       Optional application name override. If omitted, app name is read from
#       source metadata.name.
#   -v, --version <value>
#       Optional version override applied after merge to:
#       - human_version
#       - metadata.app_version
#   -d, --dry-run
#       Execute full merge and preview flow without saving target file and
#       without confirmation prompt.
#
# Exit codes:
#   0 = success
#   1 = error

set -Eeuo pipefail

# Color palette for terminal output.
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

# Runtime state.
SCRIPT_DIR=''
YQ_BIN=''
SOURCE_FILE=''
APP_NAME=''
VERSION_OVERRIDE=''
DRY_RUN=false
TARGET_FILE=''
BACKUP_FILE=''
MERGED_TEMP_FILE=''

error() {
	# Print a readable error and exit with a general failure status.
	printf '%bERROR:%b %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$1" >&2
	exit 1
}

warn() {
	# Print warning-level information.
	printf '%bWARNING:%b %s\n' "${COLOR_YELLOW}" "${COLOR_RESET}" "$1"
}

info() {
	# Print informational output.
	printf '%bINFO:%b %s\n' "${COLOR_CYAN}" "${COLOR_RESET}" "$1"
}

success() {
	# Print success output.
	printf '%b%s%b\n' "${COLOR_GREEN}" "$1" "${COLOR_RESET}"
}

cleanup() {
	# Always remove temporary files, including on interruption or script errors.
	if [[ -n "${MERGED_TEMP_FILE}" && -f "${MERGED_TEMP_FILE}" ]]; then
		rm -f -- "${MERGED_TEMP_FILE}"
	fi
}

print_help() {
	cat <<'EOF'
Usage:
	update-truenas-app-metadata.sh -f <source-yaml> [options]

Description:
	Recursively merges a source metadata YAML into:
	/mnt/.ix-apps/app_configs/<app-name>/metadata.yaml

Options:
	-h, --help              Show this help and exit.
	-f, --file <path>       Source YAML file to merge (required unless --help is used).
	-n, --name <app-name>   Override application name. If omitted, uses source metadata.name.
	-v, --version <value>   Override merged human_version and metadata.app_version.
	-d, --dry-run           Perform merge and preview output without saving.

Examples:
	./update-truenas-app-metadata.sh -f ./metadata.yaml
	./update-truenas-app-metadata.sh -f ./metadata.yaml -n immich
	./update-truenas-app-metadata.sh -f ./metadata.yaml -v v4.130.0
	./update-truenas-app-metadata.sh -f ./metadata.yaml -d
EOF
}

parse_arguments() {
	# Parse CLI arguments and map them to runtime state.
	while (($# > 0)); do
		case "$1" in
			-f|--file)
				[[ $# -ge 2 ]] || error 'Missing value for --file.'
				SOURCE_FILE="$2"
				shift 2
				;;
			-n|--name)
				[[ $# -ge 2 ]] || error 'Missing value for --name.'
				APP_NAME="$2"
				shift 2
				;;
			-v|--version)
				[[ $# -ge 2 ]] || error 'Missing value for --version.'
				VERSION_OVERRIDE="$2"
				shift 2
				;;
			-d|--dry-run)
				DRY_RUN=true
				shift
				;;
			-h|--help)
				# Help is handled before argument parsing, but keep this branch for completeness.
				print_help
				exit 0
				;;
			*)
				error "Unknown argument: $1"
				;;
		esac
	done
}

validate_arguments() {
	# Validate user input and source file accessibility.
	[[ -n "${SOURCE_FILE}" ]] || error 'Source file is required. Use -f or --file.'
	[[ -f "${SOURCE_FILE}" ]] || error 'Source file does not exist.'
	[[ -r "${SOURCE_FILE}" ]] || error 'Source file is not readable.'
}

find_yq() {
	# Resolve local standalone yq binary from the script directory.
	local local_yq

	local_yq="${SCRIPT_DIR}/yq"
	[[ -f "${local_yq}" ]] || error 'Cannot locate yq executable.'
	[[ -x "${local_yq}" ]] || error 'yq exists but is not executable.'

	YQ_BIN="${local_yq}"
}

resolve_app_name() {
	# Resolve app name from CLI override or source metadata.name.
	if [[ -n "${APP_NAME}" ]]; then
		return
	fi

	APP_NAME="$("${YQ_BIN}" eval -r '.metadata.name // ""' "${SOURCE_FILE}")"
	APP_NAME="${APP_NAME//$'\r'/}"

	[[ -n "${APP_NAME}" ]] || error 'Unable to determine application name.'
}

resolve_target_file() {
	# Build and validate target metadata path for the selected application.
	TARGET_FILE="/mnt/.ix-apps/app_configs/${APP_NAME}/metadata.yaml"

	[[ -f "${TARGET_FILE}" ]] || error 'Target metadata file does not exist.'
	[[ -r "${TARGET_FILE}" ]] || error 'Target metadata file is not readable.'

	if [[ "${DRY_RUN}" == false && ! -w "${TARGET_FILE}" ]]; then
		error 'Target metadata file is not writable.'
	fi
}

create_backup() {
	# Create timestamped backup of the target metadata before any write operation.
	local timestamp

	timestamp="$(date '+%Y%m%d-%H%M%S')"
	BACKUP_FILE="${TARGET_FILE}.${timestamp}.bak"

	if [[ -e "${BACKUP_FILE}" ]]; then
		error 'Backup file already exists for the current timestamp. Please retry.'
	fi

	cp -- "${TARGET_FILE}" "${BACKUP_FILE}" || error 'Failed to create backup file.'
}

merge_metadata() {
	# Merge complete YAML documents recursively using target * source semantics.
	MERGED_TEMP_FILE="$(mktemp)"

	"${YQ_BIN}" eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
		"${TARGET_FILE}" "${SOURCE_FILE}" > "${MERGED_TEMP_FILE}" || error 'Failed to merge metadata files.'
}

override_version() {
	# Apply version overrides after merge, regardless of original key presence.
	[[ -n "${VERSION_OVERRIDE}" ]] || return

	VERSION_OVERRIDE="${VERSION_OVERRIDE}" \
		"${YQ_BIN}" eval --inplace '.human_version = strenv(VERSION_OVERRIDE) | .metadata.app_version = strenv(VERSION_OVERRIDE)' \
		"${MERGED_TEMP_FILE}" || error 'Failed to override version fields.'
}

print_summary() {
	# Print a concise execution summary before displaying merged YAML.
	local mode

	if [[ "${DRY_RUN}" == true ]]; then
		mode='DRY RUN'
	else
		mode='NORMAL'
	fi

	printf '%s\n' '--------------------------------------------------'
	printf '%bSummary%b\n' "${COLOR_CYAN}" "${COLOR_RESET}"
	printf '%s\n\n' '--------------------------------------------------'
	printf '%-12s %s\n\n' 'Application :' "${APP_NAME}"
	printf '%-12s %s\n\n' 'Source      :' "${SOURCE_FILE}"
	printf '%-12s %s\n\n' 'Target      :' "${TARGET_FILE}"
	if [[ "${DRY_RUN}" == true ]]; then
		printf '%-12s %s\n\n' 'Backup      :' 'N/A (dry run)'
	else
		printf '%-12s %s\n\n' 'Backup      :' "${BACKUP_FILE}"
	fi
	printf '%-12s %s\n' 'Mode        :' "${mode}"
}

print_merged_yaml() {
	# Print full merged YAML preview with no truncation.
	printf '\n%s\n' '--------------------------------------------------'
	printf '%bMerged metadata%b\n' "${COLOR_CYAN}" "${COLOR_RESET}"
	printf '%s\n' '--------------------------------------------------'
	cat -- "${MERGED_TEMP_FILE}"
}

confirm_save() {
	# Ask for explicit confirmation using an interactive arrow-key menu.
	local selected key rest
	selected=1 # 0 = Yes, 1 = No (default)

	if [[ ! -t 0 || ! -t 1 ]]; then
		warn 'Interactive confirmation is unavailable. Defaulting to No.'
		return 1
	fi

	printf '\nSave these changes?\n'

	while true; do
		if [[ "${selected}" -eq 0 ]]; then
			printf '> Yes\n'
			printf '  No\n'
		else
			printf '  Yes\n'
			printf '> No\n'
		fi

		IFS= read -rsn1 key || return 1

		if [[ "${key}" == $'\x1b' ]]; then
			IFS= read -rsn2 rest || true
			case "${rest}" in
				'[A')
					if [[ "${selected}" -eq 0 ]]; then
						selected=1
					else
						selected=0
					fi
					;;
				'[B')
					if [[ "${selected}" -eq 0 ]]; then
						selected=1
					else
						selected=0
					fi
					;;
			esac
		elif [[ -z "${key}" ]]; then
			break
		elif [[ "${key}" == 'y' || "${key}" == 'Y' ]]; then
			selected=0
			break
		elif [[ "${key}" == 'n' || "${key}" == 'N' ]]; then
			selected=1
			break
		fi

		# Redraw both menu lines in place after handling keyboard input.
		printf '\033[2A'
		printf '\r\033[2K'
		printf '\033[1B\r\033[2K'
		printf '\033[1A\r'
	done

	if [[ "${selected}" -eq 0 ]]; then
		return 0
	fi

	return 1
}

save_file() {
	# Overwrite the target metadata with the merged temporary file.
	cp -- "${MERGED_TEMP_FILE}" "${TARGET_FILE}" || error 'Failed to write merged metadata to target file.'
}

main() {
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	trap cleanup EXIT INT TERM

	# Help has absolute priority and ignores all other arguments.
	for arg in "$@"; do
		if [[ "${arg}" == '-h' || "${arg}" == '--help' ]]; then
			print_help
			exit 0
		fi
	done

	parse_arguments "$@"
	validate_arguments
	find_yq
	resolve_app_name
	resolve_target_file
	merge_metadata
	override_version

	if [[ "${DRY_RUN}" == false ]]; then
		create_backup
	fi

	print_summary
	print_merged_yaml

	if [[ "${DRY_RUN}" == true ]]; then
		success 'Dry run complete. No files were modified.'
		exit 0
	fi

	if ! confirm_save; then
		warn 'Operation cancelled.'
		exit 0
	fi

	save_file
	success 'Metadata successfully updated.'
}

main "$@"
