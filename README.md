# vaultwarden-dr-suite

A secure, production-ready Disaster Recovery and Lifecycle management suite designed to back up Vaultwarden configurations and data directory architectures to any remote SMB/Samba share (e.g., Network Attached Storage, Windows Server, or a dedicated backup machine). 

This suite is engineered to run with **zero downtime** and is fully hardened to prevent sensitive credential leaks within the Linux process space.

## Features

* 🔒 **Zero-Downtime Hot Backup:** Leverages SQLite's native `.backup` online feature inside the running container, ensuring data consistency across all tables and active write-ahead log (`-wal`) state pools without stopping Vaultwarden.
* 📦 **Flexible Formats:** Supports native `.7z` (Default - maximum compression), standard `.zip`, or traditional Linux `.tar.gz`.
* 🛡️ **Hardened Process-Safe Encryption:** Optional AES-256 password protection. Multi-stage encryption processes pass secrets exclusively via environment memory layers to OpenSSL, leaving passwords completely invisible to system monitoring tools like `ps aux` or `htop`.
* 🔑 **Secrets Isolation:** Uses a separate local configuration secrets file (`chmod 600`) to store SMB credentials and the archive encryption password completely outside the main script logic.
* 🔄 **Integrated Auto-Update Sequence:** Optional mechanism to fetch container updates right after a successful backup. Supports custom compose filenames and legacy/modern Docker environments.
* 🌐 **Universal SMB Support:** Dynamically mounts any SMB share via `cifs-utils` and unmounts it safely after transfer.
* 🧹 **Smart Retention Management:** Automated local, remote (SMB), and log-file cleanup using rolling date-based logic. Set any value to `0` to keep files indefinitely.
* 📋 **Timestamped Log Rotation:** Generates clean, timestamped individual log files per run, preventing a single giant log file and allowing precise, retention-based cleanup.
* 🚨 **Dependency Pre-Flight Check:** Verifies if required CLI tools (`7z`, `openssl`, `cifs-utils`) are available *before* altering any filesystem states.

---

## Prerequisites & Dependency Verification

### Intelligent Pre-Flight Check & Interactive Installation
To prevent unexpected pipeline failures, the script features an intelligent **Pre-Flight Dependency Check**. 

* **Interactive Mode (Manual Run):** If you execute the script manually in your terminal and a package is missing, the script will explicitly ask you if you want to install it now. **The default answer is strictly set to `N` (No)**, ensuring nothing is installed without your explicit consent.
* **Non-Interactive Mode (Automation/Cron):** If running unassisted in the background, it automatically skips the prompt, aborts safely, and logs the exact `apt` command needed for manual installation.

Depending on your chosen configuration, you will need to install specific packages:

### Required Core Tools (Always Needed)
| Tool | Package | Purpose |
| :--- | :--- | :--- |
| `docker` | `docker.io` | Managing the Vaultwarden container lifecycle and database interaction |
| `mount.cifs` | `cifs-utils` | Seamlessly mounting the remote SMB share to the local filesystem |

### Conditional Tools (Based on your Configuration)
| Tool | Package | When is it required? |
| :--- | :--- | :--- |
| `7z` | `p7zip-full` | Required if `ARCHIVE_FORMAT="7z"` (Default) or `ARCHIVE_FORMAT="zip"` |
| `openssl` | `openssl` | Required if `ENCRYPT_BACKUP=true` to execute secure AES-256 encapsulation |
| `docker compose` / `docker-compose` | `docker-compose-v2` / `docker-compose` | Required ONLY if `USE_COMPOSE=true` |

To install all potential dependencies as well as `wget` (which is needed if you want to download the script via CLI), run:

    sudo apt update && sudo apt install cifs-utils p7zip-full openssl wget -y

---

## Zero-Downtime Hot Backup & SQLite WAL Handling

Standard database file copies on a live container often trigger data corruption because Vaultwarden uses SQLite's modern **WAL (Write-Ahead Logging)** engine. In WAL mode, new writes are appended to a separate transactional cache file (`db.sqlite3-wal`) rather than committing directly to the primary database (`db.sqlite3`). 

To resolve this challenge completely without freezing your infrastructure, this script executes a specialized, multi-stage processing routine:

1. **The Online Checkpoint:** The script invokes a native safe-snapshot loop inside the running container (`sqlite3 .backup`). SQLite safely flushes the active WAL cache segments into memory, consolidates uncommitted queries, and renders a fully compiled, standalone file copy named `db_backup.sqlite3`.
2. **The Staging Layer Copy:** A standard local recursive copy (`cp -R`) clones your assets, key infrastructures (`rsa_key.pem`, `config.json`), attachments, and the freshly minted database snapshot into the temporary staging area (`TMP_DIR`).
3. **The WAL/SHM Clean Artifact Purge:** Because the recursive clone copies everything in the directory block, the raw live environment's active `db.sqlite3-wal` and `db.sqlite3-shm` files are pulled into staging as well. **The script explicitly targets and purges these two specific files from the staging cache before triggering compression.**
4. **Infrastructure & Environment Configuration Capture:** If your ecosystem is running via Docker Compose (`USE_COMPOSE=true`), the script automatically locates your specified configuration file (e.g., `compose.yaml`). Furthermore, if you pass your variables (`ADMIN_TOKEN`, database or SMTP passwords) via an external environment declaration file (`COMPOSE_ENV_FILE`), the script maps this file explicitly and pulls it into the root staging layer. Both files are safely included inside the final archive layer.

### Why is including the Compose & Env configuration vital for Disaster Recovery?
A true bare-metal recovery requires more than just raw database states. If your hardware fails entirely, you must be able to restore the exact surrounding runtime definition. By archiving your Docker Compose configuration file and your `.env` configuration file directly alongside your encrypted data folder, you preserve your entire operational parameters. Environmental configurations, tokens, port maps, hardware path links, and proxy networks are safely preserved. Extracting the archive on a fresh host and running `docker compose up -d` will reconstruct your identical, functional Vaultwarden node in seconds with zero manual reconfiguration.

---

## Configuration Variables

Before running the script, you **must open it** and adjust the configuration block at the top to match your local setup. Here is an overview of what you need to configure:

### Directories & Paths
* `SOURCE_DIR`: The path to your live Vaultwarden data directory (the `vw-data` folder on your host machine).
* `TMP_DIR`: A temporary local staging directory used during compression/encryption (automatically cleaned up after every run).
* `LOCAL_BACKUP_DIR`: The directory on your host machine where local backup copies are kept before being rotated.
* `MOUNT_POINT`: A temporary local directory where the remote SMB share will be mounted during the file transfer.

### Docker Settings
* `CONTAINER_NAME`: The exact name of your running Vaultwarden container.
* `USE_COMPOSE`: Set to `true` if you use Docker Compose, or `false` if you use standalone Docker.
* `COMPOSE_DIR`: The path to the folder containing your compose structure (only required if `USE_COMPOSE=true`).
* `COMPOSE_FILE`: The exact filename of your compose configuration (e.g., `compose.yaml`, `docker-compose.yml`, or custom names like `vaultwarden.yaml`).
* `COMPOSE_ENV_FILE`: Optional: The filename of your environment deployment file (e.g., `.env`, `vaultwarden.env`). **Leave empty (`""`) if no external environment file is used.**

### Archive & Encryption Settings
* `ARCHIVE_FORMAT`: Choose between `"7z"` (maximum compression - Default), `"zip"`, or `"tar.gz"`.
* `ENCRYPT_BACKUP`: Set to `true` to enable AES-256 password protection for your archives, or `false` to disable encryption.

### Automated Update Sequence
* `AUTO_UPDATE`: Set to `true` to enable the automated post-backup update pipeline. **Defaults to `false`.** (See details below).

### Retention Settings & Logging
* `KEEP_LOCAL_DAYS`: Number of days to keep backups locally on the host machine. **Set to `0` to keep them forever.**
* `KEEP_REMOTE_DAYS`: Number of days to keep backups on the remote SMB share. **Set to `0` to keep them forever.**
* `ENABLE_LOGGING`: Set to `true` to save backup logs to a file, or `false` to output directly to the console.
* `KEEP_LOG_DAYS`: Number of days to keep standalone timestamped log files before automatic rotation. **Set to `0` to keep them forever.**
* `LOG_ONLY_ERRORS`: Set to `true` to keep logs clean with a one-line summary unless an error occurs, or `false` for verbose step-by-step logging.

---

## Automated Update Sequence (Detailed Logic)

If you toggle `AUTO_UPDATE=true`, the script launches a secure, intelligent image check **immediately after the backup transfer has succeeded**. This sequence acts as a built-in maintenance window. Because it runs *after* the backup, you always have a fresh fallback snapshot readily available if an update introduces structural changes.

The update pipeline adapts dynamically to your specific environment configurations:

### 1. Docker Compose Environments (`USE_COMPOSE=true`)
The script handles custom file declarations and older syntax versions automatically:
* **CLI Auto-Detection:** The script automatically probes your system to detect whether it should use modern Docker V2 syntax (`docker compose`) or legacy V1 Python syntax (`docker-compose`).
* **Targeted Invocations:** It maps requests explicitly to your configured `COMPOSE_FILE` (e.g., executing commands via `$COMPOSE_CMD -f vaultwarden.yaml pull`).
* **Automated Stack Recreation:** If `pull` detects a newer image layer on the registry, it fetches it and recreates the container stack silently via `up -d`. If the image is already up-to-date, no restart is triggered, avoiding unnecessary container downtime.

### 2. Standalone Docker Environments (`USE_COMPOSE=false`)
Automated recreation of standalone containers is intentionally restricted to prevent configuration loss (since a script cannot safely guess your original `docker run` network mappings, environment flags, or local hardware bindings).
* **Safe Pull Execution:** The script dynamically identifies the active image tag used by your container and runs a standard `docker pull` against it.
* **Notification Layer:** If a new image is pulled, the script appends a prominent warning to the backup log summary to let you know a manual container restart is pending. Your live stack remains completely untouched.

---

## Installation & Security Setup

Since this script handles infrastructure paths, it **must** be stored securely. All plaintext SMB credentials and the archive encryption password must be completely stripped from the main script environment and encapsulated into an isolated configuration secrets file.

### 1. Download or Create the Script
Create a secure directory for your infrastructure scripts and download the backup script:

    sudo mkdir -p /opt/scripts
    sudo wget -O /opt/scripts/vaultwarden_backup.sh https://raw.githubusercontent.com/Smok3y97/vaultwarden-dr-suite/main/vaultwarden_backup.sh

### 2. Create the Unified Secrets File
By default, the script looks for a file named `vaultwarden_backup.secrets` located in the **exact same directory** as the script itself (`/opt/scripts/`).

Create the file by copying the repository template or creating it from scratch:

    sudo nano /opt/scripts/vaultwarden_backup.secrets

Add your connection secrets and backup password into the file format cleanly:

    username=your_smb_username
    password=your_smb_password
    ENCRYPTION_PASSWORD=your_secure_backup_encryption_password

### 3. Restrict Permissions (Crucial Hardening)
Apply strict Linux file permissions. The secrets file needs to be readable exclusively by root (`600`), while the script needs to be executable by root (`700`).

    sudo chown root:root /opt/scripts/vaultwarden_backup.sh /opt/scripts/vaultwarden_backup.secrets
    sudo chmod 700 /opt/scripts/vaultwarden_backup.sh
    sudo chmod 600 /opt/scripts/vaultwarden_backup.secrets

* `vaultwarden_backup.sh (700)` -> Owner=Read/Write/Execute, Group/Others=None.
* `vaultwarden_backup.secrets (600)` -> Owner=Read/Write, Group/Others=None (No execution bit needed for text configurations).

---

## Automation via Crontab

To automate the script to run seamlessly every night at **03:00 AM**, add it to the root crontab scheduler.

1. Open the root system crontab:
    
    sudo crontab -e

2. Append the following line to the very bottom:

    0 3 * * * /opt/scripts/vaultwarden_backup.sh

> **Note:** Using the root crontab (`sudo crontab`) is required because the script file permissions are restricted to the `root` user (`700`) and it requires root privileges to execute native Linux `mount` protocols for SMB pipelines.

---

## How to Restore / Extract Backups

⚠️ **CRITICAL COMPATIBILITY NOTE FOR WINDOWS USERS:**
The Windows built-in Compressed Folders utility (File Explorer) **does not support AES-256 encrypted containers at all** (neither `.zip` nor `.7z` nor `.enc`). Attempting to extract an encrypted file layer using standard Windows environments will throw validation errors. 

To successfully decrypt and restore your files on Windows, you **must use a dedicated third-party archive manager** like [7-Zip](https://www.7-zip.org) or WinRAR.

### Decryption Phase (If ENCRYPT_BACKUP=true)
All encrypted backups output as an active `.enc` package to protect the command line execution space. Decrypt the file back into its native format first:

* **Linux / CLI:** `openssl enc -aes-256-cbc -d -pbkdf2 -pass pass:"YourPassword" -in vaultwarden_backup_XYZ.7z.enc -out vaultwarden_backup_XYZ.7z`
* **Windows:** Open the `.enc` file layer using the **7-Zip desktop UI** and extract the internal archive package by supplying your master password.

### Extraction Phase

#### 1. 7z Format (Default)
* **Linux / CLI:** `7z x backup_file.7z -o/path/to/restore/`
* **Windows:** Right-click the file ➡️ *7-Zip* ➡️ *Extract to...* (Enter your password when prompted).
*(Note: Windows 11 can open unencrypted `.7z` archives natively; encrypted versions strictly require the 7-Zip desktop app).*

#### 2. ZIP Format
* **Linux / CLI:** `7z x backup_file.zip -o/path/to/restore/`
* **Windows:** Right-click the file ➡️ *7-Zip* ➡️ *Extract to...* (Enter your password when prompted).
*(Do not use the native Windows "Extract All" wizard, as it fails on AES-256).*

#### 3. TAR.GZ Format
* **Linux / CLI (Unencrypted):** `tar -xzf backup_file.tar.gz -C /path/to/restore/`
* **Linux / CLI (Encrypted .tar.gz.enc):**
    ```bash
    openssl enc -aes-256-cbc -d -pbkdf2 -pass pass:"YourPassword" -in backup_file.tar.gz.enc | tar -xzf - -C /path/to/restore/
    ```
* **Windows Compatibility:** Yes, you can open this on Windows using **7-Zip**! 
  1. If encrypted, decrypt it first using OpenSSL (or use 7-Zip to extract the `.enc` layer).
  2. Open the `.tar.gz` file with 7-Zip to extract the `.tar` archive.
  3. Open the resulting `.tar` file with 7-Zip a second time to extract the final data folder.

---

## AI Transparency & Acknowledgments

In the spirit of openness and transparency within the open-source community, please note that this backup script and its documentation were developed and optimized with the assistance of **Google Gemini**. The core logic, edge-case handling (like database locking and container recovery), and security constraints were engineered iteratively using AI assistance to achieve a highly reliable and robust infrastructure tool.

---

## License

This project is open-source and available under the [MIT License](LICENSE).

## Disclaimer

*This script is provided "as is", without warranty of any kind, express or implied. Always verify your backups manually to ensure data integrity.*
