[← Back to the Main Menu](../../README.md)

# Dozzle - installation and configuration

## Pre-requirements

Datasets and files structure:

```php
tank [POOL]
└─ apps [DATASET] # Dataset Preset: APPS
   ├─ compose [DATASET] # Dataset Preset: APPS
   │  ├─ dozzle [DATASET] # Dataset Preset: APPS
   |  |  ├─ compose.yaml [FILE]
   |  |  └─ metadata.yaml [FILE]
   |  |
   │  └─ shared [DATASET] # Dataset Preset: APPS
   │     └─ .env [FILE]
   │
   └─ configs [DATASET] # Dataset Preset: APPS
      └─ dozzle [DATASET] # Dataset Preset: APPS
```
In my case, the datasets have the APPS preset because I'm running this Docker container as the user/group: Apps/Apps (568/568).  
If you use a different user or group in the container, remember to set the appropriate ACLs for the above datasets.

You can create the this datasets structure manually or you can use my [create-datasets script](../../docs/datasets-creation.md#creating-datasets-automatically).  
If you use the script, here is the list of dataset to create:
```
tank/apps/compose/dozzle
tank/apps/compose/shared
tank/apps/configs/dozzle
```
<br />

**Here is the example of the `tank/apps/compose/shared/.env` file:**  
[compose/shared/.env](../shared/.env.example)

**Here is the `tank/apps/compose/dozzle/compose.yaml` file:**  
[compose/dozzle/compose.yaml](./compose.yaml)

**Here is the `tank/apps/compose/dozzle/metadata.yaml` file:**  
[compose/dozzle/metadata.yaml](./metadata.yaml)

## Installing Dozzle

Open TrueNAS `Apps` page.

Press the `Discover Apps` button.

Press the `More Options` button (the `⠀⋮⠀` icon), located to the right of the `Custom App` button.

Select the `Install via YAML` option.

In the `Name` field, enter: `dozzle`.

In the `Custom Config` field, enter:
```yaml
include:
  - env_file:
      - /mnt/tank/apps/compose/shared/.env
    path: /mnt/tank/apps/compose/dozzle/compose.yaml
```

## Updating TrueNAS metadata for the Dozzle app

To display additional options and information for `Dozzle` on the Apps page from the TrueNAS system, i.e. icon, link to Web UI, description, etc., it is necessary to edit the `/mnt/.ix-apps/app_configs/dozzle/metadata.yaml` file.

Here is the metadata.yaml file for Dozzle:  
[metadata.yaml](./metadata.yaml)

### Manually modifying the metadata.yaml file

You can simply edit the `metadata.yaml` file manually and update the properties you care about.  
Here's an example using nano:
```bash
sudo nano /mnt/.ix-apps/app_configs/dozzle/metadata.yaml
```

> [!NOTE]
> By default, when you create a `Custom App` on the TrueNAS, it is version `1.0.0`.  
> If you specify a version other than `1.0.0` in the `metadata.yaml` file, you must also create a folder corresponding to that version in `/mnt/.ix-apps/app_configs/dozzle/versions/`.  
> The easiest way is to simply copy the content from version `1.0.0`.  
> For example, if we set version `1.2.3`, the copy command will look like this:  
> ```bash
> sudo cp -r /mnt/.ix-apps/app_configs/dozzle/versions/1.0.0/. /mnt/.ix-apps/app_configs/dozzle/versions/1.2.3
> ```

### Automatic modification of the metadata.yaml file

You can also use my script, which simply requires passing the path to the metadata.yaml file that is to be used to overwrite the application metadata. By default, the application name is taken from the provided metadata.yaml file (from the `metadata.name` property), but if necessary, this can be changed by passing an additional argument to the script.

Here is a link to instructions on how to use this script:

[Update TrueNAS app metadata script](../../system/scripts/update-truenas-app-metadata/README.md)

Command example:
```bash
./update-truenas-app-metadata.sh -f /mnt/tank/apps/compose/dozzle/metadata.yaml -e /mnt/tank/apps/compose/shared/.env -v 10.6.11
```

<br />

### To see updated data for `Dozzle` on the TrueNAS `Apps` page

- open `Apps` TrueNAS page

- Find `dozzle` app on the list and select it

- Press the `Edit` button

- Don't make any changes, just click the `Save` button.


\___  <br />

[← Back to the Main Menu](../../README.md)