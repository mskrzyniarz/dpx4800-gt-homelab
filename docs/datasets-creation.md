[← Back to the Main Menu](../README.md)

# Datasets creation

**Table of Contents**  
[List of datasets to be created](#list-of-datasets-to-be-created)  
[Creating datasets automatically](#creating-datasets-automatically)  

## List of datasets to be created:

```
/tank/apps
/tank/apps/compose
/tank/apps/compose/shared
/tank/apps/config
/tank/apps/resources
/tank/apps/resources/icons
/tank/apps/resources/images
/tank/apps/system
/tank/apps/system/scripts
/tank/apps/system/scripts/ugreen-led
/tank/apps/data
/tank/apps/backups
```

You can create all the datasets manually or automate this process using the method described below.

## Creating datasets automatically

> [!NOTE]
> My script uses the TrueNAS API, so creating datasets using this script will only work on a TrueNAS system.  
> This script was tested on TrueNAS Scale v25.10.4.

<br />

**Download my script for creating datasets:**
```bash
sudo curl -o create-datasets.sh https://raw.githubusercontent.com/mskrzyniarz/dpx4800-gt-homelab/refs/heads/main/system/scripts/create-datasets.sh
```

<br />

**Make the file executable:**
```bash
sudo chmod 755 create-datasets.sh
```

<br />

**Create a file containing the datasets you want to create** one after the other (e.g. datasets.txt).  
Datasets should be listed one below the other and begin with the pool name.  
You can use the list from the [List of datasets to be created](#list-of-datasets-to-be-created) section or create you own list.  
Here is an example of the contents of such a file:
```
tank/apps/compose/shared
tank/apps/config/
/tank/apps/resources
```

<br />

**Run command:**

In the place where you downloaded the create-datasets.sh file, run the command:

```bash
sudo ./create-datasets.sh -d /path/to/datasets.txt
```

If you want to see exactly which actions will be performed before implementing them, you can simply add the `--dry-run` argument.

By default, the `APPS` preset is used, but if you want to change it, you can pass an additional parameter:  
`-p` | `--preset` , available values: `GENERIC` | `SMB` | `APPS` | `MULTIPROTOCOL`

If you want to learn more about exactly how the script works and what options it has, check the script's header.  
Here's a [link to the create-datasets.sh script](../system/scripts/create-datasets.sh).

\___  <br />

[← Back to the main menu](../README.md)