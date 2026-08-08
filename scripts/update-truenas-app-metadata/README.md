[← Back to the Main Menu](../../../README.md)

# Update TrueNAS app metadata

A Bash utility for TrueNAS SCALE that recursively merges a source application metadata YAML into an existing app metadata file.

The script is designed to run without installing packages on the host.  
It uses a local standalone [`yq`](https://github.com/mikefarah/yq) binary ([Mike Farah](https://github.com/mikefarah), Go implementation) located next to the script.

## Features

- Full recursive YAML merge of complete documents (`target * source`)
- Source metadata is authoritative for overlapping keys
- Preserves keys that exist only in target
- Interactive yq bootstrap when local binary is missing
- Optional non-interactive mode (`--yes`) for automated runs
- Optional application name override
- Optional explicit target file path override
- Optional ordered loading of multiple `.env` files for `${VAR}` interpolation
- Optional version override for:
	- `human_version`
	- `metadata.app_version`
- Dry run mode with full merged YAML preview
- Change detection - skips save when merged result is identical to target
- Permanent base backup of the original file (created once, never overwritten)
- Automatic timestamped backup rotation (up to 5 backups kept)
- Explicit confirmation before save
- Colored, readable terminal output
- Temporary file workflow with automatic cleanup via `trap`

## Requirements

- TrueNAS SCALE
- Bash
- Standalone [`yq`](https://github.com/mikefarah/yq) binary ([Mike Farah](https://github.com/mikefarah) version written in Go)

No system-wide [`yq`](https://github.com/mikefarah/yq) installation is required.

## Downloading yq

Download the correct Linux AMD64 release from the official project:

- Releases page: <https://github.com/mikefarah/yq/releases>

Place the binary in the same directory as the script and make it executable:

```bash
cd update-truenas-app-metadata
```
```bash
curl -L -o yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
```

If local `./yq` is missing, the script can also offer an interactive download prompt.
Choose Yes/No with arrow keys and confirm with Enter.

```bash
chmod 755 yq
```

Expected local path:

```text
./yq
```

## Installation

Place the script in the same directory as the binary and make it executable:

```bash
cd update-truenas-app-metadata
```

```bash
sudo curl -o update-truenas-app-metadata.sh https://raw.githubusercontent.com/mskrzyniarz/dpx4800-gt-homelab/refs/heads/main/scripts/update-truenas-app-metadata/update-truenas-app-metadata.sh
```
You can also download the script file from this link: [update-truenas-app-metadata.sh](./update-truenas-app-metadata.sh)  

Make it executable
```bash
chmod 755 update-truenas-app-metadata.sh
```

Expected local path:

```text
./update-truenas-app-metadata.sh
```

## Usage

```bash
./update-truenas-app-metadata.sh -s <source-yaml> [options]
```

### Arguments

- `-h`, `--help`
	- Show usage and exit with code `0`.
	- If present, all other arguments are ignored.

- `-s`, `--source <path>`
	- Required unless help is requested.
	- Source YAML used for merge.

- `-e`, `--env-files <paths>`
	- Optional comma-separated list of `.env` files.
	- Files are loaded from left to right.
	- Variables from later files override variables from earlier files.
	- Values are used to replace `${VAR}` placeholders in the source YAML before merge.

- `-n`, `--name <app-name>`
	- Optional app name override.
	- If omitted, app name is read from `metadata.name` in source YAML.

- `-t`, `--target <path>`
	- Optional explicit path to the target metadata file to overwrite.
	- The file must exist and have a `.yaml` or `.yml` extension.
	- If omitted, the target is resolved from the app name (see [Target Resolution](#target-resolution)).

- `-v`, `--version <value>`
	- Optional version value.
	- Applied after merge to:
		- `human_version`
		- `metadata.app_version`

- `-y`, `--yes`
	- Non-interactive mode.
	- Automatically answers yes to all prompts.
	- If local `yq` is missing, it is downloaded automatically.
	- In normal mode, skips summary and confirmation prompt and overwrites target immediately.
	- In `--dry-run` mode, no file is written.

- `-d`, `--dry-run`
	- Perform full processing and preview.
	- Do not create confirmation prompt.
	- Do not overwrite target file.

## Target Resolution

If `--target` is provided, it is used directly as the target file path. The file must exist and have a `.yaml` or `.yml` extension.

If `--target` is not provided, the target is resolved as:

```text
/mnt/.ix-apps/app_configs/<app-name>/metadata.yaml
```

where `<app-name>` is chosen in this order:

1. `--name`
2. `metadata.name` from source YAML

## Examples

Merge using app name from source:

```bash
./update-truenas-app-metadata.sh -s ./metadata.yaml
```

Merge with multiple `.env` files (ordered override):

```bash
./update-truenas-app-metadata.sh -s ./metadata.yaml -e ./compose/shared/.env,./compose/code-server/.env
```

Merge using explicit app name:

```bash
./update-truenas-app-metadata.sh -s ./metadata.yaml -n immich
```

Merge and override version:

```bash
./update-truenas-app-metadata.sh -s ./metadata.yaml -v v4.130.0
```

Merge with an explicit target file path:

```bash
./update-truenas-app-metadata.sh -s ./metadata.yaml -t /mnt/.ix-apps/app_configs/immich/metadata.yaml
```

Run in non-interactive mode:

```bash
./update-truenas-app-metadata.sh -s ./metadata.yaml -y
```

Dry run preview:

```bash
./update-truenas-app-metadata.sh -s ./metadata.yaml -d
```

Run without local `./yq` to trigger interactive download prompt:

```bash
./update-truenas-app-metadata.sh -s ./metadata.yaml
```

Prompt flow:

```text
WARNING: Cannot locate yq executable.
Download yq binary now?
Downloaded yq will be saved in /path/to/script
> Yes
	No
```

## Environment Variable Interpolation

Before merge, the script scans source metadata for placeholders in form `${VAR}` and replaces them with values loaded from `.env` files.

Rules:

- If a referenced variable exists in loaded `.env` values, it is replaced.
- If a referenced variable does not exist, the script exits with an error:

```text
In the source metadata file, the VAR variable is used but it is not defined
```

- Special variables `PUID_NAME` and `PGID_NAME` are allowed even if not present in `.env` files.

Fallback logic:

- `PUID_NAME`
	- If defined in `.env`, use it.
	- Else if `PUID` is defined and mapped, use mapped user name.
	- Else use `unknown`.

- `PGID_NAME`
	- If defined in `.env`, use it.
	- Else if `PGID` is defined and mapped, use mapped group name.
	- Else use `unknown`.

Built-in maps:

```text
USER_NAME[0]=root
USER_NAME[568]=apps
USER_NAME[950]=truenas_admin

USER_GROUP_NAME[0]=root
USER_GROUP_NAME[568]=apps
USER_GROUP_NAME[950]=truenas_admin
```

## Merge Behavior

The script uses Mike Farah `yq` recursive merge semantics equivalent to:

```text
merged = target * source
```

Behavior:

- Source values overwrite target values for overlapping keys
- New source keys are added
- Keys present only in target remain unchanged

The merge is applied to the entire document, not selected fields.

## Backup Behavior

Backups are created in the same directory as the target file, only when actual changes are detected.
If the merged result is identical to the current target, the script exits without saving or creating any backup.

### Base backup

On the first run that produces changes, the script creates a permanent base backup of the original file:

```text
metadata.yaml.base.bak
```

This file is **never overwritten or rotated**. It always reflects the original state of `metadata.yaml` before any script modification, so you can restore to the initial state at any time.

### Timestamped backups

Before every save, the script creates a timestamped backup:

```text
metadata.yaml.YYYYMMDD-HHMMSS.bak
```

Example:

```text
metadata.yaml.20260804-223501.bak
```

At most **5** timestamped backups are kept. When the limit is reached, the oldest one is automatically removed before the new backup is created.
The base backup (`metadata.yaml.base.bak`) is never counted towards this limit.

## Dry Run Mode

Dry run performs all processing steps except saving:

- Resolve target
- Merge YAML
- Apply optional version override
- Print summary
- Print full merged YAML

Dry run never overwrites the target and exits with code `0`.

\___  <br />

[← Back to the Main Menu](../../../README.md)