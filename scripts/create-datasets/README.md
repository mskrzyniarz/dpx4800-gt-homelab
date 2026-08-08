[← Back to the Main Menu](../../../README.md)

# Automatic creation of TrueNAS datasets

A Bash utility for TrueNAS SCALE that creates ZFS datasets from a text file using the TrueNAS middleware API (`midclt`).

The script expands each dataset path into all required parent segments, deduplicates and sorts them, then processes every dataset exactly once.

## Features

- Creates datasets from a file (`-d` / `--datasets`)
- Expands input paths to include all parent dataset segments
- Deduplicates and sorts the execution plan
- Uses only TrueNAS middleware API calls (`midclt`) for dataset operations
- Uses a configurable dataset preset (`-p` / `--preset`, default: `APPS`)
- Dry run mode (`--dry-run`)
- Converts existing regular directories to datasets (interactive)
- Rollback logic when directory-to-dataset conversion fails
- Pool existence is queried once and cached
- Skip-propagation for children of skipped or missing-pool paths
- Detailed final summary with per-dataset statuses

## Requirements

- `TrueNAS SCALE`
- `Bash 5.x`
- `midclt`
- `jq`
- `mktemp`
- `mv`
- `find`

<br />

> [!NOTE]
> The script uses the TrueNAS API, so it works only on a TrueNAS system.

## Installation

Download the script:

```bash
cd create-datasets
```

```bash
sudo curl -o create-datasets.sh https://raw.githubusercontent.com/mskrzyniarz/dpx4800-gt-homelab/refs/heads/main/scripts/create-datasets/create-datasets.sh
```

You can also download the script file from this link: [create-datasets.sh](./create-datasets.sh)

Make it executable:

```bash
chmod 755 create-datasets.sh
```

Expected local path:

```text
./create-datasets.sh
```

## Dataset List File

Create a text file with one dataset path per line. Every path should start with the pool name.

Example (`datasets.txt`):

```text
tank/apps/compose/shared
tank/apps/config
/tank/apps/resources/
```

Normalization and validation rules used by the script:

- Leading/trailing whitespace is removed
- Leading/trailing slashes are removed
- Empty lines are ignored
- Duplicates are ignored
- A valid path must contain at least `pool/dataset`

## Usage

```bash
./create-datasets.sh -d <datasets_file> [-p <preset>] [--dry-run]
```

### Arguments

- `-h`, `--help`
  - Show usage and exit with code `0`.

- `-d`, `--datasets <file>`
  - Required unless help is requested.
  - Path to a dataset list file.

- `-p`, `--preset <preset>`
  - Optional preset for new datasets.
  - Allowed values: `GENERIC`, `MULTIPROTOCOL`, `NFS`, `SMB`, `APPS`
  - Default: `APPS`

- `--dry-run`
  - Show planned actions without making changes.
  - No datasets are created or converted.

## Examples

Create datasets using default preset (`APPS`):

```bash
sudo ./create-datasets.sh -d /path/to/datasets.txt
```

Dry run preview:

```bash
sudo ./create-datasets.sh -d /path/to/datasets.txt --dry-run
```

Use a custom preset:

```bash
sudo ./create-datasets.sh -d /path/to/datasets.txt -p SMB
```

## How Processing Works

The script performs these steps:

1. Validates required tools.
2. Loads existing pools once (`pool.query`) and caches them.
3. Reads and normalizes the dataset list file.
4. Expands each path into all intermediate segments.
5. Deduplicates and sorts the final execution plan.
6. Processes each dataset in order.

Per dataset:

- If an ancestor path was skipped or has a missing pool, the dataset is skipped.
- If the pool does not exist, the dataset is marked as `POOL_MISSING`.
- If the dataset already exists, it is marked as `EXISTS`.
- If `/mnt/pool/<path/to/dataset>` does not exist, the dataset is created.
- If `/mnt/pool/<path/to/dataset>` exists as a regular directory, the script can convert it to a dataset interactively.

## Directory Conversion Behavior

When a regular directory already exists at the dataset mountpoint, the script can convert it to a dataset:

1. Moves the directory to a temporary location in the parent mountpoint.
2. Creates the dataset at the original path.
3. Moves the original contents back into the new dataset.
4. Removes temporary directories.

If dataset creation fails, the script attempts rollback by restoring the original directory.

## Summary Output

After processing, the script prints aggregate counters and detailed results in execution order.

Possible status values:

- `CREATED`  
  number of newly created datasets

- `EXISTS`  
  number of datasets that already existed in TrueNAS

- `CONVERTED`  
  number of regular directories successfully converted to datasets

- `SKIPPED`  
  number of datasets skipped due to user choice or skipped ancestor

- `POOL_MISSING`  
  number of datasets skipped because the target pool does not exist

- `ERROR`  
  number of datasets that ended with an error during processing

\___  <br />

[← Back to the Main Menu](../../../README.md)
