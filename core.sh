#!/bin/bash

# =============================================================================
# ROBUST SERVER MIGRATION SCRIPT - Digital Ocean to Hetzner Cloud
# =============================================================================
# This script migrates nginx, uwsgi, django, nextjs configs, cron jobs, 
# docker containers, volumes, and application files from source to destination
# Run this script from the DESTINATION (Hetzner) server
# =============================================================================

# Don't exit on errors, we'll handle them gracefully
set +e

# Track migration status
MIGRATION_STATUS="success"
STEP_FAILURES=0

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions with file output
log() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${GREEN}$message${NC}"
    echo "$message" >> "$LOG_FILE"
}

error() {
    local message="[ERROR] $1"
    echo -e "${RED}$message${NC}" >&2
    echo "$message" >> "$LOG_FILE"
    MIGRATION_STATUS="failed"
    ((STEP_FAILURES++))
}

warning() {
    local message="[WARNING] $1"
    echo -e "${YELLOW}$message${NC}"
    echo "$message" >> "$LOG_FILE"
}

info() {
    local message="[INFO] $1"
    echo -e "${BLUE}$message${NC}"
    echo "$message" >> "$LOG_FILE"
}



# Total number of steps in the migration process
TOTAL_STEPS=8
CURRENT_STEP=0

# Function to display step progress header
display_step_header() {
    local step_name=$1
    local step_description=$2
    ((CURRENT_STEP++))
    
    # Create a header with step number and description
    echo
    echo "============================================================================="
    echo -e "${GREEN}STEP $CURRENT_STEP/$TOTAL_STEPS: ${YELLOW}$step_description${NC}"
    echo "============================================================================="
    echo
    
    # Log the step start
    log "Starting step $CURRENT_STEP/$TOTAL_STEPS: $step_name - $step_description"
}

# Function to display step completion footer
display_step_footer() {
    local step_name=$1
    local duration=$2
    local status=$3
    
    # Create a footer with completion status
    echo
    echo "-----------------------------------------------------------------------------"
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN}✓ COMPLETED: Step $CURRENT_STEP/$TOTAL_STEPS ($step_name) - Took ${duration}s${NC}"
    else
        echo -e "${RED}✗ FAILED: Step $CURRENT_STEP/$TOTAL_STEPS ($step_name) - Took ${duration}s${NC}"
    fi
    echo "-----------------------------------------------------------------------------"
    echo
}

# Function to run a step with error handling and progress display
run_step() {
    local step_name=$1
    local step_function=$2
    local step_description=$3
    
    # Display step header
    display_step_header "$step_name" "$step_description"
    
    # Run the step function
    local start_time=$(date +%s)
    local step_result=0
    
    # Capture output and errors
    local output_file="$DEST_BASE_DIR/${step_name}_output.log"
    $step_function > "$output_file" 2>&1 || step_result=$?
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [[ $step_result -eq 0 ]]; then
        log "Step completed successfully: $step_name (took ${duration}s)"
        display_step_footer "$step_name" "$duration" "success"
    else
        error "Step failed: $step_name (took ${duration}s, exit code: $step_result)"
        error "See log file for details: $output_file"
        display_step_footer "$step_name" "$duration" "failed"
        
        # Show last few lines of error output
        echo -e "${RED}Last 10 lines of error output:${NC}"
        tail -n 10 "$output_file"
        echo
        
        # Ask if we should continue
        read -p "Continue with migration despite error? (Y/n): " continue_choice
        if [[ "$continue_choice" =~ ^[Nn]$ ]]; then
            error "Migration aborted by user"
            exit 1
        fi
    fi
    
    return $step_result
}

# =============================================================================
# CONFIGURATION SECTION
# =============================================================================

# Source server details (Digital Ocean)
SOURCE_HOST="178.128.169.33"
SOURCE_USER="root"
SOURCE_PORT="22"

# Destination paths (current server - Hetzner)
DEST_BASE_DIR="/opt/migration"
BACKUP_DIR="/opt/migration/backup"
LOG_FILE="/var/log/migration.log"

# Migration flags
MIGRATE_NGINX=true
MIGRATE_UWSGI=true
MIGRATE_DJANGO=true
MIGRATE_NEXTJS=true
MIGRATE_CRON=true
MIGRATE_DOCKER=true
MIGRATE_FILES=true

# Common paths to check for configurations
NGINX_PATHS=("/etc/nginx" "/usr/local/nginx" "/opt/nginx")
UWSGI_PATHS=("/etc/uwsgi" "/opt/uwsgi" "/usr/local/etc/uwsgi")
CRON_PATHS=("/var/spool/cron" "/etc/cron.d" "/etc/crontab")
DOCKER_PATHS=("/var/lib/docker" "/opt/docker")

# Application paths (will be auto-detected)
DJANGO_PATHS=("/var/www" "/opt" "/home" "/srv")
NEXTJS_PATHS=("/var/www" "/opt" "/home" "/srv")

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        warning "This script should ideally be run as root"
        warning "Some operations may fail without root privileges"
        read -p "Continue anyway? (y/N): " continue_choice
        if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
            error "Aborted by user due to insufficient privileges"
            return 1
        fi
    fi
    
    # Check required commands and install missing ones if possible
    local required_commands=("ssh" "scp" "rsync" "docker" "systemctl" "tar" "gzip" "jq")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        warning "Missing required commands: ${missing_commands[*]}"
        warning "Attempting to install missing packages..."
        
        # Try to detect package manager and install
        if command -v apt-get &> /dev/null; then
            apt-get update
            apt-get install -y ${missing_commands[*]}
        elif command -v yum &> /dev/null; then
            yum install -y ${missing_commands[*]}
        elif command -v dnf &> /dev/null; then
            dnf install -y ${missing_commands[*]}
        else
            error "Could not install missing packages. Please install manually: ${missing_commands[*]}"
            read -p "Continue anyway? (y/N): " continue_choice
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
    fi
    
    # Check for required services and install if missing
    log "Checking for required services..."
    local required_services=("nginx" "uwsgi" "docker")
    local missing_services=()
    
    for service in "${required_services[@]}"; do
        if ! systemctl list-unit-files | grep -q "$service"; then
            missing_services+=("$service")
        fi
    done
    
    if [[ ${#missing_services[@]} -gt 0 ]]; then
        warning "Missing required services: ${missing_services[*]}"
        warning "Attempting to install missing services..."
        
        # Try to detect package manager and install
        if command -v apt-get &> /dev/null; then
            apt-get update
            for service in "${missing_services[@]}"; do
                case "$service" in
                    nginx)
                        apt-get install -y nginx
                        ;;
                    uwsgi)
                        apt-get install -y uwsgi uwsgi-plugin-python3
                        ;;
                    docker)
                        # Install Docker using the official method
                        apt-get install -y ca-certificates curl gnupg
                        install -m 0755 -d /etc/apt/keyrings
                        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
                          gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                        chmod a+r /etc/apt/keyrings/docker.gpg
                        
                        echo \
                          "deb [arch=$(dpkg --print-architecture) \
                          signed-by=/etc/apt/keyrings/docker.gpg] \
                          https://download.docker.com/linux/ubuntu \
                          $(lsb_release -cs) stable" | \
                          tee /etc/apt/sources.list.d/docker.list > /dev/null
                        
                        apt-get update
                        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                        
                        # Test Docker installation
                        if docker --version && docker compose version; then
                            log "Docker installed successfully"
                        else
                            warning "Docker installation may have issues. Please check manually."
                        fi
                        ;;
                esac
            done
        elif command -v yum &> /dev/null; then
            for service in "${missing_services[@]}"; do
                case "$service" in
                    nginx)
                        yum install -y nginx
                        ;;
                    uwsgi)
                        yum install -y uwsgi uwsgi-plugin-python3
                        ;;
                    docker)
                        yum install -y docker docker-compose
                        ;;
                esac
            done
        elif command -v dnf &> /dev/null; then
            for service in "${missing_services[@]}"; do
                case "$service" in
                    nginx)
                        dnf install -y nginx
                        ;;
                    uwsgi)
                        dnf install -y uwsgi uwsgi-plugin-python3
                        ;;
                    docker)
                        dnf install -y docker docker-compose
                        ;;
                esac
            done
        else
            error "Could not install missing services. Please install manually: ${missing_services[*]}"
            read -p "Continue anyway? (y/N): " continue_choice
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
    fi
    
    # Create directories with error handling
    mkdir -p "$DEST_BASE_DIR" 2>/dev/null || {
        error "Failed to create directory: $DEST_BASE_DIR"
        warning "Attempting to create with sudo..."
        sudo mkdir -p "$DEST_BASE_DIR" 2>/dev/null || {
            error "Failed to create directory even with sudo. Please check permissions."
            return 1
        }
    }
    
    mkdir -p "$BACKUP_DIR" 2>/dev/null || {
        error "Failed to create directory: $BACKUP_DIR"
        warning "Attempting to create with sudo..."
        sudo mkdir -p "$BACKUP_DIR" 2>/dev/null || {
            error "Failed to create directory even with sudo. Please check permissions."
            return 1
        }
    }
    
    # Check SSH agent
    if ! ssh-add -l &>/dev/null; then
        warning "SSH agent doesn't appear to be running or has no keys"
        warning "You may need to run 'eval $(ssh-agent)' and 'ssh-add' to add your keys"
    fi
    
    log "Prerequisites check completed"
    return 0
}



test_ssh_connection() {
    log "Testing SSH connection to source server..."
    
    # Simple direct connection test
    if ssh -o ConnectTimeout=10 "$SOURCE_USER@$SOURCE_HOST" -p "$SOURCE_PORT" "echo 'SSH connection successful'" &>/dev/null; then
        log "SSH connection established successfully"
        return 0
    else
        warning "Could not connect to $SOURCE_USER@$SOURCE_HOST:$SOURCE_PORT"
        warning "Make sure SSH key is added to ssh-agent or the server accepts password authentication"
    
        # Provide troubleshooting tips
        error "Failed to connect to source server. Please check:"
        error "- SSH key is added to your ssh-agent (run 'ssh-add')"
        error "- Network connectivity to $SOURCE_HOST"
        error "- Firewall settings"
        error "- The server is online and SSH service is running"
        
        read -p "Skip SSH connection check and continue anyway? (y/N): " continue_choice
        if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
            return 1
        fi
        warning "Continuing without verified SSH connection"
    fi
    
    return 0
}

execute_remote_command() {
    local command="$1"
    local max_retries=3
    local retry_count=0
    local result=
    local exit_code=1
    
    while [[ $retry_count -lt $max_retries && $exit_code -ne 0 ]]; do
        # Simple direct SSH command execution
        result=$(ssh -p "$SOURCE_PORT" "$SOURCE_USER@$SOURCE_HOST" "$command" 2>&1)
        exit_code=$?
        
        if [[ $exit_code -ne 0 ]]; then
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                warning "Command failed, retrying ($retry_count/$max_retries)..."
                sleep 2
            fi
        fi
    done
    
    if [[ $exit_code -ne 0 ]]; then
        warning "Remote command failed after $max_retries attempts: $command"
        warning "Error: $result"
    fi
    
    echo "$result"
    return $exit_code
}

# Function to perform rsync migration with progress display
migrate_with_rsync() {
    local source_path=$1
    local dest_path=$2
    local exclude_patterns=$3
    local delete_flag=$4
    local description=$5
    
    log "Starting migration of $description..."
    
    # Base rsync options for good performance and progress display
    local rsync_opts="-avzP --stats --human-readable --timeout=1800"
    
    # Add exclude patterns if provided
    if [[ -n "$exclude_patterns" ]]; then
        for pattern in $exclude_patterns; do
            rsync_opts="$rsync_opts --exclude='$pattern'"
        done
    fi
    
    # Add SSH options
    rsync_opts="$rsync_opts -e 'ssh -p $SOURCE_PORT -o StrictHostKeyChecking=no'"
    
    # Add deletion option if specified
    if [[ "$delete_flag" == "true" ]]; then
        rsync_opts="$rsync_opts --delete"
    fi
    
    # Create destination directory if it doesn't exist
    mkdir -p "$dest_path"
    
    # Log the rsync command
    info "Rsync command: rsync $rsync_opts $SOURCE_USER@$SOURCE_HOST:$source_path/ $dest_path/"
    
    # Execute the rsync command
    if eval rsync $rsync_opts "$SOURCE_USER@$SOURCE_HOST:$source_path/" "$dest_path/"; then
        log "$description migration completed successfully"
        return 0
    else
        error "$description migration failed"
        return 1
    fi
}

# =============================================================================
# BACKUP FUNCTIONS
# =============================================================================

create_backup() {
    log "Creating backup of existing configurations..."
    
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/pre_migration_backup_$backup_timestamp.tar.gz"
    
    # Backup existing configs
    tar -czf "$backup_file" \
        /etc/nginx 2>/dev/null || true \
        /etc/uwsgi 2>/dev/null || true \
        /etc/cron* 2>/dev/null || true \
        /var/spool/cron 2>/dev/null || true
    
    log "Backup created: $backup_file"
}

# =============================================================================
# DISCOVERY FUNCTIONS
# =============================================================================

discover_applications() {
    log "Discovering applications on source server..."
    
    # Find Django applications
    local django_apps=$(execute_remote_command "
        find /var/www /opt /home /srv -name 'manage.py' -type f 2>/dev/null | head -20 || true
    ")
    
    # Find Next.js applications
    local nextjs_apps=$(execute_remote_command "
        find /var/www /opt /home /srv -name 'package.json' -type f -exec grep -l 'next' {} \; 2>/dev/null | head -20 || true
    ")
    
    # Find Docker Compose files
    local docker_compose_files=$(execute_remote_command "
        find /var/www /opt /home /srv -name 'docker-compose.yml' -o -name 'docker-compose.yaml' 2>/dev/null | head -20 || true
    ")
    
    echo "$django_apps" > "$DEST_BASE_DIR/discovered_django_apps.txt"
    echo "$nextjs_apps" > "$DEST_BASE_DIR/discovered_nextjs_apps.txt"
    echo "$docker_compose_files" > "$DEST_BASE_DIR/discovered_docker_compose.txt"
    
    info "Discovered applications saved to $DEST_BASE_DIR/discovered_*.txt"
}

# =============================================================================
# MIGRATION FUNCTIONS
# =============================================================================

migrate_nginx() {
    if [[ "$MIGRATE_NGINX" != "true" ]]; then
        return 0
    fi
    
    log "Migrating Nginx configurations..."
    
    # Check if nginx is installed, install if missing
    if ! command -v nginx &>/dev/null; then
        warning "Nginx not found. Installing..."
        if command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y nginx
        elif command -v yum &>/dev/null; then
            yum install -y nginx
        elif command -v dnf &>/dev/null; then
            dnf install -y nginx
        else
            error "Could not install nginx. Please install manually."
            return 1
        fi
    fi
    
    # Stop nginx if running
    systemctl stop nginx 2>/dev/null || true
    
    # Create nginx backup
    if [[ -d /etc/nginx ]]; then
        cp -r /etc/nginx /etc/nginx.backup.$(date +%Y%m%d_%H%M%S)
    fi
    
    # Ensure nginx directory exists with proper permissions
    if [[ ! -d /etc/nginx ]]; then
        mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled
        chmod 755 /etc/nginx /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled
    fi
    
    # Sync nginx configurations
    migrate_with_rsync "/etc/nginx" "/etc/nginx" "" "true" "Nginx configuration"
    
    # Set proper permissions
    chmod 644 /etc/nginx/*.conf 2>/dev/null || true
    chmod 644 /etc/nginx/conf.d/*.conf 2>/dev/null || true
    chmod 644 /etc/nginx/sites-available/* 2>/dev/null || true
    chmod 755 /etc/nginx/sites-enabled 2>/dev/null || true
    
    # Check for custom nginx installations
    for path in "${NGINX_PATHS[@]}"; do
        if execute_remote_command "test -d $path" 2>/dev/null; then
            info "Found nginx installation at $path"
            # Create destination directory if it doesn't exist
            mkdir -p "$DEST_BASE_DIR/nginx_custom$path/"
            migrate_with_rsync "$path" "$DEST_BASE_DIR/nginx_custom$path" "" "false" "Custom Nginx from $path"
        fi
    done
    
    # Test nginx configuration
    if nginx -t; then
        log "Nginx configuration is valid"
        systemctl enable nginx
        systemctl start nginx
    else
        error "Nginx configuration is invalid. Please check manually."
        systemctl stop nginx
    fi
}

migrate_uwsgi() {
    if [[ "$MIGRATE_UWSGI" != "true" ]]; then
        return 0
    fi
    
    log "Migrating uWSGI configurations..."
    
    # Check if uwsgi is installed, install if missing
    if ! command -v uwsgi &>/dev/null; then
        warning "uWSGI not found. Installing..."
        if command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y uwsgi uwsgi-plugin-python3
        elif command -v yum &>/dev/null; then
            yum install -y uwsgi uwsgi-plugin-python3
        elif command -v dnf &>/dev/null; then
            dnf install -y uwsgi uwsgi-plugin-python3
        else
            error "Could not install uWSGI. Please install manually."
            return 1
        fi
    fi
    
    # Stop uwsgi services
    systemctl stop uwsgi* 2>/dev/null || true
    
    # Sync uwsgi configurations
    for path in "${UWSGI_PATHS[@]}"; do
        if execute_remote_command "test -d $path" 2>/dev/null; then
            info "Syncing uWSGI config from $path"
            # Create destination directory if it doesn't exist
            mkdir -p "$path"
            chmod 755 "$path"
            
            migrate_with_rsync "$path" "$path" "" "false" "uWSGI configuration from $path"
                
            # Set proper permissions for uwsgi config files
            find "$path" -type f -name "*.ini" -exec chmod 644 {} \; 2>/dev/null || true
        fi
    done
    
    # Ensure systemd directory exists
    mkdir -p /etc/systemd/system
    chmod 755 /etc/systemd/system
    
    # Sync systemd service files
    # First create a temporary directory to handle the wildcard
    local temp_dir="$DEST_BASE_DIR/temp_uwsgi_services"
    mkdir -p "$temp_dir"
    
    # Get a list of uwsgi service files
    local service_files=$(execute_remote_command "ls -1 /etc/systemd/system/*uwsgi* 2>/dev/null || echo ''")
    
    if [[ -n "$service_files" ]]; then
        # For each service file, copy it individually
        for service_file in $service_files; do
            local service_name=$(basename "$service_file")
            migrate_with_rsync "$service_file" "/etc/systemd/system/$service_name" "" "false" "uWSGI service file $service_name"
        done
    else
        warning "No uWSGI service files found on source server"
    fi
        
    # Set proper permissions for service files
    chmod 644 /etc/systemd/system/*uwsgi* 2>/dev/null || true
    
    systemctl daemon-reload
    
    # Enable and start uwsgi services
    for service in $(systemctl list-unit-files | grep uwsgi | awk '{print $1}'); do
        systemctl enable "$service" 2>/dev/null || true
        systemctl start "$service" 2>/dev/null || true
    done
}

migrate_cron_jobs() {
    if [[ "$MIGRATE_CRON" != "true" ]]; then
        return 0
    fi
    
    log "Migrating cron jobs..."
    
    # Check if cron service is installed
    if ! command -v crontab &>/dev/null; then
        warning "Cron not found. Installing..."
        if command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y cron
        elif command -v yum &>/dev/null; then
            yum install -y cronie
        elif command -v dnf &>/dev/null; then
            dnf install -y cronie
        else
            error "Could not install cron. Please install manually."
            return 1
        fi
    fi
    
    # Backup existing cron
    crontab -l > "$BACKUP_DIR/current_crontab.bak" 2>/dev/null || true
    
    # Get and apply root crontab
    execute_remote_command "crontab -l" 2>/dev/null | crontab - || true
    
    # Sync cron directories
    for path in "${CRON_PATHS[@]}"; do
        if execute_remote_command "test -d $path" 2>/dev/null; then
            # Create destination directory if it doesn't exist
            mkdir -p "$path"
            chmod 755 "$path"
            
            migrate_with_rsync "$path" "$path" "" "false" "Cron configuration from $path"
                
            # Set proper permissions for cron files
            if [[ "$path" == "/etc/cron.d" || "$path" == "/etc/crontab" ]]; then
                find "$path" -type f -exec chmod 644 {} \; 2>/dev/null || true
            elif [[ "$path" == "/var/spool/cron" ]]; then
                find "$path" -type f -exec chmod 600 {} \; 2>/dev/null || true
            fi
        fi
    done
    
    # Get user crontabs
    local users=$(execute_remote_command "cut -d: -f1 /etc/passwd" | grep -E '^(www-data|nginx|ubuntu|deploy)$' || true)
    for user in $users; do
        local user_cron=$(execute_remote_command "crontab -u $user -l" 2>/dev/null || true)
        if [[ -n "$user_cron" ]]; then
            echo "$user_cron" | crontab -u "$user" - 2>/dev/null || true
        fi
    done
    
    # Restart cron service
    systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true
}

migrate_docker() {
    if [[ "$MIGRATE_DOCKER" != "true" ]]; then
        return 0
    fi
    
    log "Migrating Docker configurations and images..."
    
    # Check if Docker is installed
    if ! command -v docker &>/dev/null; then
        warning "Docker not found. Installing..."
        if command -v apt-get &>/dev/null; then
            # Install Docker using the official method
            apt-get install -y ca-certificates curl gnupg
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
              gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
            
            echo \
              "deb [arch=$(dpkg --print-architecture) \
              signed-by=/etc/apt/keyrings/docker.gpg] \
              https://download.docker.com/linux/ubuntu \
              $(lsb_release -cs) stable" | \
              tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            
            # Test Docker installation
            if docker --version && docker compose version; then
                log "Docker installed successfully"
            else
                warning "Docker installation may have issues. Please check manually."
            fi
        elif command -v yum &>/dev/null; then
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        elif command -v dnf &>/dev/null; then
            dnf -y install dnf-plugins-core
            dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        else
            error "Could not install Docker. Please install manually."
            return 1
        fi
        
        # Start and enable Docker service
        systemctl start docker
        systemctl enable docker
    fi
    
    # Stop all containers
    docker stop $(docker ps -aq) 2>/dev/null || true
    
    # Get list of images from source
    local images=$(execute_remote_command "docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>'" 2>/dev/null || true)
    
    # Create Docker directories
    mkdir -p /opt/docker
    chmod 755 /opt/docker
    
    # Export and transfer images
    for image in $images; do
        if [[ "$image" != *"<none>"* ]]; then
            info "Transferring Docker image: $image"
            local image_file=$(echo "$image" | tr '/:' '_')
            
            # Export image on source
            execute_remote_command "docker save '$image' | gzip" > "$DEST_BASE_DIR/${image_file}.tar.gz"
            
            # Import image on destination
            gunzip -c "$DEST_BASE_DIR/${image_file}.tar.gz" | docker load
            
            # Clean up
            rm "$DEST_BASE_DIR/${image_file}.tar.gz"
        fi
    done
    
    # Sync docker-compose files
    mkdir -p /opt/docker
    chmod 755 /opt/docker
    migrate_with_rsync "/opt/docker" "/opt/docker" "" "false" "Docker compose files"
    
    # Find and sync all docker-compose files
    while IFS= read -r compose_file; do
        if [[ -n "$compose_file" ]]; then
            local dest_dir=$(dirname "$compose_file")
            mkdir -p "$dest_dir"
            chmod 755 "$dest_dir"
            # For individual compose files, we need to handle the directory structure
            local compose_dir=$(dirname "$compose_file")
            migrate_with_rsync "$compose_file" "$compose_file" "" "false" "Docker compose file $compose_file"
            # Set proper permissions for docker-compose files
            chmod 644 "$compose_file" 2>/dev/null || true
        fi
    done < "$DEST_BASE_DIR/discovered_docker_compose.txt"
    
    # Sync volumes (this is complex, handle carefully)
    local volumes=$(execute_remote_command "docker volume ls -q" 2>/dev/null || true)
    for volume in $volumes; do
        info "Backing up volume: $volume"
        execute_remote_command "docker run --rm -v $volume:/data -v /tmp:/backup alpine tar czf /backup/$volume.tar.gz -C /data ." 2>/dev/null || true
        
        # Use rsync instead of scp for better progress reporting
        migrate_with_rsync "/tmp/$volume.tar.gz" "$DEST_BASE_DIR/$volume.tar.gz" "" "false" "Docker volume $volume"
        
        # Create volume and restore
        docker volume create "$volume" 2>/dev/null || true
        docker run --rm -v "$volume":/data -v "$DEST_BASE_DIR":/backup alpine \
            tar xzf "/backup/$volume.tar.gz" -C /data 2>/dev/null || true
        
        # Cleanup
        execute_remote_command "rm /tmp/$volume.tar.gz" 2>/dev/null || true
        rm "$DEST_BASE_DIR/$volume.tar.gz" 2>/dev/null || true
    done
}

migrate_applications() {
    if [[ "$MIGRATE_DJANGO" != "true" && "$MIGRATE_NEXTJS" != "true" ]]; then
        return 0
    fi
    
    log "Migrating application files..."
    
    # Migrate Django applications
    if [[ "$MIGRATE_DJANGO" == "true" ]]; then
        # Check if Python is installed
        if ! command -v python3 &>/dev/null; then
            warning "Python3 not found. Installing..."
            if command -v apt-get &>/dev/null; then
                apt-get update && apt-get install -y python3 python3-pip python3-venv
            elif command -v yum &>/dev/null; then
                yum install -y python3 python3-pip
            elif command -v dnf &>/dev/null; then
                dnf install -y python3 python3-pip
            else
                error "Could not install Python3. Please install manually."
            fi
        fi
        
        while IFS= read -r django_app; do
            if [[ -n "$django_app" ]]; then
                local app_dir=$(dirname "$django_app")
                info "Migrating Django app: $app_dir"
                
                # Create directory with proper permissions
                mkdir -p "$app_dir"
                
                migrate_with_rsync "$app_dir" "$app_dir" "*.pyc __pycache__ .git" "false" "Django application $app_dir" || warning "Failed to sync $app_dir"
                
                # Set proper permissions
                if [[ "$app_dir" == /var/www/* ]]; then
                    chown -R www-data:www-data "$app_dir"
                    find "$app_dir" -type d -exec chmod 755 {} \;
                    find "$app_dir" -type f -exec chmod 644 {} \;
                    # Make manage.py executable
                    chmod +x "$app_dir/manage.py" 2>/dev/null || true
                fi
                
                # Sync related configs
                local app_name=$(basename "$app_dir")
                mkdir -p /etc/systemd/system
                # Get a list of service files for this app
                local service_files=$(execute_remote_command "ls -1 /etc/systemd/system/*$app_name* 2>/dev/null || echo ''")
                
                if [[ -n "$service_files" ]]; then
                    # For each service file, copy it individually
                    for service_file in $service_files; do
                        local service_name=$(basename "$service_file")
                        migrate_with_rsync "$service_file" "/etc/systemd/system/$service_name" "" "false" "Service file for $app_name"
                    done
                fi
                    
                # Set proper permissions for service files
                chmod 644 /etc/systemd/system/*$app_name* 2>/dev/null || true
            fi
        done < "$DEST_BASE_DIR/discovered_django_apps.txt"
    fi
    
    # Migrate Next.js applications
    if [[ "$MIGRATE_NEXTJS" == "true" ]]; then
        # Check if Node.js is installed
        if ! command -v node &>/dev/null; then
            warning "Node.js not found. Installing..."
            if command -v apt-get &>/dev/null; then
                curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
                apt-get install -y nodejs
            elif command -v yum &>/dev/null; then
                curl -fsSL https://rpm.nodesource.com/setup_16.x | bash -
                yum install -y nodejs
            elif command -v dnf &>/dev/null; then
                curl -fsSL https://rpm.nodesource.com/setup_16.x | bash -
                dnf install -y nodejs
            else
                error "Could not install Node.js. Please install manually."
            fi
        fi
        
        while IFS= read -r nextjs_app; do
            if [[ -n "$nextjs_app" ]]; then
                local app_dir=$(dirname "$nextjs_app")
                info "Migrating Next.js app: $app_dir"
                
                # Create directory with proper permissions
                mkdir -p "$app_dir"
                
                migrate_with_rsync "$app_dir" "$app_dir" "node_modules .next .git" "false" "Next.js application $app_dir" || warning "Failed to sync $app_dir"
                
                # Set proper permissions
                if [[ "$app_dir" == /var/www/* ]]; then
                    chown -R www-data:www-data "$app_dir"
                    find "$app_dir" -type d -exec chmod 755 {} \;
                    find "$app_dir" -type f -exec chmod 644 {} \;
                fi
                
                # Install dependencies
                if [[ -f "$app_dir/package.json" ]]; then
                    cd "$app_dir"
                    npm install 2>/dev/null || yarn install 2>/dev/null || true
                    npm run build 2>/dev/null || yarn build 2>/dev/null || true
                fi
            fi
        done < "$DEST_BASE_DIR/discovered_nextjs_apps.txt"
    fi
}


migrate_system_configs() {
    log "Migrating system configurations..."
    
    # Ensure directories exist with proper permissions
    mkdir -p /opt /var/www /etc/systemd/system
    chmod 755 /opt /var/www /etc/systemd/system
    
    # Environment files
    for env_file in ".env" ".env.local" ".env.production"; do
        # For env files, we need to handle them differently since they use wildcards
        # Get a list of matching env files in /opt
        local opt_env_files=$(execute_remote_command "find /opt -name '$env_file' -type f 2>/dev/null || echo ''")
        
        if [[ -n "$opt_env_files" ]]; then
            for env_path in $opt_env_files; do
                local dest_dir=$(dirname "$env_path" | sed 's|^/opt|/opt|')
                mkdir -p "$dest_dir"
                migrate_with_rsync "$env_path" "$dest_dir/$(basename "$env_path")" "" "false" "Environment file $env_path"
            done
        fi
        
        # Get a list of matching env files in /var/www
        local www_env_files=$(execute_remote_command "find /var/www -name '$env_file' -type f 2>/dev/null || echo ''")
        
        if [[ -n "$www_env_files" ]]; then
            for env_path in $www_env_files; do
                local dest_dir=$(dirname "$env_path" | sed 's|^/var/www|/var/www|')
                mkdir -p "$dest_dir"
                migrate_with_rsync "$env_path" "$dest_dir/$(basename "$env_path")" "" "false" "Environment file $env_path"
            done
        fi
    done
    
    # Set proper permissions for environment files
    find /opt -name ".env*" -type f -exec chmod 600 {} \; 2>/dev/null || true
    find /var/www -name ".env*" -type f -exec chmod 600 {} \; 2>/dev/null || true
    
    # Systemd services
    # Get a list of service files
    local service_files=$(execute_remote_command "ls -1 /etc/systemd/system/*.service 2>/dev/null || echo ''")
    
    if [[ -n "$service_files" ]]; then
        # For each service file, copy it individually
        for service_file in $service_files; do
            local service_name=$(basename "$service_file")
            migrate_with_rsync "$service_file" "/etc/systemd/system/$service_name" "" "false" "System service file $service_name"
        done
    else
        warning "No service files found on source server"
    fi
    
    # Set proper permissions for service files
    chmod 644 /etc/systemd/system/*.service 2>/dev/null || true
    
    systemctl daemon-reload
}

# =============================================================================
# POST-MIGRATION FUNCTIONS
# =============================================================================

post_migration_setup() {
    log "Running post-migration setup..."
    
    # Fix permissions for web directories
    if getent passwd www-data >/dev/null; then
        chown -R www-data:www-data /var/www/ 2>/dev/null || true
        find /var/www -type d -exec chmod 755 {} \; 2>/dev/null || true
        find /var/www -type f -exec chmod 644 {} \; 2>/dev/null || true
    fi
    
    if getent passwd nginx >/dev/null; then
        chown -R nginx:nginx /var/www/ 2>/dev/null || true
    fi
    
    # Make sure script files are executable
    find /var/www -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    find /opt -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    
    # Fix permissions for configuration files
    chmod 644 /etc/nginx/nginx.conf 2>/dev/null || true
    chmod 644 /etc/nginx/conf.d/*.conf 2>/dev/null || true
    chmod 644 /etc/nginx/sites-available/* 2>/dev/null || true
    find /etc/uwsgi -name "*.ini" -exec chmod 644 {} \; 2>/dev/null || true
    
    # Restart services
    systemctl restart nginx 2>/dev/null || true
    systemctl restart uwsgi* 2>/dev/null || true
    
    # Enable services
    for service in nginx uwsgi postgresql mysql mariadb docker; do
        if systemctl list-unit-files | grep -q "$service"; then
            systemctl enable "$service" 2>/dev/null || true
        fi
    done
    
    log "Post-migration setup completed"
}



# Post-migration restart services
restart_services() {
    log "Restarting services..."
    
    # Restart Nginx
    systemctl restart nginx || warning "Failed to restart Nginx"
    
    # Restart uWSGI
    systemctl restart uwsgi || warning "Failed to restart uWSGI"
    
    # Restart Docker containers
    if command -v docker &>/dev/null; then
        docker restart $(docker ps -q) || warning "Failed to restart Docker containers"
    fi
    
    log "Services restarted"
}

generate_migration_report() {
    log "Generating migration report..."
    
    local report_file="$DEST_BASE_DIR/migration_report_$(date +%Y%m%d_%H%M%S).txt"
    
    cat > "$report_file" << EOF
=============================================================================
SERVER MIGRATION REPORT
=============================================================================
Migration Date: $(date)
Source Server: $SOURCE_USER@$SOURCE_HOST:$SOURCE_PORT
Destination Server: $(hostname)

MIGRATION SUMMARY:
- Nginx: $([ "$MIGRATE_NGINX" == "true" ] && echo "✓ Migrated" || echo "✗ Skipped")
- uWSGI: $([ "$MIGRATE_UWSGI" == "true" ] && echo "✓ Migrated" || echo "✗ Skipped")
- Django Apps: $([ "$MIGRATE_DJANGO" == "true" ] && echo "✓ Migrated" || echo "✗ Skipped")
- Next.js Apps: $([ "$MIGRATE_NEXTJS" == "true" ] && echo "✓ Migrated" || echo "✗ Skipped")
- Cron Jobs: $([ "$MIGRATE_CRON" == "true" ] && echo "✓ Migrated" || echo "✗ Skipped")
- Docker: $([ "$MIGRATE_DOCKER" == "true" ] && echo "✓ Migrated" || echo "✗ Skipped")

DISCOVERED APPLICATIONS:
$(cat "$DEST_BASE_DIR/discovered_django_apps.txt" 2>/dev/null | sed 's/^/Django: /')
$(cat "$DEST_BASE_DIR/discovered_nextjs_apps.txt" 2>/dev/null | sed 's/^/Next.js: /')

SERVICE STATUS:
$(systemctl status nginx --no-pager -l 2>/dev/null | head -3 || echo "Nginx: Not running")
$(systemctl status uwsgi --no-pager -l 2>/dev/null | head -3 || echo "uWSGI: Not running")
$(systemctl status postgresql --no-pager -l 2>/dev/null | head -3 || echo "PostgreSQL: Not running")
$(systemctl status mysql --no-pager -l 2>/dev/null | head -3 || echo "MySQL: Not running")

NEXT STEPS:
1. Verify all applications are working correctly
2. Update DNS records to point to this server
3. Test SSL certificates and renew if necessary
4. Review and update any hardcoded IP addresses
5. Monitor logs for any issues: tail -f $LOG_FILE

BACKUP LOCATION: $BACKUP_DIR
MIGRATION FILES: $DEST_BASE_DIR
EOF
    
    info "Migration report saved to: $report_file"
    cat "$report_file"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    echo "==============================================================================" | tee -a "$LOG_FILE"
    echo "SERVER MIGRATION SCRIPT - $(date)" | tee -a "$LOG_FILE"
    echo "==============================================================================" | tee -a "$LOG_FILE"
    echo
    echo -e "${YELLOW}Source Server:${NC} $SOURCE_USER@$SOURCE_HOST:$SOURCE_PORT"
    echo -e "${YELLOW}Destination:${NC} $(hostname)"
    echo -e "${YELLOW}Migration Directory:${NC} $DEST_BASE_DIR"
    echo -e "${YELLOW}Log File:${NC} $LOG_FILE"
    echo
    
    # Setup
    run_step "prerequisites" check_prerequisites "Checking System Prerequisites"
    run_step "ssh_connection" test_ssh_connection "Testing SSH Connection to Source Server"
    
    # Discovery
    run_step "discover_applications" discover_applications "Discovering Applications on Source Server"
    
    # Backup current state
    run_step "create_backup" create_backup "Creating Backup of Current Configuration"
    
    # Execute migrations
    run_step "migrate_nginx" migrate_nginx "Migrating Nginx Configuration"
    run_step "migrate_uwsgi" migrate_uwsgi "Migrating uWSGI Configuration"
    run_step "migrate_cron_jobs" migrate_cron_jobs "Migrating Cron Jobs"
    run_step "migrate_docker" migrate_docker "Migrating Docker Containers and Volumes"
    run_step "migrate_applications" migrate_applications "Migrating Application Files"
    

    
    run_step "migrate_system_configs" migrate_system_configs "Migrating System Configurations"
    
    # Post-migration
    run_step "post_migration_setup" post_migration_setup "Running Post-Migration Setup"
    run_step "generate_report" generate_migration_report "Generating Migration Report"
    
    echo "==============================================================================" 
    echo -e "${GREEN}MIGRATION SUMMARY${NC}"
    echo "==============================================================================" 
    echo
    
    if [[ "$STEP_FAILURES" -eq 0 ]]; then
        echo -e "${GREEN}✓ Migration completed successfully!${NC}"
    else
        echo -e "${YELLOW}⚠ Migration completed with $STEP_FAILURES failures.${NC}"
        echo -e "${YELLOW}  Some steps may require manual intervention.${NC}"
    fi
    
    echo
    echo -e "${BLUE}Next Steps:${NC}"
    echo "1. Review the migration report at: $DEST_BASE_DIR/migration_report_*.txt"
    echo "2. Test all migrated applications"
    echo "3. Update DNS records to point to this server"
    echo "4. Monitor logs for any issues: tail -f $LOG_FILE"
    echo
}

# Error handling - don't exit, just log the error
trap 'error "Error occurred at line $LINENO: $BASH_COMMAND"' ERR

# Handle interruptions gracefully
trap 'error "Migration interrupted by user"; generate_migration_report; exit 1' INT TERM



# Create directories
mkdir -p "$DEST_BASE_DIR" "$BACKUP_DIR"
touch "$LOG_FILE"
chmod 755 "$DEST_BASE_DIR" "$BACKUP_DIR"
chmod 644 "$LOG_FILE"

# Display banner
echo
echo "==============================================================================" 
echo -e "${GREEN}SERVER MIGRATION TOOL${NC} - Digital Ocean to Hetzner Cloud"
echo "==============================================================================" 
echo -e "${YELLOW}Starting migration process at $(date)${NC}"
echo

# Execute main function with output logging
main "$@" 2>&1 | tee -a "$LOG_FILE"

# Final status report
if [[ "$MIGRATION_STATUS" == "success" ]]; then
    log "Migration completed successfully at $(date)!"
else
    warning "Migration completed with $STEP_FAILURES failures at $(date). Review logs and fix issues manually."
fi

log "See detailed report at: $DEST_BASE_DIR/migration_report_*.txt"