[← Back to the Main Menu](../../../README.md)

# Update TrueNAS app metadata

A Bash utility for TrueNAS SCALE that recursively merges a source application metadata YAML into an existing app metadata file.

The script is designed to run without installing packages on the host.  
It uses a local standalone [`yq`](https://github.com/mikefarah/yq) binary ([Mike Farah](https://github.com/mikefarah), Go implementation) located next to the script.

## Features

- Full recursive YAML merge of complete documents (`target * source`)
- Source metadata is authoritative for overlapping keys
- Preserves keys that exist only in target
- Optional application name override
- Optional ordered loading of multiple `.env` files for `${VAR}` interpolation
- Optional version override for:
	- `human_version`
	- `metadata.app_version`
- Dry run mode with full merged YAML preview
- Timestamped backup before write operations
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
`yt` binary version 4.53.3 is also added to this repository.

Here is the link to the file: [yt binary v4.53.3](./yq)

```bash
chmod +x yq
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
chmod +x update-truenas-app-metadata.sh
```

Expected local path:

```text
./update-truenas-app-metadata.sh
```

## Usage

```bash
./update-truenas-app-metadata.sh -f <source-yaml> [options]
```

### Arguments

- `-h`, `--help`
	- Show usage and exit with code `0`.
	- If present, all other arguments are ignored.

- `-f`, `--file <path>`
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

- `-v`, `--version <value>`
	- Optional version value.
	- Applied after merge to:
		- `human_version`
		- `metadata.app_version`

- `-d`, `--dry-run`
	- Perform full processing and preview.
	- Do not create confirmation prompt.
	- Do not overwrite target file.

## Target Resolution

The target file is resolved as:

```text
/mnt/.ix-apps/app_configs/<app-name>/metadata.yaml
```

`<app-name>` is chosen in this order:

1. `--name`
2. `metadata.name` from source YAML

## Examples

Merge using app name from source:

```bash
./update-truenas-app-metadata.sh -f ./metadata.yaml
```

Merge with multiple `.env` files (ordered override):

```bash
./update-truenas-app-metadata.sh -f ./metadata.yaml -e ./compose/shared/.env,./compose/code-server/.env
```

Merge using explicit app name:

```bash
./update-truenas-app-metadata.sh -f ./metadata.yaml -n immich
```

Merge and override version:

```bash
./update-truenas-app-metadata.sh -f ./metadata.yaml -v v4.130.0
```

Dry run preview:

```bash
./update-truenas-app-metadata.sh -f ./metadata.yaml -d
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

In normal mode, before any write operation, the script creates:

```text
metadata.yaml.YYYYMMDD-HHMMSS.bak
```

Example:

```text
metadata.yaml.20260804-223501.bak
```

Backups are never overwritten.

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