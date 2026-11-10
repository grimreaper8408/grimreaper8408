#!/bin/bash
#############################################################################
# NAS Sync Backup Script
# Reads configuration from /etc/backup/nas-sync.yaml
# Has to be placed in /usr/local/bin/backup.sh
#############################################################################

set -euo pipefail

CONFIG_FILE="/etc/backup/nas-sync.yaml"
LOG_FILE="/home/raven/nas-backup.log"
LOCK_FILE="/tmp/nas-backup.lock"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

#############################################################################
# Variables & Initialization
#############################################################################

DRY_RUN=false
LOCK_FORCE=false
FAILED=0
TOTAL_JOBS=0

#############################################################################
# Helper Functions
#############################################################################

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo -e "$msg" | tee -a "$LOG_FILE"
}

status_ok() {
    echo -e "${GREEN}✓${NC} $1"
    log "[SUCCESS] $1"
}

status_error() {
    echo -e "${RED}✗${NC} $1"
    log "[ERROR] $1"
}

status_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    log "[WARN] $1"
}

usage() {
    cat <<EOF
Usage: $0 [--dry-run|--force]
  --dry-run  Preview changes without transferring
  --force    Continue even if lockfile exists (stale lock)
EOF
    exit 1
}

parse_yaml_value() {
    local key="$1"
    python3 -c "
import yaml
import sys

try:
    with open('${CONFIG_FILE}', 'r') as f:
        config = yaml.safe_load(f)
    parts = '${key}'.split('.')
    val = config
    for p in parts:
        val = val.get(p) if isinstance(val, dict) else None
        if val is None:
            print('')
            sys.exit(0)
    print(val if val else '')
except Exception as e:
    print('', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

get_backup_jobs() {
    python3 <<EOF
import yaml
import sys

try:
    with open('${CONFIG_FILE}', 'r') as f:
        config = yaml.safe_load(f)
    for job in config.get('backups', []):
        name = job.get('name', '').replace('\t', ' ')
        src = job.get('source', '').replace('\t', ' ')
        dst = job.get('destination', '').replace('\t', ' ')
        excludes = '|'.join(job.get('exclude', []))
        print(f"{name}\t{src}\t{dst}\t{excludes}")
except Exception as e:
    print(f"Error parsing config: {e}", file=sys.stderr)
    sys.exit(1)
EOF
}

run_backup_job() {
    local job_name="$1"
    local src="$2"
    local dest_base="$3"
    local exclude_patterns="$4"
    
    local conn_user conn_host
    conn_user=$(parse_yaml_value "connection.user")
    conn_host=$(parse_yaml_value "connection.host")
    
    # Verify source exists BEFORE attempting backup
    if [ ! -d "$src" ]; then
        status_error "Source directory does not exist: $src (${job_name})"
        return 1
    fi
    
    # Build rsync flags using array for safe quoting
    local rsync_flags=(-avz)
    rsync_flags+=(-e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new")
    
    # Apply delete option from config
    local del_opt
    del_opt=$(parse_yaml_value "connection.rsync_options.delete")
    if [ "$del_opt" = "true" ]; then
        rsync_flags+=(--delete)
    fi
    
    # Apply exclude patterns if any
    if [ -n "$exclude_patterns" ]; then
        for pattern in $(echo "$exclude_patterns" | tr '|' '\n'); do
            if [ -n "$pattern" ]; then
                rsync_flags+=(--exclude="$pattern")
            fi
        done
    fi

    # Add dry-run flag if requested
    if [ "$DRY_RUN" = "true" ]; then
        rsync_flags+=(--dry-run)
    fi
    
    local full_dest="${conn_user}@${conn_host}:${dest_base}"
    
    log "Backup: $job_name"
    log "  Source: $src"
    log "  Destination: $full_dest"
    log "  Flags: ${rsync_flags[*]}"
    
    # Safe rsync execution without eval
    local rsync_exit_code=0
    rsync "${rsync_flags[@]}" "$src/" "$full_dest/" >> "$LOG_FILE" 2>&1 || rsync_exit_code=$?
    
    # Exit code 23 = partial transfer (acceptable), 0 = success
    if [ "$rsync_exit_code" -eq 0 ] || [ "$rsync_exit_code" -eq 23 ]; then
        status_ok "$job_name completed (exit code: $rsync_exit_code)"
        return 0
    else
        status_error "$job_name FAILED (exit code: $rsync_exit_code)"
        tail -5 "$LOG_FILE" >&2
        return 1
    fi
}


#############################################################################
# GitLab Backup Hook
#############################################################################

trigger_gitlab_backup() {
    log "Triggering GitLab backup inside Docker container...(may take a while)"
    
    if docker exec gitlab gitlab-rake gitlab:backup:create STRATEGY=copy >> "$LOG_FILE" 2>&1; then
        status_ok "GitLab backup triggered successfully"
        sleep 5  # Give it a moment to write the file
        return 0
    else
        status_error "GitLab backup trigger failed"
        return 1
    fi
}
#############################################################################
# Validation Functions
#############################################################################

validate_config() {
    log "Validating configuration..."
    
    if [ ! -f "$CONFIG_FILE" ]; then
        status_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    if ! command -v python3 >/dev/null 2>&1; then
        status_error "python3 not installed"
        exit 1
    fi
    
    if ! python3 -c "import yaml" >/dev/null 2>&1; then
        status_error "PyYAML not installed. Run: pip3 install pyyaml"
        exit 1
    fi
    
    # Validate connection settings
    local conn_user conn_host conn_ssh_key
    conn_user=$(parse_yaml_value "connection.user")
    conn_host=$(parse_yaml_value "connection.host")
    conn_ssh_key=$(parse_yaml_value "connection.ssh_key")
    
    if [ -z "$conn_user" ] || [ -z "$conn_host" ] || [ -z "$conn_ssh_key" ]; then
        status_error "Missing required connection settings in config"
        exit 1
    fi
    
    # Resolve SSH key path and validate existence + permissions
    SSH_KEY="${conn_ssh_key/#\~/$HOME}"
    SSH_KEY="${SSH_KEY:-$HOME/$conn_ssh_key}"
    
    if [ ! -f "$SSH_KEY" ]; then
        status_error "SSH key not found: $SSH_KEY"
        exit 1
    fi
    
    local key_perms
    key_perms=$(stat -c '%a' "$SSH_KEY" 2>/dev/null || stat -f '%OLp' "$SSH_KEY" 2>/dev/null | tail -c 4)
    if [ "$key_perms" != "600" ]; then
        status_warn "SSH key has insecure permissions ($key_perms). Recommended: 600"
    fi
    
    status_ok "Configuration validated"
}

check_ssh_connectivity() {
    local conn_user conn_host
    conn_user=$(parse_yaml_value "connection.user")
    conn_host=$(parse_yaml_value "connection.host")
    
    log "Testing SSH connectivity to ${conn_host}..."
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
         "${conn_user}@${conn_host}" "echo OK" 2>/dev/null | grep -q "OK"; then
        status_ok "SSH connection successful"
    else
        status_error "SSH connection failed. Verify key and authorized_keys"
        exit 1
    fi
}

#############################################################################
# Main Entry Point
#############################################################################

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --force) LOCK_FORCE=true; shift ;;
        *) usage ;;
    esac
done

# Initialize lock_force if not set
LOCK_FORCE="${LOCK_FORCE:=false}"

# Prevent concurrent runs (corrected logic)
exec 200>"$LOCK_FILE" && flock -n 200 || { status_error "Another backup is running"; exit 1; }
trap 'rm -f "$LOCK_FILE"' EXIT

log "=========================================="
log "NAS Sync Backup Starting"
[[ "$DRY_RUN" = "true" ]] && log "MODE: DRY-RUN (no files will be transferred)"
log "=========================================="

# Validation phase
validate_config
check_ssh_connectivity

# Trigger GitLab backup before syncing (skip in dry-run mode)
if [ "$DRY_RUN" = "false" ]; then
    trigger_gitlab_backup || log "Warning: GitLab backup trigger skipped - will sync existing files anyway"
fi

# Get backup jobs and count them
JOB_OUTPUT=$(get_backup_jobs)
if [ -z "$JOB_OUTPUT" ]; then
    status_error "No backup jobs defined in configuration or invalid YAML"
    exit 1
fi

# Count total jobs (lines in JOB_OUTPUT)
TOTAL_JOBS=$(echo "$JOB_OUTPUT" | grep -c . || echo 0)

# Execute each backup job
while IFS=$'\t' read -r name src dest excludes; do
    # Skip empty lines
    [ -z "$name" ] && continue

    log "---"
    if ! run_backup_job "$name" "$src" "$dest" "$excludes"; then
	   FAILED=$((FAILED + 1))
    fi
done < <(echo "$JOB_OUTPUT")

# Calculate success count
SUCCESS=$((TOTAL_JOBS - FAILED))

log "=========================================="
log "SUMMARY"
log "Total jobs: $TOTAL_JOBS"
log "Successful: $SUCCESS"
log "Failed: $FAILED"
if [ "$FAILED" -eq 0 ]; then
    status_ok "All backup jobs completed successfully"
else
    status_error "$FAILED out of $TOTAL_JOBS jobs failed"
fi
log "=========================================="

exit $FAILED

# script was made with aid of the LLM Lumo.proton.me


