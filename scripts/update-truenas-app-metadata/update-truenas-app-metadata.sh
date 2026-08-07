#!/usr/bin/env bash

# update-truenas-app-metadata.sh
#
# Description:
#   A utility for TrueNAS SCALE that updates application metadata by recursively 
#   merging a source YAML file into an existing target metadata file.
#
# How it works:
#   1. Resolves local standalone yq executable from SCRIPT_DIR/yq.
#      If missing, the script can interactively download yq to SCRIPT_DIR.
#   2. Loads variables from optional .env files in order (later files override earlier).
#   3. Replaces ${VAR} placeholders in the source file using loaded variables.
#   4. Determines application name from --name or source .metadata.name.
#   5. Resolves target file:
#      - From --target if provided (must exist, must have .yaml or .yml extension).
#      - Otherwise: /mnt/.ix-apps/app_configs/<app-name>/metadata.yaml
#   6. Creates merged output in a temporary file using recursive merge:
#      target * source
#   7. Optionally overrides after merge:
#      - .human_version
#      - .metadata.app_version
#   8. In normal mode, creates timestamped backup and asks for confirmation.
#   9. Saves merged result only after explicit user confirmation.
#
# Dependency:
#   This script requires Mike Farah yq (Go implementation) as a standalone
#   binary named "yq" placed in the same directory as this script.
#   System-installed yq is not used. If yq is missing, the script can download
#   it automatically after interactive confirmation.
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
#   ./update-truenas-app-metadata.sh -s <source-yaml> [options]
#
# Arguments:
#   -h, --help
#       Show help and exit with code 0. If provided, all other arguments are
#       ignored.
#   -e, --env-files <paths>
#       Optional comma-separated list of .env files loaded in order.
#       Later files override variables from earlier files.
#   -s, --source <path>
#       Source YAML metadata file used for merge. Required unless help is
#       requested.
#   -n, --name <app-name>
#       Optional application name override. If omitted, app name is read from
#       source metadata.name.
#   -v, --version <value>
#       Optional version override applied after merge to:
#       - human_version
#       - metadata.app_version
#   -t, --target <path>
#       Optional path to the target metadata file to overwrite.
#       If omitted, the target is resolved as:
#       /mnt/.ix-apps/app_configs/<app-name>/metadata.yaml
#       If provided, the file must exist and have a .yaml or .yml extension.
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
YQ_DOWNLOAD_URL='https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64'

# Runtime state.
SCRIPT_DIR=''
YQ_BIN=''
SOURCE_FILE=''
ENV_FILES_ARG=''
APP_NAME=''
VERSION_OVERRIDE=''
DRY_RUN=false
TARGET_FILE=''
BACKUP_FILE=''
MERGED_TEMP_FILE=''
SOURCE_RENDERED_FILE=''
TARGET_ARG=''

declare -a ENV_FILE_LIST=()
declare -A ENV_VARS=()
declare -A USER_NAME=(
	[0]='root'
	[568]='apps'
	[950]='truenas_admin'
)
declare -A USER_GROUP_NAME=(
	[0]='root'
	[568]='apps'
	[950]='truenas_admin'
)

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

select_yes_no() {
	# Render an interactive Yes/No chooser controlled by arrow keys and Enter.
	local selected key rest
	selected=1 # 0 = Yes, 1 = No (default)

	if [[ ! -t 0 || ! -t 1 ]]; then
		return 1
	fi

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
				'[A'|'[B')
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

download_local_yq() {
	# Download yq into script directory and make it executable.
	command -v curl >/dev/null 2>&1 || error 'curl is required to download yq automatically.'

	(
		cd -- "${SCRIPT_DIR}" || exit 1
		curl -L -o yq "${YQ_DOWNLOAD_URL}" || exit 1
		chmod +x yq || exit 1
	) || error 'Failed to download and prepare yq binary.'

	success "yq downloaded successfully to ${SCRIPT_DIR}/yq"
}

offer_yq_download() {
	# Offer interactive yq download when local binary is missing.
	if [[ ! -t 0 || ! -t 1 ]]; then
		error "Cannot locate yq executable. Download it from ${YQ_DOWNLOAD_URL} and place it in ${SCRIPT_DIR}/yq"
	fi

	printf '%bWARNING:%b Cannot locate yq executable.\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
	printf 'Download yq binary now?\n'
	printf 'Downloaded yq will be saved in %s\n' "${SCRIPT_DIR}"

	if select_yes_no; then
		download_local_yq
	else
		error 'Cannot locate yq executable.'
	fi
}

cleanup() {
	# Always remove temporary files, including on interruption or script errors.
	if [[ -n "${MERGED_TEMP_FILE}" && -f "${MERGED_TEMP_FILE}" ]]; then
		rm -f -- "${MERGED_TEMP_FILE}"
	fi

	if [[ -n "${SOURCE_RENDERED_FILE}" && -f "${SOURCE_RENDERED_FILE}" ]]; then
		rm -f -- "${SOURCE_RENDERED_FILE}"
	fi
}

print_help() {
	cat <<'EOF'
Usage:
	update-truenas-app-metadata.sh -s <source-yaml> [options]

Description:
	Recursively merges a source metadata YAML into:
	/mnt/.ix-apps/app_configs/<app-name>/metadata.yaml

Options:
	-h, --help              Show this help and exit.
	-e, --env-files <paths> Comma-separated .env files. Later files override earlier ones.
	-s, --source <path>     Source YAML file to merge (required unless --help is used).
	-n, --name <app-name>   Override application name. If omitted, uses source metadata.name.
	-t, --target <path>     Target metadata file to overwrite. Must exist and have .yaml or .yml
	                        extension. If omitted, resolved from app name.
	-v, --version <value>   Override merged human_version and metadata.app_version.
	-d, --dry-run           Perform merge and preview output without saving.

Examples:
	./update-truenas-app-metadata.sh -s ./metadata.yaml
	./update-truenas-app-metadata.sh -s ./metadata.yaml -e ./compose/shared/.env,./compose/code-server/.env
	./update-truenas-app-metadata.sh -s ./metadata.yaml -n immich
	./update-truenas-app-metadata.sh -s ./metadata.yaml -v v4.130.0
	./update-truenas-app-metadata.sh -s ./metadata.yaml -d
EOF
}

parse_arguments() {
	# Parse CLI arguments and map them to runtime state.
	while (($# > 0)); do
		case "$1" in
			-e|--env-files)
				[[ $# -ge 2 ]] || error 'Missing value for --env-files.'
				if [[ -z "${ENV_FILES_ARG}" ]]; then
					ENV_FILES_ARG="$2"
				else
					ENV_FILES_ARG+=",$2"
				fi
				shift 2
				;;
			-s|--source)
				[[ $# -ge 2 ]] || error 'Missing value for --source.'
				SOURCE_FILE="$2"
				shift 2
				;;
			-n|--name)
				[[ $# -ge 2 ]] || error 'Missing value for --name.'
				APP_NAME="$2"
				shift 2
				;;
			-t|--target)
				[[ $# -ge 2 ]] || error 'Missing value for --target.'
				TARGET_ARG="$2"
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
	[[ -n "${SOURCE_FILE}" ]] || error 'Source file is required. Use -s or --source.'
	[[ -f "${SOURCE_FILE}" ]] || error 'Source file does not exist.'
	[[ -r "${SOURCE_FILE}" ]] || error 'Source file is not readable.'
}

trim_whitespace() {
	# Trim leading and trailing whitespace from the provided string.
	local value

	value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "${value}"
}

parse_env_file_list() {
	# Parse comma-separated env file paths while preserving input order.
	local raw_path trimmed_path

	[[ -n "${ENV_FILES_ARG}" ]] || return

	IFS=',' read -r -a ENV_FILE_LIST <<< "${ENV_FILES_ARG}"

	for i in "${!ENV_FILE_LIST[@]}"; do
		raw_path="${ENV_FILE_LIST[$i]}"
		trimmed_path="$(trim_whitespace "${raw_path}")"
		[[ -n "${trimmed_path}" ]] || error 'The --env-files list contains an empty path.'
		ENV_FILE_LIST[$i]="${trimmed_path}"
		[[ -f "${ENV_FILE_LIST[$i]}" ]] || error "Env file does not exist: ${ENV_FILE_LIST[$i]}"
		[[ -r "${ENV_FILE_LIST[$i]}" ]] || error "Env file is not readable: ${ENV_FILE_LIST[$i]}"
	done
}

load_env_files() {
	# Load variables from .env files in order; later files override previous values.
	local env_file line key value

	for env_file in "${ENV_FILE_LIST[@]}"; do
		while IFS= read -r line || [[ -n "${line}" ]]; do
			line="${line%$'\r'}"

			[[ "${line}" =~ ^[[:space:]]*$ ]] && continue
			[[ "${line}" =~ ^[[:space:]]*# ]] && continue

			if [[ "${line}" =~ ^[[:space:]]*export[[:space:]]+(.+)$ ]]; then
				line="${BASH_REMATCH[1]}"
			fi

			[[ "${line}" == *'='* ]] || error "Invalid line in env file ${env_file}: ${line}"

			key="${line%%=*}"
			value="${line#*=}"
			key="$(trim_whitespace "${key}")"

			[[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || error "Invalid variable name '${key}' in env file ${env_file}."

			if [[ "${value}" =~ ^".*"$ ]] || [[ "${value}" =~ ^'.*'$ ]]; then
				value="${value:1:${#value}-2}"
			fi

			ENV_VARS["${key}"]="${value}"
		done < "${env_file}"
	done
}

resolve_variable_value() {
	# Resolve interpolation variable value using loaded env vars and special fallbacks.
	local variable_name lookup_id

	variable_name="$1"

	if [[ -v ENV_VARS["${variable_name}"] ]]; then
		printf '%s' "${ENV_VARS["${variable_name}"]}"
		return
	fi

	case "${variable_name}" in
		PUID_NAME)
			if [[ -v ENV_VARS['PUID'] ]]; then
				lookup_id="${ENV_VARS['PUID']}"
				if [[ -v USER_NAME["${lookup_id}"] ]]; then
					printf '%s' "${USER_NAME["${lookup_id}"]}"
				else
					printf '%s' 'unknown'
				fi
			else
				printf '%s' 'unknown'
			fi
			return
			;;
		PGID_NAME)
			if [[ -v ENV_VARS['PGID'] ]]; then
				lookup_id="${ENV_VARS['PGID']}"
				if [[ -v USER_GROUP_NAME["${lookup_id}"] ]]; then
					printf '%s' "${USER_GROUP_NAME["${lookup_id}"]}"
				else
					printf '%s' 'unknown'
				fi
			else
				printf '%s' 'unknown'
			fi
			return
			;;
		esac

	error "In the source metadata file, the ${variable_name} variable is used but it is not defined"
}

render_source_template() {
	# Replace ${VAR} placeholders in the source file using resolved variable values.
	local source_content variable_name variable_value
	local -a referenced_variables=()

	SOURCE_RENDERED_FILE="$(mktemp)"
	source_content="$(cat -- "${SOURCE_FILE}")"

	mapfile -t referenced_variables < <(
		grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${SOURCE_FILE}" \
			| sed -E 's/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/\1/' \
			| sort -u || true
	)

	for variable_name in "${referenced_variables[@]}"; do
		variable_value="$(resolve_variable_value "${variable_name}")"
		source_content="${source_content//\$\{${variable_name}\}/${variable_value}}"
	done

	printf '%s' "${source_content}" > "${SOURCE_RENDERED_FILE}"
}

find_yq() {
	# Resolve local standalone yq binary from the script directory.
	local local_yq

	local_yq="${SCRIPT_DIR}/yq"
	if [[ ! -f "${local_yq}" ]]; then
		offer_yq_download
	fi

	[[ -f "${local_yq}" ]] || error 'Cannot locate yq executable.'
	[[ -x "${local_yq}" ]] || error 'yq exists but is not executable.'

	YQ_BIN="${local_yq}"
}

resolve_app_name() {
	# Resolve app name from CLI override or source metadata.name.
	if [[ -n "${APP_NAME}" ]]; then
		return
	fi

	APP_NAME="$("${YQ_BIN}" eval -r '.metadata.name // ""' "${SOURCE_RENDERED_FILE}")"
	APP_NAME="${APP_NAME//$'\r'/}"

	[[ -n "${APP_NAME}" ]] || error 'Unable to determine application name.'
}

resolve_target_file() {
	# Build target path from explicit argument or from the app name convention.
	if [[ -n "${TARGET_ARG}" ]]; then
		TARGET_FILE="${TARGET_ARG}"

		# Validate file extension before anything else.
		case "${TARGET_FILE}" in
			*.yaml|*.yml) ;;
			*) error "Target file must have a .yaml or .yml extension: ${TARGET_FILE}" ;;
		esac
	else
		TARGET_FILE="/mnt/.ix-apps/app_configs/${APP_NAME}/metadata.yaml"
	fi

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
		"${TARGET_FILE}" "${SOURCE_RENDERED_FILE}" > "${MERGED_TEMP_FILE}" || error 'Failed to merge metadata files.'
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
	if [[ ${#ENV_FILE_LIST[@]} -gt 0 ]]; then
		printf '%-12s %s\n\n' 'Env files   :' "${ENV_FILE_LIST[*]}"
	fi
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
	if [[ ! -t 0 || ! -t 1 ]]; then
		warn 'Interactive confirmation is unavailable. Defaulting to No.'
		return 1
	fi

	printf '\nSave these changes?\n'
	select_yes_no
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
	parse_env_file_list
	load_env_files
	render_source_template
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
