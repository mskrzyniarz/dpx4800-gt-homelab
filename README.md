# Configuration of UGREEN DXP4800 GT

_This repository aims to document the setup process of my NAS server._

General information about the hardware used:
- NAS: **UGREEN DXP4800 GT**
- 2 x 32 GB RAM ECC DDR4 _(64 GB total)_
- 1 x NvMe 250 GB _(for TrueNAS Scale OS)_
- 1 x NvMe 1 Tb _(for applications, VMs, etc.)_
- 2 x HDD 4 TB _(for data storage)_
- 2 x HDD 8 TB _(for data storage)_

**The configuration of my pools is as follows:**
```
boot (Stripe)
└─ VDEV 1 x DISK NvMe 250 GB (TrueNAS)

tank (Stripe made of 2 x MIRROR)
├─ VDEV MIRROR 2 x HDD 4 TB
└─ VDEV MIRROR 2 x HDD 8 TB

apps (Stripe)
└─ VDEV 1 x DISK NvMe 1 TB
```

**My dataset and folder structure is as follows:**

**`apps` pool**  
It contains only the Docker runtime environment (images, layers, volumes, etc.). Virtually everything is created and managed by TrueNAS.  
The only manual changes I make to this pool are editing the metadata (the `/mnt/.ix-apps/app_configs/{{app-name}}/metadata.yaml` file) for each application to set the icon, description, URL to the Web UI, etc. This ensures that additional descriptions, buttons, etc. are displayed on the TrueNAS container management page (the TrueNAS `Apps` page). For my home use, this method of managing containers is more than enough for me.
```php
apps
└─ ix-apps
   ├─ app_configs
   └─ ․․․  # other files and directories crated be TrueNAS, ex. docker, catalogs, volumes, etc.
```

**`tank` pool**  
It contains all the data that's important to me. I use it to store copies of my documents, photos, phone backups, app settings, etc.  
Here's my datasets structure (at least for now):
```php
tank [POOL]
├─ apps [DATASET] # contains everything related to applications, it is also root folder of my GIT repo
|  ├─ .gitignore [FILE] # excluding the 'config', 'data', 'backups' folders from GIT
|  ├─ LICENSE [FILE] # terms and conditions for use, reproduction and distribution of this repo
|  ├─ README.md [FILE] # the file you are currently reading
|  │
|  ├─ compose [DATASET]  # contains Docker Compose YAML file, env variables, etc.
|  │  ├─ .gitignore [FILE]  # excluding .env files and other folder/files containing sensitive data
|  │  ├─ shared [DATASET]  # contains shared env variables and settings
|  │  │  ├─ .env [FILE]  # shared env variable
|  │  │  ├─ .env.example [FILE]  # shared env variable without sensitive data
|  │  │  ├─ compose.yml [FILE]  # general shared apps settings
|  │  │  └─ ․․․ # other shared .env and *.yaml files, ex. compose.network.yaml
|  │  │
|  │  ├─ homepage [DATASET]  # Homepage app (example)
|  │  │  ├─ .env [FILE]  # if required, variables intended solely for the Homepage app
|  │  │  ├─ .env.example [FILE]  # if required, .env file without sensitive data
|  │  │  ├─ compose.yml [FILE]  # definition of Homepage app in Docker compose YAML format
|  │  │  ├─ metadata.yml [FILE]  # metadata to overwrite the app information on the Apps page in TrueNAS
|  │  │  └─ README.md [FILE]  # contains instructions for installing and configuring the Homepage app
|  │  │
|  │  └─ ․․․  # datasets with docker-compose.yml files for other apps 
|  │ 
|  ├─ config [DATASET]  # contains separate configurations for each application
|  │  ├─ homepage [DATASET]  # Homepage app configuration: layout, widgets, etc.
|  │  └─ ․․․  # config files for each application, mostly generated and managed entirely by the app
|  |
|  ├─ resources [DATASET]  # static files used be applications
|  |  ├─ .gitignore [FILE]  # excluding folders containing sensitive data, ex. certificates
|  │  ├─ images [DATASET]  # ex. background image for Homepage dashboard
|  │  ├─ icons [DATASET]  # app icons displayed on the TrueNAS page, icons used on Homepage dashboard, etc.
|  │  └─ ․․․  # other datasets with static files, ex. fonts, certificates, etc.
|  |
|  ├─ system [DATASET]  #  scripts, configurations related with OS
|  |  ├─ .gitignore [FILE]  # if required, to exclude files nad folders containing sensitive data
|  │  ├─ scripts [DATASET]  # all kind of scripts
|  │  │  ├─ ugreen-led [DATASET]  # all scripts required to support UGREEN LEDs on my NAS
|  │  │  └─ ․․․  # other script files or datasets with scripts
|  │  └─ ․․․  # other datasets related with OS, ex. services, cron, templates, etc.
|  |
|  ├─ data [DATASET]  # app specific data
|  │  ├─ immich [DATASET]  # immich images
|  │  ├─ paperless [DATASET]  # documents, source images, etc.
|  │  └─ ․․․  # other apps data
|  |
|  ├─ backups [DATASET]  # mainly copies of databases from applications
|  |  ├─ paperless [DATASET]
|  |  |  └─ paperless.sql.gz
|  |  └─ ․․․  # other backups from the app, ex. /immich/database.sql.gz
|  |
|  └─ docs [DATASET]  # is used to document the entire homelab
|     ├─ images [FOLDER]  # images used in the documentation
|     └─ ․․․  # all the documentation files
|
├─ backups [DATASET]  # user backups (I will probably remove this once I have set up Cloudflare)
|  ├─ user1 [DATASET] [SMB]  # user1 backups, user1 with FullControl permissions
|  └─ ․․․  # backups of other users
|
└─ data [DATASET]  # media data, default ARR stack setup
   ├─ media [DATASET]
   ├─ torrents [DATASET]
   └─ usenet [DATASET]
```

This guide does not cover the TrueNAS installation process. Instead, it explains how to configure it immediately after installation.

The TrueNAS version for which this manual was written is **25.10.4**.

### Steps:

1. [Initial setup (set localization settings, create your own admin user)](./truenas-setup/Initial_Setup.md)

2. [Pools configuration (create all pools and use the "apps" pool via TrueNAS Apps)](./truenas-setup/Pools_Configuration.md)

3. [UGREEN LED Controller support (adding the ability to control LED lights on the front panel of the NAS)](./ugreen-dxp4800-gt/LED_Controller_Support.md)

4. [SMB configuration (attach a network drive on Windows OS to access files from the NAS)](./truenas-setup/SMB_Configuration.md)

5. [Useful Apps](./truenas-setup/Useful_Apps.md)

6. [ARR Stack: General](./truenas-setup/ARR_Stack.md)

    6.1. [ARR Stack: qbittorrent](./truenas-setup/ARR_Stack.md)

