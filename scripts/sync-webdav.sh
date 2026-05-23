#!/bin/bash
# scripts/sync-webdav.sh

# Defaults
DATA_DIR="${DATA_DIR:-./data}"
WEBDAV_URL="${WEBDAV_URL:-}"
WEBDAV_USER="${WEBDAV_USER:-}"
WEBDAV_PASS="${WEBDAV_PASS:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
G_TOKEN="${G_TOKEN:-}"

BACKUP_FILE="${DATA_DIR}/latest-backup.tar.gz"
BACKUP_EXTRACT_DIR="${DATA_DIR}/restore"

echo "Ensuring data directory exists at ${DATA_DIR}"
mkdir -p "${DATA_DIR}"

echo "Starting initial recovery process..."

recovery_success=false

# Attempt WebDAV recovery
if [ -n "${WEBDAV_URL}" ]; then
    echo "Attempting to download latest backup from WebDAV..."
    CURL_AUTH=""
    if [ -n "${WEBDAV_USER}" ] && [ -n "${WEBDAV_PASS}" ]; then
        CURL_AUTH="-u ${WEBDAV_USER}:${WEBDAV_PASS}"
    fi

    # Download to temporary location first
    TMP_DOWNLOAD="${DATA_DIR}/tmp-download.tar.gz"
    
    if curl -s -f ${CURL_AUTH} -o "${TMP_DOWNLOAD}" "${WEBDAV_URL}/latest-backup.tar.gz"; then
        echo "Successfully downloaded backup from WebDAV."
        mv "${TMP_DOWNLOAD}" "${BACKUP_FILE}"
        mkdir -p "${BACKUP_EXTRACT_DIR}"
        if tar -xzf "${BACKUP_FILE}" -C "${BACKUP_EXTRACT_DIR}"; then
            echo "Successfully extracted WebDAV backup."
            recovery_success=true
        else
            echo "Failed to extract WebDAV backup."
        fi
    else
        echo "Failed to download backup from WebDAV."
        rm -f "${TMP_DOWNLOAD}"
    fi
else
    echo "WEBDAV_URL not provided, skipping WebDAV recovery."
fi

# Fallback to GitHub recovery
if [ "${recovery_success}" = false ]; then
    echo "Falling back to GitHub repository recovery..."
    if [ -n "${GITHUB_REPO}" ] && [ -n "${G_TOKEN}" ]; then
        TMP_GIT_DIR=$(mktemp -d)
        REPO_URL="https://${G_TOKEN}@github.com/${GITHUB_REPO}.git"
        
        echo "Cloning repository..."
        if git clone --depth 1 "${REPO_URL}" "${TMP_GIT_DIR}" 2>/dev/null; then
            if [ -f "${TMP_GIT_DIR}/latest-backup.tar.gz" ]; then
                cp "${TMP_GIT_DIR}/latest-backup.tar.gz" "${BACKUP_FILE}"
                mkdir -p "${BACKUP_EXTRACT_DIR}"
                if tar -xzf "${BACKUP_FILE}" -C "${BACKUP_EXTRACT_DIR}"; then
                    echo "Successfully recovered and extracted backup from GitHub."
                    recovery_success=true
                else
                    echo "Failed to extract GitHub backup."
                fi
            else
                echo "latest-backup.tar.gz not found in GitHub repository."
            fi
        else
            echo "Failed to clone GitHub repository."
        fi
        rm -rf "${TMP_GIT_DIR}"
    else
        echo "GITHUB_REPO or G_TOKEN not provided, skipping GitHub recovery."
    fi
fi

if [ "${recovery_success}" = false ]; then
    echo "Warning: Initial recovery failed or was skipped. Starting fresh."
fi

LAST_DAILY_DATE=""

echo "Starting continuous sync loop..."

while true; do
    echo "[$(date -u)] Starting backup cycle..."
    
    # 1. Create backup using openclaw
    echo "Running 'openclaw backup create'..."
    if openclaw backup create --output "${BACKUP_FILE}" --no-include-workspace; then
        echo "Backup successfully created at ${BACKUP_FILE}."
        
        # 2. Sync latest backup to WebDAV
        if [ -n "${WEBDAV_URL}" ]; then
            echo "Uploading latest backup to WebDAV..."
            CURL_AUTH=""
            if [ -n "${WEBDAV_USER}" ] && [ -n "${WEBDAV_PASS}" ]; then
                CURL_AUTH="-u ${WEBDAV_USER}:${WEBDAV_PASS}"
            fi
            
            if curl -s -f ${CURL_AUTH} -T "${BACKUP_FILE}" "${WEBDAV_URL}/latest-backup.tar.gz"; then
                echo "Successfully uploaded latest backup to WebDAV."
            else
                echo "Failed to upload latest backup to WebDAV."
            fi
        fi
        
        # 3. Daily historical archive and GitHub sync
        # Check if current time is around midnight (00:xx UTC)
        CURRENT_HOUR=$(date -u +%H)
        CURRENT_DATE=$(date -u +%Y-%m-%d)
        
        if [ "${CURRENT_HOUR}" = "00" ] && [ "${LAST_DAILY_DATE}" != "${CURRENT_DATE}" ]; then
            echo "Performing daily historical backup for ${CURRENT_DATE}..."
            
            # Upload historical backup to WebDAV
            if [ -n "${WEBDAV_URL}" ]; then
                echo "Uploading historical daily backup to WebDAV..."
                if curl -s -f ${CURL_AUTH} -T "${BACKUP_FILE}" "${WEBDAV_URL}/backup-${CURRENT_DATE}.tar.gz"; then
                    echo "Successfully uploaded historical backup to WebDAV."
                else
                    echo "Failed to upload historical backup to WebDAV."
                fi
            fi
            
            # Commit and push to GitHub
            if [ -n "${GITHUB_REPO}" ] && [ -n "${G_TOKEN}" ]; then
                echo "Pushing latest backup to GitHub repository..."
                TMP_GIT_DIR=$(mktemp -d)
                REPO_URL="https://${G_TOKEN}@github.com/${GITHUB_REPO}.git"
                
                # Clone ignoring output to avoid leaking token
                if git clone --depth 1 "${REPO_URL}" "${TMP_GIT_DIR}" 2>/dev/null || git clone "${REPO_URL}" "${TMP_GIT_DIR}" 2>/dev/null; then
                    cp "${BACKUP_FILE}" "${TMP_GIT_DIR}/latest-backup.tar.gz"
                    
                    (
                        cd "${TMP_GIT_DIR}" || exit 1
                        git config user.name "OpenClaw Backup Bot"
                        git config user.email "bot@openclaw.ai"
                        
                        git add latest-backup.tar.gz
                        # If there are changes, commit and push
                        if ! git diff --staged --quiet; then
                            git commit -m "chore(backup): daily backup ${CURRENT_DATE}"
                            if git push origin HEAD:main 2>/dev/null || git push origin HEAD:master 2>/dev/null; then
                                echo "Successfully pushed daily backup to GitHub."
                            else
                                echo "Failed to push to GitHub."
                            fi
                        else
                            echo "No changes in latest-backup.tar.gz to push."
                        fi
                    )
                else
                    echo "Failed to clone GitHub repository for daily backup."
                fi
                rm -rf "${TMP_GIT_DIR}"
            fi
            
            LAST_DAILY_DATE="${CURRENT_DATE}"
        fi
    else
        echo "Error: 'openclaw backup create' failed."
    fi
    
    echo "Cycle complete. Sleeping for 3600 seconds..."
    sleep 3600
done
