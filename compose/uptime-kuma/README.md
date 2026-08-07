[← Back to the Main Menu](../../README.md)

# Uptime Kuma - installation and configuration

## Pre-requirements

Datasets and files structure:

```php
tank [POOL]
└─ apps [DATASET] # Dataset Preset: APPS
   ├─ compose [DATASET] # Dataset Preset: APPS
   │  ├─ shared [DATASET] # Dataset Preset: APPS
   |  |  └─ .env [FILE]
   |  |
   │  └─ uptime-kuma [DATASET] # Dataset Preset: APPS
   |     ├─ compose.yaml [FILE]
   |     └─ metadata.yaml [FILE]
   │
   └─ configs [DATASET] # Dataset Preset: APPS
      └─ uptime-kuma [DATASET] # Dataset Preset: APPS
```

You can create the this datasets structure manually or you can use my [create-datasets script](../../docs/datasets-creation.md#creating-datasets-automatically).  
If you use the script, here is the list of dataset to create:
```
tank/apps/compose/uptime-kuma
tank/apps/compose/shared
tank/apps/configs/uptime-kuma
```
<br />

**Here is the example of the `tank/apps/compose/shared/.env` file:**  
[compose/shared/.env](../shared/.env.example)

**Here is the `tank/apps/compose/uptime-kuma/compose.yaml` file:**  
[compose/uptime-kuma/compose.yaml](./compose.yaml)

**Here is the `tank/apps/compose/uptime-kuma/metadata.yaml` file:**  
[compose/uptime-kuma/metadata.yaml](./metadata.yaml)

## Installing Uptime Kuma

Open TrueNAS `Apps` page.

Press the `Discover Apps` button.

Press the `More Options` button (the `⠀⋮⠀` icon), located to the right of the `Custom App` button.

Select the `Install via YAML` option.

In the `Name` field, enter: `uptime-kuma`.

In the `Custom Config` field, enter:
```yaml
include:
  - env_file:
      - /mnt/tank/apps/compose/shared/.env
    path: /mnt/tank/apps/compose/uptime-kuma/compose.yaml
```

## Updating TrueNAS metadata for the Uptime Kuma app

To display additional options and information for `Uptime Kuma` on the Apps page from the TrueNAS system, i.e. icon, link to Web UI, description, etc., it is necessary to edit the `/mnt/.ix-apps/app_configs/uptime-kuma/metadata.yaml` file.

Here is the metadata.yaml file for Uptime Kuma:  
[metadata.yaml](./metadata.yaml)

### Manually modifying the metadata.yaml file

You can simply edit the `metadata.yaml` file manually and update the properties you care about.  
Here's an example using nano:
```bash
sudo nano /mnt/.ix-apps/app_configs/uptime-kuma/metadata.yaml
```

> [!NOTE]
> By default, when you create a `Custom App` on the TrueNAS, it is version `1.0.0`.  
> If you specify a version other than `1.0.0` in the `metadata.yaml` file, you must also create a folder corresponding to that version in `/mnt/.ix-apps/app_configs/uptime-kuma/versions/`.  
> The easiest way is to simply copy the content from version `1.0.0`.  
> For example, if we set version `1.2.3`, the copy command will look like this:  
> ```bash
> sudo cp -r /mnt/.ix-apps/app_configs/uptime-kuma/versions/1.0.0/. /mnt/.ix-apps/app_configs/uptime-kuma/versions/1.2.3
> ```

### Automatic modification of the metadata.yaml file

You can also use my script, which simply requires passing the path to the metadata.yaml file that is to be used to overwrite the application metadata. By default, the application name is taken from the provided metadata.yaml file (from the `metadata.name` property), but if necessary, this can be changed by passing an additional argument to the script.

Here is a link to instructions on how to use this script:

[Update TrueNAS app metadata script](../../scripts/update-truenas-app-metadata/README.md)

Command example:
```bash
./update-truenas-app-metadata.sh -s /mnt/tank/apps/compose/uptime-kuma/metadata.yaml -e /mnt/tank/apps/compose/shared/.env -v 2.4.0
```

<br />

### To see updated data for `Uptime Kuma` on the TrueNAS `Apps` page

- open `Apps` TrueNAS page

- Find `uptime-kuma` app on the list and select it

- Press the `Edit` button

- Don't make any changes, just click the `Save` button.


### 3.3 Configuration of Uptime Kuma

Open Uptime Kuma Web UI `http://YOUR.I.ADDRESS:3001`, ex. `192.168.1.50:3001`

If this is your first time visiting this page, you will be asked to create a user account.

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
