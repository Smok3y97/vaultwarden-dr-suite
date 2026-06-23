#!/bin/bash

# ==============================================================================
# VAULTWARDEN DISASTER RECOVERY SUITE (VW-DR-SUITE)
# ==============================================================================
#
# REQUIRED DEPENDENCIES:
# - 'cifs-utils' to connect to the SMB share.
# - 'p7zip-full' (Provides '7z', required if ARCHIVE_FORMAT is "7z" or "zip").
# - 'openssl' (Required if ENCRYPT_BACKUP=true).
#
# Install all dependencies via:
#   apt update && apt install cifs-utils p7zip-full openssl -y
#
# ------------------------------------------------------------------------------
# SECURITY & DEPLOYMENT INSTRUCTIONS (How to save this script securely):
#
# 1. Create the secrets file in the SAME directory as this script
#    by copying the template: 'cp vaultwarden_backup.secrets.template vaultwarden_backup.secrets'
#    Fill in your SMB secrets and your desired archive encryption password.
#    
# 2. Restrict permissions immediately!
#    chmod 600 vaultwarden_backup.secrets
#    chown root:root vaultwarden_backup.sh && chmod 700 vaultwarden_backup.sh
#
# ==============================================================================

# Dynamically resolve the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==========================================
# CONFIGURATION BLOCK
# ==========================================
SOURCE_DIR="/opt/stacks/vaultwarden/vw-data" # Verified Vaultwarden data directory on the host
TMP_DIR="/tmp/vw_backup_tmp"               # Temporary directory for staging
LOCAL_BACKUP_DIR="/var/backups/vaultwarden" # Local backup storage on the host
MOUNT_POINT="/mnt/smb_backup"              # Temporary mount point on the host
SMB_SHARE="//192.168.1.X/your-backup-share" # Target SMB share path (No trailing slash!)

# Docker Settings
CONTAINER_NAME="vaultwarden"               # Name of your Vaultwarden container
USE_COMPOSE=false                          # Set to true for Docker Compose, false for plain Docker
COMPOSE_DIR="/opt/stacks/vaultwarden"      # Path to your compose folder (if USE_COMPOSE=true)
COMPOSE_FILE="compose.yaml"                # Name of your file (e.g., compose.yaml, docker-compose.yml)
COMPOSE_ENV_FILE=""                        # Optional: Name of your environment file (e.g., .env). Leave empty if not used.

# Archive & Encryption Settings
ARCHIVE_FORMAT="7z"                        # Options: "7z", "zip", or "tar.gz" (Default is 7z)
ENCRYPT_BACKUP=true                        # Set to true to enable password protection, false to disable

# Auto-Update Settings (Safe post-backup update sequence)
AUTO_UPDATE=false                          # Set to true to automatically check and apply updates after a successful backup

# Retention Settings (Cleanup - Set any value to 0 to keep files forever)
KEEP_LOCAL_DAYS=7                          # Days backups remain locally on the host
KEEP_REMOTE_DAYS=30                        # Days backups remain on the SMB share

# Logging Configuration
ENABLE_LOGGING=true                        # Set to true to enable logging to a file, false to disable
KEEP_LOG_DAYS=14                           # Days logs remain before deletion (0 to keep forever)
LOG_ONLY_ERRORS=true                       # Set to true to log errors only, false for verbose output

# ==========================================
# SYSTEM VARIABLES & LOGGING SETUP
# ==========================================
# Secrets File Path (Contains SMB login & archive password)
BACKUP_CRED_FILE="$SCRIPT_DIR/vaultwarden_backup.secrets" 

# Timestamp, Filename and Timestamped Log Handling
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="/var/log/vaultwarden_backup_$TIMESTAMP.log"

if [ "$ENCRYPT_BACKUP" = true ]; then
    BACKUP_NAME="vaultwarden_backup_$TIMESTAMP.$ARCHIVE_FORMAT.enc"
else
    BACKUP_NAME="vaultwarden_backup_$TIMESTAMP.$ARCHIVE_FORMAT"
fi

# Create a temporary file to capture stderr when LOG_ONLY_ERRORS is true
ERR_LOG=$(mktemp)
HAS_ERRORS=0

if [ "$ENABLE_LOGGING" = true ]; then
    if [ "$KEEP_LOG_DAYS" -gt 0 ] && [ -d "$(dirname "$LOG_FILE")" ]; then
        find "$(dirname "$LOG_FILE")" -type f -name "vaultwarden_backup_*.log" -mtime +$KEEP_LOG_DAYS -delete
    fi
    if [ "$LOG_ONLY_ERRORS" = false ]; then
        exec >> "$LOG_FILE" 2>&1
    fi
fi

log_message() {
    local type="$1"
    local msg="$2"
    if [ "$ENABLE_LOGGING" = true ]; then
        if [ "$LOG_ONLY_ERRORS" = false ]; then
            echo "$msg"
        elif [ "$type" = "ERROR" ] || [ "$type" = "SUMMARY" ]; then
            echo "$msg" >> "$LOG_FILE"
        fi
    else
        echo "$msg"
    fi
}

# ==========================================
# CORE AUXILIARY FUNCTIONS
# ==========================================
check_status() {
    local status=$1
    local error_msg=$2
    if [ $status -ne 0 ]; then
        HAS_ERRORS=1
        log_message "ERROR" "CRITICAL ERROR: $error_msg (Exit Code: $status)"
        
        # Emergency Cleanup
        rm -rf "$TMP_DIR"
        if [ -n "$DETECTED_BACKUP" ]; then
            rm -f "$SOURCE_DIR/$DETECTED_BACKUP"
        fi
        if mountpoint -q "$MOUNT_POINT"; then
            umount "$MOUNT_POINT"
        fi
        
        END_DATE=$(date)
        if [ "$LOG_ONLY_ERRORS" = true ] && [ "$ENABLE_LOGGING" = true ]; then
            {
                echo "=== Backup ABORTED WITH ERRORS at $END_DATE ==="
                echo "--- Captured Error Log ---"
                if [ -f "$ERR_LOG" ]; then
                    cat "$ERR_LOG"
                fi
                echo "--------------------------"
            } >> "$LOG_FILE"
        fi
        
        rm -f "$ERR_LOG"
        exit 1
    fi
}

run_cmd() {
    if [ "$ENABLE_LOGGING" = true ] && [ "$LOG_ONLY_ERRORS" = true ]; then
        eval "$@" > /dev/null 2>> "$ERR_LOG"
    else
        eval "$@"
    fi
    return $?
}

# ==========================================
# DOCKER COMPOSE CLI AUTO-DETECTION
# ==========================================
COMPOSE_CMD=""
if [ "$USE_COMPOSE" = true ]; then
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    fi
fi

# ==========================================
# PRE-FLIGHT DEPENDENCY CHECK
# ==========================================
check_dependency() {
    local cmd=$1
    local package=$2
    local reason=$3
    
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_message "ERROR" "DEPENDENCY WARNING: Required tool '$cmd' is missing (Needed for $reason)."
        
        if [ -t 0 ]; then
            echo ""
            read -p "Would you like to install '$package' now? [y/N]: " user_response
            user_response=${user_response,,}
            
            if [[ "$user_response" =~ ^(yes|y)$ ]]; then
                log_message "INFO" "Attempting to install $package..."
                apt update && apt install "$package" -y
                
                if command -v "$cmd" >/dev/null 2>&1; then
                    log_message "INFO" "Successfully installed '$package'. Continuing backup..."
                    return 0
                else
                    log_message "ERROR" "CRITICAL: Installation of '$package' failed."
                fi
            else
                log_message "INFO" "Installation declined by user."
            fi
        else
            log_message "ERROR" "Non-interactive environment detected (e.g., Cronjob). Skipping installation prompt."
        fi
        
        log_message "ERROR" "Fix: Please install it manually by running: apt update && apt install $package -y"
        rm -f "$ERR_LOG"
        exit 1
    fi
}

# Always required CLI tools
check_dependency "docker" "docker.io" "managing the Vaultwarden container state"
check_dependency "mount.cifs" "cifs-utils" "mounting the remote SMB share"

# Explicit Docker Compose validation (Handles V1 vs V2 edge case)
if [ "$USE_COMPOSE" = true ] && [ -z "$COMPOSE_CMD" ]; then
    log_message "ERROR" "DEPENDENCY ERROR: Neither 'docker compose' (V2) nor 'docker-compose' (V1) was found on this system."
    log_message "ERROR" "Fix: Please install docker-compose or the docker-compose-plugin."
    rm -f "$ERR_LOG"
    exit 1
fi

# Dynamic checks based on active configurations
if [ "$ARCHIVE_FORMAT" = "7z" ] || [ "$ARCHIVE_FORMAT" = "zip" ]; then
    check_dependency "7z" "p7zip-full" "compressing the backup into secure formats"
fi

if [ "$ENCRYPT_BACKUP" = true ]; then
    check_dependency "openssl" "openssl" "encrypting the archive securely via AES-256"
fi

# Sanity Check: Verify secrets file exists before doing anything
if [ ! -f "$BACKUP_CRED_FILE" ]; then
    log_message "ERROR" "CRITICAL: Secrets file missing at $BACKUP_CRED_FILE"
    log_message "ERROR" "Please create it based on the template and secure it with 'chmod 600'."
    rm -f "$ERR_LOG"
    exit 1
fi

# Safely extract the encryption password from the secrets file
if [ "$ENCRYPT_BACKUP" = true ]; then
    ENCRYPTION_PASSWORD=$(grep '^ENCRYPTION_PASSWORD=' "$BACKUP_CRED_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    if [ -z "$ENCRYPTION_PASSWORD" ]; then
        log_message "ERROR" "CRITICAL: ENCRYPT_BACKUP is true, but ENCRYPTION_PASSWORD is empty or missing in $BACKUP_CRED_FILE"
        rm -f "$ERR_LOG"
        exit 1
    fi
fi

# ==========================================
# START OF THE BACKUP PROCESS
# ==========================================
START_DATE=$(date)
log_message "INFO" "=== Backup started at $START_DATE ==="

# 1. Verify and create local directories
log_message "INFO" "Preparing local directories..."
run_cmd "mkdir -p '$TMP_DIR'"
check_status $? "Failed to create temporary directory ($TMP_DIR)."

run_cmd "mkdir -p '$LOCAL_BACKUP_DIR'"
check_status $? "Failed to create local backup directory ($LOCAL_BACKUP_DIR)."

run_cmd "mkdir -p '$MOUNT_POINT'"
check_status $? "Failed to create mount point ($MOUNT_POINT)."

# 2. Hot-Backup: Native built-in Vaultwarden backup command (Zero Downtime)
log_message "INFO" "Executing container-native Vaultwarden online backup..."
run_cmd "docker exec $CONTAINER_NAME /vaultwarden backup"
check_status $? "Failed to execute container-native Vaultwarden backup wrapper."

# Dynamically capture the newly created timestamped database file (newest one)
DETECTED_BACKUP=$(basename "$(ls -t "$SOURCE_DIR"/db_*.sqlite3 2>/dev/null | head -n 1)")

if [ -z "$DETECTED_BACKUP" ]; then
    check_status 1 "Could not locate the generated database backup file (db_*.sqlite3) in $SOURCE_DIR."
fi

# 3. Copy Vaultwarden data to temporary staging directory
log_message "INFO" "Copying data files to staging area..."
run_cmd "cp -R '$SOURCE_DIR/.' '$TMP_DIR/'"
check_status $? "Failed to copy data from $SOURCE_DIR to staging directory."

# 3.1 Infrastructure Backup: Include Docker Compose file and optional environment file if enabled
if [ "$USE_COMPOSE" = true ]; then
    if [ -f "$COMPOSE_DIR/$COMPOSE_FILE" ]; then
        log_message "INFO" "Copying Docker Compose configuration ($COMPOSE_FILE) to staging area..."
        run_cmd "cp '$COMPOSE_DIR/$COMPOSE_FILE' '$TMP_DIR/'"
        check_status $? "Failed to copy compose configuration file to staging directory."
    else
        check_status 1 "USE_COMPOSE is true, but configuration file was not found at $COMPOSE_DIR/$COMPOSE_FILE"
    fi
    
    # Securely append the optional environment variable file into the staging root block if configured
    if [ -n "$COMPOSE_ENV_FILE" ]; then
        if [ -f "$COMPOSE_DIR/$COMPOSE_ENV_FILE" ]; then
            log_message "INFO" "Copying Docker Compose environment file ($COMPOSE_ENV_FILE) to staging area..."
            run_cmd "cp '$COMPOSE_DIR/$COMPOSE_ENV_FILE' '$TMP_DIR/'"
            check_status $? "Failed to copy compose environment file to staging directory."
        else
            check_status 1 "COMPOSE_ENV_FILE is specified as '$COMPOSE_ENV_FILE', but was not found at $COMPOSE_DIR/$COMPOSE_ENV_FILE"
        fi
    fi
fi

# 4. Finalize staging structure by applying the clean container-native hot-backup
if [ -f "$TMP_DIR/$DETECTED_BACKUP" ]; then
    run_cmd "mv '$TMP_DIR/$DETECTED_BACKUP' '$TMP_DIR/db.sqlite3'"
    check_status $? "Failed to rename hot-backup database file in staging area."
fi

# AUTOMATED SWEEP: Purge ANY temp database backup artifacts from live production folder to prevent disk accumulation
run_cmd "find '$SOURCE_DIR' -maxdepth 1 -type f -name 'db_*.sqlite3' -delete"
check_status $? "Failed to purge database backup artifacts from production directory."

# 4.1 HARDENING: Remove live WAL and SHM files from staging area to prevent restore corruption
if [ -f "$TMP_DIR/db.sqlite3-wal" ] || [ -f "$TMP_DIR/db.sqlite3-shm" ]; then
    log_message "INFO" "Removing temporary WAL and SHM files from staging to ensure clean restore state..."
    run_cmd "rm -f '$TMP_DIR/db.sqlite3-wal' '$TMP_DIR/db.sqlite3-shm'"
    check_status $? "Failed to remove WAL/SHM artifacts from staging area."
fi

# 5. Compress and stage archive (Unencrypted intermediate file)
log_message "INFO" "Compressing backup files ($ARCHIVE_FORMAT)..."
cd "$TMP_DIR" || check_status $? "Failed to enter temporary staging directory."

if [ "$ARCHIVE_FORMAT" = "7z" ]; then
    run_cmd "7z a -m0=lzma2 -mx=9 '$LOCAL_BACKUP_DIR/$BACKUP_NAME.tmp' ."
    check_status $? "Failed to create 7z archive."
elif [ "$ARCHIVE_FORMAT" = "zip" ]; then
    run_cmd "7z a -tzip '$LOCAL_BACKUP_DIR/$BACKUP_NAME.tmp' ."
    check_status $? "Failed to create ZIP archive."
elif [ "$ARCHIVE_FORMAT" = "tar.gz" ]; then
    run_cmd "tar -czf '$LOCAL_BACKUP_DIR/$BACKUP_NAME.tmp' ."
    check_status $? "Failed to create tar.gz archive."
fi

# 6. Secure Encryption Layer via OpenSSL (Hides password from process list)
if [ "$ENCRYPT_BACKUP" = true ]; then
    log_message "INFO" "Applying process-safe AES-256 encryption via OpenSSL..."
    export ENCRYPTION_PASSWORD
    run_cmd "openssl enc -aes-256-cbc -salt -pbkdf2 -pass env:ENCRYPTION_PASSWORD -in '$LOCAL_BACKUP_DIR/$BACKUP_NAME.tmp' -out '$LOCAL_BACKUP_DIR/$BACKUP_NAME'"
    check_status $? "Secure OpenSSL encryption layer execution failed."
    
    run_cmd "rm -f '$LOCAL_BACKUP_DIR/$BACKUP_NAME.tmp'"
    check_status $? "Failed to remove unencrypted temporary backup archive."
    unset ENCRYPTION_PASSWORD
else
    run_cmd "mv '$LOCAL_BACKUP_DIR/$BACKUP_NAME.tmp' '$LOCAL_BACKUP_DIR/$BACKUP_NAME'"
    check_status $? "Failed to finalize unencrypted backup archive name."
fi

# 7. Clean up temporary staging files (We move out of the directory before deleting it!)
cd "$SCRIPT_DIR" || cd /
run_cmd "rm -rf '$TMP_DIR'"
check_status $? "Failed to clean up staging directory."

# 8. Mount SMB share via Credentials File, transfer backup, and apply Remote Retention
log_message "INFO" "Connecting to SMB share securely..."
if [ "$ENABLE_LOGGING" = true ] && [ "$LOG_ONLY_ERRORS" = true ]; then
    mount -t cifs -o credentials="$BACKUP_CRED_FILE",vers=3.0 "$SMB_SHARE" "$MOUNT_POINT" > /dev/null 2>> "$ERR_LOG"
else
    mount -t cifs -o credentials="$BACKUP_CRED_FILE",vers=3.0 "$SMB_SHARE" "$MOUNT_POINT"
fi

if mountpoint -q "$MOUNT_POINT"; then
    log_message "INFO" "Copying backup archive to the SMB share..."
    run_cmd "cp '$LOCAL_BACKUP_DIR/$BACKUP_NAME' '$MOUNT_POINT/'"
    check_status $? "Failed to copy backup file to SMB share."
    
    if [ "$KEEP_REMOTE_DAYS" -gt 0 ]; then
        log_message "INFO" "Cleaning up old remote backups on the SMB share..."
        run_cmd "find '$MOUNT_POINT' -type f -name \"vaultwarden_backup_*\" -mtime +$KEEP_REMOTE_DAYS -delete"
        check_status $? "Failed during remote retention cleanup."
    fi
    
    run_cmd "umount '$MOUNT_POINT'"
    check_status $? "Failed to safely unmount SMB share."
else
    check_status 1 "Secure connection to SMB share failed. Mount point is unavailable."
fi

# 9. Clean up old local backups on the host
if [ "$KEEP_LOCAL_DAYS" -gt 0 ]; then
    log_message "INFO" "Cleaning up old local backups..."
    run_cmd "find '$LOCAL_BACKUP_DIR' -type f -name \"vaultwarden_backup_*\" -mtime +$KEEP_LOCAL_DAYS -delete"
    check_status $? "Failed during local retention cleanup."
fi

# ==========================================
# 10. OPTIONAL: DOCKER IMAGE UPDATE CHECK
# ==========================================
UPDATE_STATUS_MSG=""
if [ "$AUTO_UPDATE" = true ]; then
    log_message "INFO" "Backup finalized. Starting update sequence..."
    
    if [ "$USE_COMPOSE" = true ]; then
        log_message "INFO" "Checking for updates via $COMPOSE_CMD ($COMPOSE_FILE)..."
        PULL_OUTPUT=$(cd "$COMPOSE_DIR" && $COMPOSE_CMD -f "$COMPOSE_FILE" pull 2>&1)
        
        if [[ "$PULL_OUTPUT" == *"Downloaded newer image"* || "$PULL_OUTPUT" == *"Pulled"* ]]; then
            log_message "SUMMARY" "A new Vaultwarden image layer was discovered and fetched."
            log_message "INFO" "Recreating container environment securely..."
            cd "$COMPOSE_DIR" && $COMPOSE_CMD -f "$COMPOSE_FILE" up -d > /dev/null 2>&1
            UPDATE_STATUS_MSG=" -> UPDATE APPLIED: Container environment recreated via $COMPOSE_CMD successfully."
        else
            log_message "INFO" "Vaultwarden infrastructure is already running the latest image version."
        fi
    else
        log_message "INFO" "Checking for updates via standalone Docker daemon..."
        IMAGE_NAME=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        if [ -n "$IMAGE_NAME" ]; then
            PULL_OUTPUT=$(docker pull "$IMAGE_NAME" 2>&1)
            if [[ "$PULL_OUTPUT" == *"Downloaded newer image"* ]]; then
                UPDATE_STATUS_MSG=" -> UPDATE NOTICE: A newer image version was pulled to the host. Please restart your container manually to apply changes."
            else
                log_message "INFO" "Vaultwarden deployment is already up to date."
            fi
        fi
    fi
fi

# ==========================================
# EVALUATE LOG OUTPUTS & CLOSE
# ==========================================
END_DATE=$(date)

if [ "$LOG_ONLY_ERRORS" = true ] && [ "$ENABLE_LOGGING" = true ]; then
    if [ $HAS_ERRORS -eq 1 ] || [ -s "$ERR_LOG" ]; then
        {
            echo "=== Backup finished WITH ERRORS at $END_DATE ==="
            echo "--- Captured Error Log ---"
            if [ -f "$ERR_LOG" ]; then
                cat "$ERR_LOG"
            fi
            echo "--------------------------"
        } >> "$LOG_FILE"
    else
        log_message "SUMMARY" "[$END_DATE] Vaultwarden backup completed successfully without errors.$UPDATE_STATUS_MSG"
    fi
else
    log_message "INFO" "=== Backup finished at $END_DATE ==="
    if [ -n "$UPDATE_STATUS_MSG" ]; then
        log_message "SUMMARY" "$UPDATE_STATUS_MSG"
    fi
fi

rm -f "$ERR_LOG"
