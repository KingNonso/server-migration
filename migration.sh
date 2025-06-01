#!/bin/bash

# Server Migration Script - Run from Hetzner Cloud server
# Pulls files from Digital Ocean /root to local /root

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
SOURCE_SERVER=""       # Digital Ocean server IP/hostname
SSH_USER="root"        # Username for source server
SSH_KEY=""             # Path to SSH private key (optional)
DEST_PATH="/root"      # Local destination path
SOURCE_PATH="/root"    # Remote source path
LOG_FILE="migration_$(date +%Y%m%d_%H%M%S).log"
EXCLUDE_FILE="migration_exclude.txt"
BACKUP_EXISTING=true   # Backup existing files before migration

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# Function to check if source server is reachable
check_source_server() {
    log "Checking connectivity to source server ($SOURCE_SERVER)..."
    
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd="ssh -i $SSH_KEY -o ConnectTimeout=10 -o BatchMode=yes"
    else
        ssh_cmd="ssh -o ConnectTimeout=10 -o BatchMode=yes"
    fi
    
    if $ssh_cmd $SSH_USER@$SOURCE_SERVER "echo 'Connection successful'" &>/dev/null; then
        success "Source server is reachable"
        return 0
    else
        error "Source server is not reachable"
        echo "Please ensure:"
        echo "  1. SSH access is configured"
        echo "  2. Server IP/hostname is correct: $SOURCE_SERVER"
        echo "  3. SSH key is correct (if specified): $SSH_KEY"
        return 1
    fi
}

# Function to get disk space information
check_disk_space() {
    log "Checking disk space..."
    
    # Check local disk space
    local local_space=$(df -h $DEST_PATH | tail -1)
    log "Local (Hetzner) disk space: $local_space"
    
    # Check source disk space
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd="ssh -i $SSH_KEY"
    else
        ssh_cmd="ssh"
    fi
    
    local source_space=$($ssh_cmd $SSH_USER@$SOURCE_SERVER "df -h $SOURCE_PATH | tail -1")
    log "Source (DO) disk space: $source_space"
    
    # Get source directory size
    local source_size=$($ssh_cmd $SSH_USER@$SOURCE_SERVER "du -sh $SOURCE_PATH 2>/dev/null | cut -f1" || echo "Unknown")
    log "Source directory size: $source_size"
}

# Function to backup existing destination files
backup_existing_files() {
    if [[ "$BACKUP_EXISTING" == true && -d "$DEST_PATH" ]]; then
        local backup_dir="${DEST_PATH}_backup_$(date +%Y%m%d_%H%M%S)"
        log "Creating backup of existing files to: $backup_dir"
        
        if cp -r "$DEST_PATH" "$backup_dir" 2>/dev/null; then
            success "Backup created successfully"
        else
            warning "Failed to create backup, continuing anyway..."
        fi
    fi
}

# Function to create exclude file with common exclusions
create_exclude_file() {
    if [[ ! -f "$EXCLUDE_FILE" ]]; then
        log "Creating exclude file: $EXCLUDE_FILE"
        cat > "$EXCLUDE_FILE" << 'EOF'
# Temporary files
*.tmp
*.temp
tmp/
.tmp/

# Log files (uncomment if you don't want to transfer logs)
# *.log
# .log/

# Cache directories
.cache/
__pycache__/
*.pyc
.npm/
.yarn/
node_modules/

# SSH known_hosts (will be regenerated)
.ssh/known_hosts

# System files that shouldn't be copied
proc/
sys/
dev/
run/
mnt/
media/

# Docker files (handle separately if needed)
# .docker/

# Large database files (handle separately)
# *.sql
# mysql/
# postgresql/

# Editor temporary files
*.swp
*.swo
*~
.DS_Store

# Git repositories (uncomment if you want to exclude)
# .git/

# Logs and history files
.bash_history
.mysql_history
.lesshst
EOF
        warning "Created exclude file. Please review and modify $EXCLUDE_FILE as needed."
        echo ""
        echo "Current exclusions:"
        cat "$EXCLUDE_FILE" | grep -v "^#" | grep -v "^$" | head -10
        echo ""
        echo "Press Enter to continue or Ctrl+C to exit and modify the exclude file..."
        read -r
    else
        log "Using existing exclude file: $EXCLUDE_FILE"
    fi
}

# Function to perform rsync migration
migrate_with_rsync() {
    log "Starting migration with rsync..."
    
    local rsync_opts="-avzP --stats --human-readable --timeout=1800"
    
    if [[ -f "$EXCLUDE_FILE" ]]; then
        rsync_opts="$rsync_opts --exclude-from=$EXCLUDE_FILE"
    fi
    
    # Add SSH options if key is specified
    if [[ -n "$SSH_KEY" ]]; then
        rsync_opts="$rsync_opts -e 'ssh -i $SSH_KEY -o StrictHostKeyChecking=no'"
    else
        rsync_opts="$rsync_opts -e 'ssh -o StrictHostKeyChecking=no'"
    fi
    
    # Add deletion option (uncomment if you want to sync deletions)
    # rsync_opts="$rsync_opts --delete"
    
    # Add dry-run option for testing (uncomment to test first)
    # rsync_opts="$rsync_opts --dry-run"
    
    log "Rsync command: rsync $rsync_opts $SSH_USER@$SOURCE_SERVER:$SOURCE_PATH/ $DEST_PATH/"
    
    # Create destination directory if it doesn't exist
    mkdir -p "$DEST_PATH"
    
    if [[ -n "$SSH_KEY" ]]; then
        if rsync -avzP --stats --human-readable --timeout=1800 --exclude-from="$EXCLUDE_FILE" -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" "$SSH_USER@$SOURCE_SERVER:$SOURCE_PATH/" "$DEST_PATH/"; then
            success "Rsync migration completed successfully"
            return 0
        else
            error "Rsync migration failed"
            return 1
        fi
    else
        if rsync -avzP --stats --human-readable --timeout=1800 --exclude-from="$EXCLUDE_FILE" -e "ssh -o StrictHostKeyChecking=no" "$SSH_USER@$SOURCE_SERVER:$SOURCE_PATH/" "$DEST_PATH/"; then
            success "Rsync migration completed successfully"
            return 0
        else
            error "Rsync migration failed"
            return 1
        fi
    fi
}

# Function to create tar backup and transfer
migrate_with_tar() {
    log "Starting migration with tar method..."
    
    # Create temporary tar file on source server
    local tar_file="/tmp/root_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    local local_tar="/tmp/$(basename $tar_file)"
    
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd="ssh -i $SSH_KEY"
        scp_cmd="scp -i $SSH_KEY"
    else
        ssh_cmd="ssh"
        scp_cmd="scp"
    fi
    
    log "Creating tar archive on source server..."
    # Create exclude pattern for tar
    local tar_excludes="--exclude='proc/*' --exclude='sys/*' --exclude='dev/*' --exclude='run/*' --exclude='tmp/*' --exclude='mnt/*' --exclude='media/*'"
    
    if $ssh_cmd $SSH_USER@$SOURCE_SERVER "cd / && tar $tar_excludes -czf $tar_file root/"; then
        success "Tar archive created successfully on source server"
    else
        error "Failed to create tar archive on source server"
        return 1
    fi
    
    log "Transferring tar archive from source server..."
    if $scp_cmd $SSH_USER@$SOURCE_SERVER:$tar_file $local_tar; then
        success "Tar archive transferred successfully"
    else
        error "Failed to transfer tar archive"
        return 1
    fi
    
    log "Extracting tar archive locally..."
    if tar -xzf $local_tar -C / --strip-components=1; then
        success "Tar archive extracted successfully"
    else
        error "Failed to extract tar archive"
        return 1
    fi
    
    # Cleanup
    log "Cleaning up temporary files..."
    $ssh_cmd $SSH_USER@$SOURCE_SERVER "rm -f $tar_file" || warning "Failed to cleanup source server"
    rm -f $local_tar || warning "Failed to cleanup local tar file"
    
    success "Tar migration completed successfully"
}

# Function to verify migration
verify_migration() {
    log "Verifying migration..."
    
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd="ssh -i $SSH_KEY"
    else
        ssh_cmd="ssh"
    fi
    
    # Get file counts from both locations
    local source_count=$($ssh_cmd $SSH_USER@$SOURCE_SERVER "find $SOURCE_PATH -type f 2>/dev/null | wc -l" || echo "0")
    local dest_count=$(find $DEST_PATH -type f 2>/dev/null | wc -l || echo "0")
    
    log "Source server file count: $source_count"
    log "Destination file count: $dest_count"
    
    # Get directory sizes
    local source_size=$($ssh_cmd $SSH_USER@$SOURCE_SERVER "du -sh $SOURCE_PATH 2>/dev/null | cut -f1" || echo "Unknown")
    local dest_size=$(du -sh $DEST_PATH 2>/dev/null | cut -f1 || echo "Unknown")
    
    log "Source directory size: $source_size"
    log "Destination directory size: $dest_size"
    
    # Check if critical files exist
    log "Checking for critical files..."
    local critical_files=(".bashrc" ".profile" ".ssh/authorized_keys")
    
    for file in "${critical_files[@]}"; do
        if [[ -f "$DEST_PATH/$file" ]]; then
            success "Found: $file"
        else
            warning "Missing: $file"
        fi
    done
}

# Function to set proper permissions
fix_permissions() {
    log "Setting proper permissions for /root..."
    
    # Set /root directory permissions
    chmod 700 "$DEST_PATH" || warning "Failed to set permissions on $DEST_PATH"
    
    # Set SSH directory permissions if it exists
    if [[ -d "$DEST_PATH/.ssh" ]]; then
        chmod 700 "$DEST_PATH/.ssh"
        chmod 600 "$DEST_PATH/.ssh"/* 2>/dev/null || true
        success "SSH permissions set correctly"
    fi
    
    # Set proper ownership (since we're running as root)
    chown -R root:root "$DEST_PATH" || warning "Failed to set ownership"
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "This script should be run from the Hetzner Cloud server to pull files from Digital Ocean."
    echo ""
    echo "Options:"
    echo "  -s, --source SERVER      Digital Ocean server IP/hostname (required)"
    echo "  -k, --key PATH           Path to SSH private key (optional)"
    echo "  -m, --method METHOD      Migration method: rsync (default) or tar"
    echo "  -u, --user USER          SSH username for source server (default: root)"
    echo "  -p, --path PATH          Source path to copy from (default: /root)"
    echo "  -d, --dest PATH          Local destination path (default: /root)"
    echo "  --no-backup              Don't backup existing files"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -s 167.99.196.192"
    echo "  $0 -s do.example.com -k ~/.ssh/id_rsa -m rsync"
    echo "  $0 -s 192.168.1.100 -p /home/user -d /root/migrated"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--source)
            SOURCE_SERVER="$2"
            shift 2
            ;;
        -k|--key)
            SSH_KEY="$2"
            shift 2
            ;;
        -m|--method)
            METHOD="$2"
            shift 2
            ;;
        -u|--user)
            SSH_USER="$2"
            shift 2
            ;;
        -p|--path)
            SOURCE_PATH="$2"
            shift 2
            ;;
        -d|--dest)
            DEST_PATH="$2"
            shift 2
            ;;
        --no-backup)
            BACKUP_EXISTING=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    echo "======================================"
    echo "  Server Migration Script v2.0"
    echo "  Run from: Hetzner Cloud Server"
    echo "======================================"
    echo ""
    
    log "Starting server migration script"
    log "Source (DO): $SOURCE_SERVER:$SOURCE_PATH"
    log "Destination (Local): $DEST_PATH"
    log "SSH User: $SSH_USER"
    log "SSH Key: ${SSH_KEY:-'Not specified (using default SSH auth)'}"
    log "Log file: $LOG_FILE"
    log "Backup existing: $BACKUP_EXISTING"
    
    # Validate required parameters
    if [[ -z "$SOURCE_SERVER" ]]; then
        error "Source server is required. Use -s option."
        usage
        exit 1
    fi
    
    # Check SSH key exists if specified
    if [[ -n "$SSH_KEY" && ! -f "$SSH_KEY" ]]; then
        error "SSH key file not found: $SSH_KEY"
        exit 1
    fi
    
    # Check if we're running as root (recommended for /root migration)
    if [[ $EUID -ne 0 && "$DEST_PATH" == "/root" ]]; then
        warning "Not running as root. You may encounter permission issues."
        echo "Consider running with: sudo $0 $*"
        echo "Continue anyway? (yes/no)"
        read -r confirmation
        if [[ "$confirmation" != "yes" ]]; then
            exit 0
        fi
    fi
    
    # Check source server connectivity
    if ! check_source_server; then
        exit 1
    fi
    
    # Check disk space
    check_disk_space
    
    # Backup existing files if requested
    if [[ "$BACKUP_EXISTING" == true ]]; then
        backup_existing_files
    fi
    
    # Create exclude file
    create_exclude_file
    
    # Confirm before proceeding
    echo ""
    warning "This will copy files from $SOURCE_SERVER:$SOURCE_PATH to local $DEST_PATH"
    if [[ "$BACKUP_EXISTING" == true ]]; then
        echo "Existing files will be backed up first."
    fi
    echo ""
    echo "Are you sure you want to continue? (yes/no)"
    read -r confirmation
    
    if [[ "$confirmation" != "yes" ]]; then
        log "Migration cancelled by user"
        exit 0
    fi
    
    # Perform migration
    local method=${METHOD:-rsync}
    case $method in
        rsync)
            migrate_with_rsync
            ;;
        tar)
            migrate_with_tar
            ;;
        *)
            error "Unknown migration method: $method. Use 'rsync' or 'tar'"
            exit 1
            ;;
    esac
    
    # Fix permissions
    fix_permissions
    
    # Verify migration
    verify_migration
    
    echo ""
    echo "======================================"
    success "Migration completed successfully!"
    echo "======================================"
    log "Check the log file for details: $LOG_FILE"
    
    if [[ "$BACKUP_EXISTING" == true ]]; then
        echo ""
        echo "Note: Original files were backed up with timestamp."
        echo "You can remove backup directories once you've verified the migration."
    fi
}

# Run main function
main "$@"