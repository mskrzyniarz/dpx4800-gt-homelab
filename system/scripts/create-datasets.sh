#!/usr/bin/env bash
# ==============================================================================
# create-datasets.sh
#
# Creates ZFS datasets on TrueNAS SCALE 25.10.4 using the TrueNAS middleware
# API (midclt) exclusively. No direct zfs(8) commands are used for dataset
# management.
#
# The script reads a list of desired dataset paths from a file, expands every
# path into all its intermediate ancestor segments (so parents are always
# created before children), deduplicates and sorts the resulting list, then
# processes each entry exactly once.
#
# Features:
#   - Reads dataset paths from a text file  (-d / --datasets)
#   - Applies a TrueNAS dataset preset       (-p / --preset, default: Apps)
#   - Dry-run mode                           (--dry-run)
#   - Regular-directory to dataset conversion with rollback on failure
#   - Pool existence checked once via midclt; result is cached
#   - Skip-propagation: children of skipped/missing-pool paths are skipped
#   - Detailed per-dataset status tracking and a final summary report
#
# Important:
#   - Existing datasets are left completely untouched. The script only creates
#     datasets that do not yet exist. It never modifies, reconfigures, or
#     changes the preset of a dataset that is already present in TrueNAS.
#
# Usage:
#   sudo ./create-datasets.sh -d /path/to/datasets.txt
#   sudo ./create-datasets.sh -d /path/to/datasets.txt -p Apps --dry-run
#
# Requirements: bash 5.x, midclt, jq, mktemp, mv, find
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

# ==============================================================================
# CONSTANTS
# ==============================================================================

readonly SCRIPT_NAME="$(basename "$0")"

# Status labels stored in PATH_STATUS for each processed path
readonly STATUS_CREATED="CREATED"
readonly STATUS_EXISTS="EXISTS"
readonly STATUS_CONVERTED="CONVERTED"
readonly STATUS_SKIPPED="SKIPPED"
readonly STATUS_POOL_MISSING="POOL_MISSING"
readonly STATUS_ERROR="ERROR"

# Prefix for the temporary directory created during directory-to-dataset
# conversion. The suffix (XXXXXX) is appended by mktemp.
readonly TMP_DIR_PREFIX=".tmp-dataset-convert-"

# Tools that must be present before the script does anything else
readonly REQUIRED_TOOLS=("midclt" "jq" "mktemp" "mv" "find")

# ==============================================================================
# GLOBALS (mutable script state)
# ==============================================================================

DATASETS_FILE=""   # Path to the dataset list file
PRESET="Apps"      # TrueNAS share_type preset for new datasets
DRY_RUN=0          # 1 = dry-run mode (no modifications)

# Populated once by load_existing_pools(); never queried again.
# Keys: pool name; value: 1 (present).
declare -A EXISTING_POOLS=()

# Populated by load_dataset_file(); consumed by build_execution_plan().
declare -a LOADED_DATASETS=()

# Final, sorted, deduplicated list of all dataset segments to process.
# Built by build_execution_plan().
declare -a EXECUTION_PLAN=()

# Maps every processed path to its final status string (STATUS_* constants).
declare -A PATH_STATUS=()

# ==============================================================================
# LOGGING
# ==============================================================================

log_info() {
    printf '[INFO]    %s\n' "$*"
}

log_warning() {
    printf '[WARNING] %s\n' "$*" >&2
}

log_error() {
    printf '[ERROR]   %s\n' "$*" >&2
}

# ==============================================================================
# USAGE / HELP
# ==============================================================================

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME -d <datasets_file> [-p <preset>] [--dry-run] [-h]

Creates ZFS datasets on TrueNAS SCALE using the middleware API (midclt).

Required:
  -d, --datasets <file>   Path to a text file containing dataset paths
                          (one per line).

Optional:
  -p, --preset <preset>   Dataset preset applied when creating new datasets.
                          Default: Apps
  --dry-run               Show what would happen without making any changes.
  -h, --help              Display this help message and exit.

Dataset file format:
  - One dataset path per line  (e.g.  tank/apps/config)
  - Leading/trailing whitespace is stripped
  - Leading and trailing slashes are removed
  - Empty lines and duplicates are ignored
  - Paths must contain at least  pool/dataset  (e.g.  tank/apps)
  - Case is preserved

Examples:
  sudo $SCRIPT_NAME -d datasets.txt
  sudo $SCRIPT_NAME -d datasets.txt -p Apps --dry-run
EOF
}

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================

parse_arguments() {
    # Show help when invoked without any arguments
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--datasets)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option '$1' requires an argument."
                    exit 1
                fi
                DATASETS_FILE="$2"
                shift 2
                ;;
            -p|--preset)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option '$1' requires an argument."
                    exit 1
                fi
                PRESET="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                log_error "Unknown option: '$1'"
                usage
                exit 1
                ;;
            *)
                log_error "Unexpected argument: '$1'"
                usage
                exit 1
                ;;
        esac
    done

    # Validate required argument
    if [[ -z "$DATASETS_FILE" ]]; then
        log_error "Option '-d / --datasets' is required."
        usage
        exit 1
    fi

    if [[ ! -f "$DATASETS_FILE" ]]; then
        log_error "Dataset file not found: '$DATASETS_FILE'"
        exit 1
    fi
}

# ==============================================================================
# ENVIRONMENT VALIDATION
# ==============================================================================

# Confirm that every required tool is available in PATH.
# Exits immediately if any tool is missing.
validate_environment() {
    log_info "Validating environment..."

    local missing=0
    local tool

    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "Required tool not found: '$tool'"
            missing=1
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        log_error "One or more required tools are missing. Cannot continue."
        exit 1
    fi

    log_info "All required tools are available."
}

# ==============================================================================
# POOL LOADING
# ==============================================================================

# Query the TrueNAS middleware for all existing pools exactly once and
# populate the global EXISTING_POOLS associative array.
load_existing_pools() {
    log_info "Loading existing pools via middleware..."

    local pool_json
    if ! pool_json="$(midclt call pool.query 2>&1)"; then
        log_error "Failed to query pools: $pool_json"
        exit 1
    fi

    local pool_name
    while IFS= read -r pool_name; do
        [[ -z "$pool_name" ]] && continue
        EXISTING_POOLS["$pool_name"]=1
    done < <(printf '%s' "$pool_json" | jq -r '.[].name')

    if [[ "${#EXISTING_POOLS[@]}" -eq 0 ]]; then
        log_warning "No pools found on this system."
    else
        local pool_list
        pool_list="$(printf '%s, ' "${!EXISTING_POOLS[@]}")"
        pool_list="${pool_list%, }"   # strip trailing comma+space
        log_info "Found ${#EXISTING_POOLS[@]} pool(s): $pool_list"
    fi
}

# ==============================================================================
# PATH NORMALIZATION AND VALIDATION
# ==============================================================================

# Normalize a raw input string:
#   1. Trim leading and trailing whitespace (spaces, tabs, carriage returns)
#   2. Remove every leading '/'
#   3. Remove every trailing '/'
#
# Carriage returns (\r) are explicitly trimmed so that dataset files saved
# with Windows line endings (CRLF) are handled correctly. Without this, a
# blank CRLF line would normalize to "\r" (non-empty), fail path validation,
# and produce a spurious "Invalid path" warning.
#
# Outputs the normalized string to stdout.
# Outputs an empty string if the input collapses to nothing.
normalize_dataset_path() {
    local raw="$1"
    local trimmed="$raw"

    # ---- Trim leading whitespace (spaces, tabs, carriage returns) -----------
    while [[ "${trimmed:0:1}" == ' '    || \
             "${trimmed:0:1}" == $'\t'  || \
             "${trimmed:0:1}" == $'\r' ]]; do
        trimmed="${trimmed:1}"
    done

    # ---- Trim trailing whitespace (spaces, tabs, carriage returns) ----------
    while [[ "${#trimmed}" -gt 0 ]] && \
          [[ "${trimmed: -1}" == ' '    || \
             "${trimmed: -1}" == $'\t'  || \
             "${trimmed: -1}" == $'\r' ]]; do
        trimmed="${trimmed:0:${#trimmed}-1}"
    done

    # ---- Remove every leading slash -----------------------------------------
    while [[ "$trimmed" == /* ]]; do
        trimmed="${trimmed:1}"
    done

    # ---- Remove every trailing slash ----------------------------------------
    while [[ "$trimmed" == */ ]]; do
        trimmed="${trimmed:0:${#trimmed}-1}"
    done

    printf '%s' "$trimmed"
}

# Validate that a normalized dataset path has at least the form pool/dataset.
# A valid path must:
#   - Be non-empty
#   - Contain at least one '/' (i.e., pool_name/something)
#   - Have a non-empty pool name and non-empty remainder
#
# Returns 0 if valid, 1 if invalid.
validate_dataset_path() {
    local path="$1"

    # Must be non-empty and contain at least one slash
    if [[ -z "$path" || "$path" != */* ]]; then
        return 1
    fi

    local pool="${path%%/*}"
    local rest="${path#*/}"

    # Both the pool part and the remainder must be non-empty
    if [[ -z "$pool" || -z "$rest" ]]; then
        return 1
    fi

    return 0
}

# ==============================================================================
# DATASET FILE LOADING
# ==============================================================================

# Read the dataset file line by line.
# Each line is normalized, validated, and deduplicated.
# Valid results are stored in the global LOADED_DATASETS array.
load_dataset_file() {
    log_info "Loading dataset file: '$DATASETS_FILE'"

    # Associative array for O(1) deduplication
    declare -A seen_paths=()
    local line_number=0
    local line normalized

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$(( line_number + 1 ))

        normalized="$(normalize_dataset_path "$line")"

        # Skip lines that are empty after normalization
        [[ -z "$normalized" ]] && continue

        # Validate structure
        if ! validate_dataset_path "$normalized"; then
            log_warning "Line $line_number: Invalid path (needs at least pool/dataset): '$normalized'"
            continue
        fi

        # Deduplicate
        if [[ -n "${seen_paths["$normalized"]+_}" ]]; then
            log_info "Line $line_number: Duplicate ignored: '$normalized'"
            continue
        fi

        seen_paths["$normalized"]=1
        LOADED_DATASETS+=("$normalized")

    done < "$DATASETS_FILE"

    log_info "Loaded ${#LOADED_DATASETS[@]} unique valid dataset path(s) from file."
}

# ==============================================================================
# EXECUTION PLAN
# ==============================================================================

# Expand every dataset path in LOADED_DATASETS into all its intermediate
# ancestor segments (e.g. tank/apps/config/homepage → tank/apps, tank/apps/config,
# tank/apps/config/homepage), deduplicate, sort alphabetically, and store the
# result in the global EXECUTION_PLAN array.
#
# This ensures that parent datasets are always processed before their children
# and that each path appears exactly once.
build_execution_plan() {
    log_info "Building execution plan..."

    # Use an associative array to deduplicate during expansion
    declare -A segments_seen=()
    declare -a segments=()

    local dataset pool rest accumulated part
    local -a parts

    for dataset in "${LOADED_DATASETS[@]}"; do
        pool="${dataset%%/*}"
        rest="${dataset#*/}"

        # Walk down the path segment by segment, accumulating pool/seg1/seg2/…
        accumulated="$pool"
        IFS='/' read -ra parts <<< "$rest"

        for part in "${parts[@]}"; do
            accumulated="${accumulated}/${part}"

            # Guard: skip if this somehow collapsed to just a pool name
            [[ "$accumulated" != */* ]] && continue

            if [[ -z "${segments_seen["$accumulated"]+_}" ]]; then
                segments_seen["$accumulated"]=1
                segments+=("$accumulated")
            fi
        done
    done

    # Sort alphabetically and store in the global array
    if [[ "${#segments[@]}" -gt 0 ]]; then
        mapfile -t EXECUTION_PLAN < <(printf '%s\n' "${segments[@]}" | sort)
    fi

    log_info "Execution plan contains ${#EXECUTION_PLAN[@]} dataset segment(s)."

    if [[ "${#EXECUTION_PLAN[@]}" -gt 0 ]]; then
        log_info "Execution order:"
        local entry
        for entry in "${EXECUTION_PLAN[@]}"; do
            log_info "  $entry"
        done
    fi
}

# ==============================================================================
# SKIP LOGIC
# ==============================================================================

# Determine whether a dataset should be skipped because an ancestor path has
# been marked as SKIPPED or POOL_MISSING.
#
# Only paths that are strict children (current == stored + "/" + anything)
# are affected. The path itself is never compared to itself here because the
# execution plan is already unique.
#
# Returns 0 (true)  → the caller should skip this dataset.
# Returns 1 (false) → processing should proceed normally.
should_skip_processing() {
    local current_path="$1"
    local stored_path stored_status

    for stored_path in "${!PATH_STATUS[@]}"; do
        stored_status="${PATH_STATUS["$stored_path"]}"

        # Only SKIPPED and POOL_MISSING propagate downward
        if [[ "$stored_status" != "$STATUS_SKIPPED" && \
              "$stored_status" != "$STATUS_POOL_MISSING" ]]; then
            continue
        fi

        # Is current_path a child of stored_path?
        if [[ "$current_path" == "${stored_path}/"* ]]; then
            return 0   # yes → skip
        fi
    done

    return 1   # no matching ancestor → do not skip
}

# ==============================================================================
# MIDDLEWARE HELPERS
# ==============================================================================

# Check whether a dataset exists in TrueNAS via the middleware API.
#
# Returns 0 if the dataset exists, 1 if it does not (or on query error).
dataset_exists() {
    local dataset_name="$1"
    local result count

    if ! result="$(midclt call pool.dataset.query \
            "[[ \"id\", \"=\", \"${dataset_name}\" ]]" 2>/dev/null)"; then
        return 1
    fi

    count="$(printf '%s' "$result" | jq 'length')" || return 1
    [[ "$count" -gt 0 ]]
}

# Retrieve the mountpoint of an existing dataset via the middleware API.
# Outputs the mountpoint path to stdout.
# Returns 1 on error.
get_dataset_mountpoint() {
    local dataset_name="$1"
    local result

    if ! result="$(midclt call pool.dataset.query \
            "[[ \"id\", \"=\", \"${dataset_name}\" ]]" 2>/dev/null)"; then
        log_error "Failed to query mountpoint for dataset: '$dataset_name'"
        return 1
    fi

    printf '%s' "$result" | jq -r '.[0].mountpoint // empty'
}

# Create a dataset via the middleware API.
#
# In dry-run mode, only displays what would happen.
# Returns 0 on success, 1 on failure.
create_dataset() {
    local dataset_name="$1"
    local preset="$2"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '\n'
        log_info "Would create dataset:"
        printf '\n    %s\n\n' "$dataset_name"
        return 0
    fi

    log_info "Creating dataset '$dataset_name' with preset '$preset'..."

    local payload output
    payload="$(printf '{"name": "%s", "share_type": "%s"}' "$dataset_name" "$preset")"

    if ! output="$(midclt call pool.dataset.create "$payload" 2>&1)"; then
        log_error "Middleware error while creating '$dataset_name': $output"
        return 1
    fi

    log_info "Dataset created successfully: '$dataset_name'"
    return 0
}

# ==============================================================================
# FILESYSTEM HELPERS
# ==============================================================================

# Returns 0 if the given filesystem path exists (any type: directory, file,
# symlink, etc.), 1 otherwise.
directory_exists() {
    local path="$1"
    [[ -e "$path" ]]
}

# Returns 0 if the given directory contains no entries (is empty), 1 otherwise.
directory_is_empty() {
    local path="$1"
    local entry_count

    # -quit stops after the first result; wc -l is then 0 or 1
    entry_count="$(find "$path" -maxdepth 1 -mindepth 1 -print -quit 2>/dev/null \
                   | wc -l)"
    [[ "$entry_count" -eq 0 ]]
}

# ==============================================================================
# DIRECTORY CONVERSION (interactive)
# ==============================================================================

# Ask the user interactively whether a regular directory should be converted
# into a ZFS dataset.
#
# Displays a numbered select menu with options "Yes" and "No".
# Returns 0 if the user selects Yes, 1 if the user selects No.
ask_directory_conversion() {
    local dataset_name="$1"
    local fs_path="$2"
    local preset="$3"

    printf '\n'
    printf 'The selected path:\n\n'
    printf '    %s\n\n' "$fs_path"
    printf 'already exists.\n\n'
    printf 'This is not a ZFS dataset, but a regular directory.\n\n'

    if directory_is_empty "$fs_path"; then
        printf 'The directory is empty.\n\n'
    else
        printf 'The directory contains files.\n\n'
    fi

    printf "Do you want to convert this directory into a ZFS dataset using the '%s' preset?\n\n" \
        "$preset"

    # Use bash 'select' to display a numbered menu.
    # $reply holds the chosen option label ("Yes" or "No").
    local replace_dataset=0
    local reply

    select reply in "Yes" "No"; do
        case "$reply" in
            Yes | yes | y | Y | 1)
                replace_dataset=1
                break
                ;;
            No | no | n | N | 2)
                replace_dataset=0
                break
                ;;
            *)
                printf 'Invalid selection. Please choose 1 (Yes) or 2 (No).\n'
                ;;
        esac
    done

    printf '\n'
    [[ "$replace_dataset" -eq 1 ]]
}

# ==============================================================================
# DIRECTORY-TO-DATASET CONVERSION
# ==============================================================================

# Convert an existing regular directory to a ZFS dataset without copying data.
#
# Strategy (single filesystem, zero extra disk space):
#   1. Determine the parent dataset's mountpoint.
#   2. Create a temporary directory inside the parent mountpoint (mktemp).
#   3. mv the target directory into the temporary directory.
#      Because source and destination are on the same filesystem, the kernel
#      performs an atomic rename() — no data is copied.
#   4. Create the dataset at the original path via the middleware API.
#   5. mv all entries from the saved copy back into the new dataset mountpoint.
#   6. Remove the now-empty temporary directories.
#
# Rollback:
#   If step 4 (dataset creation) fails, the original directory is restored
#   from the temporary location. STATUS_ERROR is set; processing continues.
#
# Returns 0 on success, 1 on failure.
convert_directory_to_dataset() {
    local dataset_name="$1"
    local fs_path="$2"
    local preset="$3"

    local dir_basename
    dir_basename="$(basename "$fs_path")"

    # Determine the parent dataset name.
    # For  tank/apps/config  the parent is  tank/apps.
    # For  tank/apps          the parent is  tank  (the pool root dataset).
    local parent_dataset="${dataset_name%/*}"
    local parent_mountpoint

    # Pools are not regular datasets; their mountpoint is /mnt/<pool>.
    # For datasets deeper than one level the mountpoint is retrieved via API.
    if [[ "$parent_dataset" != */* ]]; then
        # Parent is the pool itself → its mountpoint is /mnt/<pool>
        parent_mountpoint="/mnt/${parent_dataset}"
    else
        parent_mountpoint="$(get_dataset_mountpoint "$parent_dataset")" || {
            log_error "Cannot determine mountpoint for parent '$parent_dataset'."
            return 1
        }
    fi

    if [[ -z "$parent_mountpoint" || "$parent_mountpoint" == "null" ]]; then
        log_error "Parent dataset '$parent_dataset' has no valid mountpoint."
        return 1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '\n'
        log_info "Would convert directory:"
        printf '\n    %s\n\n' "$fs_path"
        return 0
    fi

    # ---- Step 2: Create temporary directory inside parent mountpoint ---------
    local tmp_dir
    if ! tmp_dir="$(mktemp -d "${parent_mountpoint}/${TMP_DIR_PREFIX}XXXXXX")"; then
        log_error "Failed to create temporary directory in '$parent_mountpoint'."
        return 1
    fi

    # ---- Step 3: Move target directory to temporary location (atomic) --------
    log_info "Moving '$fs_path' → '${tmp_dir}/${dir_basename}' (atomic rename)..."

    if ! mv "$fs_path" "${tmp_dir}/${dir_basename}"; then
        log_error "Failed to move '$fs_path' to temporary location."
        rmdir "$tmp_dir" 2>/dev/null || true
        return 1
    fi

    # ---- Step 4: Create dataset (original path is now free) ------------------
    log_info "Creating dataset '$dataset_name'..."

    if ! create_dataset "$dataset_name" "$preset"; then
        # Dataset creation failed → restore original directory (rollback)
        log_error "Dataset creation failed. Attempting rollback..."

        if mv "${tmp_dir}/${dir_basename}" "$fs_path" 2>/dev/null; then
            log_info "Rollback successful: directory restored to '$fs_path'."
        else
            log_error "Rollback FAILED. Original directory is at: '${tmp_dir}/${dir_basename}'"
        fi

        rmdir "$tmp_dir" 2>/dev/null || true
        return 1
    fi

    # ---- Step 5: Move contents back into the new dataset mountpoint ----------
    log_info "Restoring directory contents into dataset '$dataset_name'..."

    local item restore_failed=0
    while IFS= read -r -d '' item; do
        if ! mv "$item" "${fs_path}/"; then
            log_error "Failed to move '${item}' back into dataset. Manual recovery needed."
            log_error "Remaining contents are at: '${tmp_dir}/${dir_basename}'"
            restore_failed=1
            break
        fi
    done < <(find "${tmp_dir}/${dir_basename}" -maxdepth 1 -mindepth 1 -print0 2>/dev/null)

    if [[ "$restore_failed" -eq 1 ]]; then
        return 1
    fi

    # ---- Step 6: Remove the now-empty temporary directories ------------------
    rmdir "${tmp_dir}/${dir_basename}" 2>/dev/null || true
    rmdir "$tmp_dir"                   2>/dev/null || true

    log_info "Successfully converted directory to dataset: '$dataset_name'"
    return 0
}

# ==============================================================================
# PER-DATASET PROCESSING
# ==============================================================================

# Process a single dataset entry from EXECUTION_PLAN.
# This function never exits the script on failure; it sets PATH_STATUS and
# returns 0 so that processing continues with the next entry.
process_dataset() {
    local dataset="$1"

    # ------------------------------------------------------------------
    # Step 1: Skip-propagation check
    # ------------------------------------------------------------------
    if should_skip_processing "$dataset"; then
        log_info "Skipping '$dataset' (ancestor is skipped or pool is missing)."
        PATH_STATUS["$dataset"]="$STATUS_SKIPPED"
        return 0
    fi

    # ------------------------------------------------------------------
    # Step 2: Extract pool name
    # ------------------------------------------------------------------
    local pool="${dataset%%/*}"

    # ------------------------------------------------------------------
    # Step 3: Pool existence check (cached — no API call)
    # ------------------------------------------------------------------
    if [[ -z "${EXISTING_POOLS["$pool"]+_}" ]]; then
        log_warning "Pool '$pool' does not exist. Skipping '$dataset' and its children."
        # Mark both the pool key and the dataset so children are skipped
        PATH_STATUS["$pool"]="$STATUS_POOL_MISSING"
        PATH_STATUS["$dataset"]="$STATUS_POOL_MISSING"
        return 0
    fi

    # ------------------------------------------------------------------
    # Step 4: Check whether the dataset already exists via middleware
    # ------------------------------------------------------------------
    if dataset_exists "$dataset"; then
        log_info "Dataset already exists: '$dataset'"
        PATH_STATUS["$dataset"]="$STATUS_EXISTS"
        return 0
    fi

    # ------------------------------------------------------------------
    # Step 5: Determine expected filesystem mountpoint
    # ------------------------------------------------------------------
    local fs_path="/mnt/${dataset}"

    # ------------------------------------------------------------------
    # Step 6: If the filesystem path does not exist → create dataset
    # ------------------------------------------------------------------
    if ! directory_exists "$fs_path"; then
        if create_dataset "$dataset" "$PRESET"; then
            PATH_STATUS["$dataset"]="$STATUS_CREATED"
        else
            PATH_STATUS["$dataset"]="$STATUS_ERROR"
        fi
        return 0
    fi

    # ------------------------------------------------------------------
    # Step 7: Filesystem path exists but is NOT a known dataset.
    #         It must be a regular directory → offer conversion.
    # ------------------------------------------------------------------

    # In dry-run mode there is no interactive prompt; just report intent.
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '\n'
        log_info "Would convert directory:"
        printf '\n    %s\n\n' "$fs_path"
        PATH_STATUS["$dataset"]="$STATUS_CONVERTED"
        return 0
    fi

    # Ask the user interactively
    if ask_directory_conversion "$dataset" "$fs_path" "$PRESET"; then
        # User chose YES → attempt conversion
        if convert_directory_to_dataset "$dataset" "$fs_path" "$PRESET"; then
            PATH_STATUS["$dataset"]="$STATUS_CONVERTED"
        else
            PATH_STATUS["$dataset"]="$STATUS_ERROR"
        fi
    else
        # User chose NO → mark as skipped; children will inherit the skip
        log_info "Skipping conversion of '$dataset'. Its children will also be skipped."
        PATH_STATUS["$dataset"]="$STATUS_SKIPPED"
    fi

    return 0
}

# ==============================================================================
# SUMMARY REPORT
# ==============================================================================

# Print a final summary: aggregate counts followed by per-dataset status lines
# in execution plan order.
print_summary() {
    local count_created=0
    local count_exists=0
    local count_converted=0
    local count_skipped=0
    local count_pool_missing=0
    local count_error=0

    local dataset status

    # Tally counts for entries in the execution plan only
    # (PATH_STATUS may also contain bare pool-name keys; exclude those)
    for dataset in "${EXECUTION_PLAN[@]}"; do
        status="${PATH_STATUS["$dataset"]-}"
        case "$status" in
            "$STATUS_CREATED")      count_created=$(( count_created + 1 ))           ;;
            "$STATUS_EXISTS")       count_exists=$(( count_exists + 1 ))             ;;
            "$STATUS_CONVERTED")    count_converted=$(( count_converted + 1 ))       ;;
            "$STATUS_SKIPPED")      count_skipped=$(( count_skipped + 1 ))           ;;
            "$STATUS_POOL_MISSING") count_pool_missing=$(( count_pool_missing + 1 )) ;;
            "$STATUS_ERROR")        count_error=$(( count_error + 1 ))               ;;
        esac
    done

    printf '\n'
    printf '========================================\n'
    printf 'Summary\n'
    printf '========================================\n'
    printf '\n'
    printf '  %-16s %d\n' "Created:"       "$count_created"
    printf '  %-16s %d\n' "Exists:"        "$count_exists"
    printf '  %-16s %d\n' "Converted:"     "$count_converted"
    printf '  %-16s %d\n' "Skipped:"       "$count_skipped"
    printf '  %-16s %d\n' "Pool missing:"  "$count_pool_missing"
    printf '  %-16s %d\n' "Error:"         "$count_error"
    printf '\n'
    printf '----------------------------------------\n'
    printf 'Detailed results (execution order):\n'
    printf '----------------------------------------\n'
    printf '\n'

    for dataset in "${EXECUTION_PLAN[@]}"; do
        status="${PATH_STATUS["$dataset"]-UNKNOWN}"
        printf '[%-16s] %s\n' "$status" "$dataset"
    done

    printf '\n'
}

# ==============================================================================
# MAIN ENTRY POINT
# ==============================================================================

main() {
    parse_arguments "$@"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "Dry-run mode is ENABLED. No changes will be made."
    fi

    validate_environment

    # Query pools exactly once; all subsequent pool checks use EXISTING_POOLS
    load_existing_pools

    # Read and normalize the dataset file into LOADED_DATASETS
    load_dataset_file

    # Expand paths into all segments, deduplicate, and sort into EXECUTION_PLAN
    build_execution_plan

    if [[ "${#EXECUTION_PLAN[@]}" -eq 0 ]]; then
        log_info "No datasets to process. Exiting."
        exit 0
    fi

    log_info "Starting processing of ${#EXECUTION_PLAN[@]} dataset(s)..."
    printf '\n'

    local dataset
    for dataset in "${EXECUTION_PLAN[@]}"; do
        process_dataset "$dataset"
    done

    print_summary
}

main "$@"
