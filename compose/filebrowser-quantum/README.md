[← Back to the Main Menu](../../README.md)

# FileBrowser Quantum - installation and configuration

## Pre-requirements

Datasets and files structure:

```php
tank [POOL]
└─ apps [DATASET] # Dataset Preset: APPS
   ├─ compose [DATASET] # Dataset Preset: APPS
   │  ├─ shared [DATASET] # Dataset Preset: APPS
   |  |  └─ .env [FILE]
   |  |
   │  └─ filebrowser-quantum [DATASET] # Dataset Preset: APPS
   |     ├─ .env [FILE]
   |     ├─ compose.yaml [FILE]
   |     └─ metadata.yaml [FILE]
   │
   ├─ configs [DATASET] # Dataset Preset: APPS
   │  └─ filebrowser-quantum [DATASET] # Dataset Preset: APPS
   |     └─ config.yaml [FILE] # FileBrowser Quantum configuration file
   │
   └─ data [DATASET] # Dataset Preset: APPS
      └─ filebrowser-quantum [DATASET] # Dataset Preset: APPS
```

You can create the this datasets structure manually or you can use my [create-datasets script](../../docs/datasets-creation.md#creating-datasets-automatically).  
If you use the script, here is the list of dataset to create:
```
tank/apps/compose/filebrowser-quantum
tank/apps/compose/shared
tank/apps/configs/filebrowser-quantum
tank/apps/data/filebrowser-quantum
```
<br />

**Here is the example of the `tank/apps/compose/shared/.env` file:**  
[compose/shared/.env](../shared/.env.example)

**Here is the example of the `tank/apps/compose/filebrowser-quantum/.env` file:**  
[compose/filebrowser-quantum/.env](./.env.exmpale)

**Here is the `tank/apps/compose/filebrowser-quantum/compose.yaml` file:**  
[compose/filebrowser-quantum/compose.yaml](./compose.yaml)

**Here is the `tank/apps/compose/filebrowser-quantum/metadata.yaml` file:**  
[compose/filebrowser-quantum/metadata.yaml](./metadata.yaml)

## Initializing the configuration

:exclamation: **Before starting the installation, first copy the FileBrowser Quantum configuration file:**

[config.yaml](./config.yaml)

to the location:

```
/mnt/tank/apps/config/filebrowser-quantum/
```

If necessary, adjust the configuration to your needs.

## Installing FileBrowser Quantum

:exclamation: **IMPORTANT: In the [docker-compose.yaml](./compose.yaml) file, I use the root user (`0`) and group (`0`) to allow the application to access all directories and avoid problems with permissions. This isn't a problem for me as I only use this application on the local network, but if you intend to grant public access, set the appropriate user and group.**

Open TrueNAS `Apps` page.

Press the `Discover Apps` button.

Press the `More Options` button (the `⠀⋮⠀` icon), located to the right of the `Custom App` button.

Select the `Install via YAML` option.

In the `Name` field, enter: `filebrowser-quantum`.

In the `Custom Config` field, enter:
```yaml
include:
  - env_file:
      - /mnt/tank/apps/compose/shared/.env
      - /mnt/tank/apps/compose/filebrowser-quantum/.env
    path: /mnt/tank/apps/compose/filebrowser-quantum/compose.yaml
```

## Updating TrueNAS metadata for the FileBrowser Quantum app

To display additional options and information for `FileBrowser Quantum` on the Apps page from the TrueNAS system, i.e. icon, link to Web UI, description, etc., it is necessary to edit the `/mnt/.ix-apps/app_configs/filebrowser-quantum/metadata.yaml` file.

Here is the metadata.yaml file for FileBrowser Quantum:  
[metadata.yaml](./metadata.yaml)

### Manually modifying the metadata.yaml file

You can simply edit the `metadata.yaml` file manually and update the properties you care about.  
Here's an example using nano:
```bash
sudo nano /mnt/.ix-apps/app_configs/filebrowser-quantum/metadata.yaml
```

> [!NOTE]
> By default, when you create a `Custom App` on the TrueNAS, it is version `1.0.0`.  
> If you specify a version other than `1.0.0` in the `metadata.yaml` file, you must also create a folder corresponding to that version in `/mnt/.ix-apps/app_configs/filebrowser-quantum/versions/`.  
> The easiest way is to simply copy the content from version `1.0.0`.  
> For example, if we set version `1.2.3`, the copy command will look like this:  
> ```bash
> sudo cp -r /mnt/.ix-apps/app_configs/filebrowser-quantum/versions/1.0.0/. /mnt/.ix-apps/app_configs/filebrowser-quantum/versions/1.2.3
> ```

### Automatic modification of the metadata.yaml file

You can also use my script, which simply requires passing the path to the metadata.yaml file that is to be used to overwrite the application metadata. By default, the application name is taken from the provided metadata.yaml file (from the `metadata.name` property), but if necessary, this can be changed by passing an additional argument to the script.

Here is a link to instructions on how to use this script:

[Update TrueNAS app metadata script](../../scripts/update-truenas-app-metadata/README.md)

Command example:
```bash
./update-truenas-app-metadata.sh -f /mnt/tank/apps/compose/filebrowser-quantum/metadata.yaml -e /mnt/tank/apps/compose/shared/.env -v 1.5.0
```

<br />

### To see updated data for `FileBrowser Quantum` on the TrueNAS `Apps` page

- open `Apps` TrueNAS page

- Find `filebrowser-quantum` app on the list and select it

- Press the `Edit` button

- Don't make any changes, just click the `Save` button.

## Configuration of FileBrowser Quantum

Open FileBrowser Quantum Web UI `http://YOUR.I.ADDRESS:3001`, ex. `192.168.1.50:3001`

If you have not set the `FILEBROWSER_ADMIN_PASSWORD` variable in the docker-compose.yaml file, the first time you visit this page you will be asked to create a user account.

**An example of adding uptime monitoring for a Dozzle Docker container:**
- Press the `+ Add New Monitor` button.
- In the `Monitor Type` field, select `HTTP(s)`.
- In the `Friendly Name` field , enter `Dozzle`.
- In the `URL` field, enter `http://YOUR_NAS_IP:8888` (ex. `http://192.168.1.50:8888`).
- Set the rest of the settings according to your preferences.
- Press the `Save` button.

**Setting up notifications:**
- Click on the user icon (in the top right-hand corner)
- Select the `Settings` option
- Select the `Notifications` tab
- Press the `Set Up Notification` button
- Setup your notification (ex. Gotify)

\___  <br />

[← Back to the Main Menu](../../README.md)
