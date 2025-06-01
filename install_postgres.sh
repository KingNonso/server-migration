#!/bin/bash

# =============================================================================
# POSTGRESQL INSTALLATION AND CONFIGURATION SCRIPT
# =============================================================================
#
# Description:
#   Automated PostgreSQL installation and configuration script that:
#   - Installs PostgreSQL with optimal settings
#   - Configures for production use
#   - Sets up security and remote access
#   - Installs common extensions and tools
#
# Supported Systems:
#   - Ubuntu 20.04/22.04
#   - Debian 10/11
#   - RHEL/CentOS 7/8 (experimental)
#
# Usage:
#   ./install_postgres.sh [options]
#
# Options:
#   --version VERSION    PostgreSQL version to install (12-16)
#   --no-firewall       Skip firewall configuration
#   --no-remote         Skip remote access setup
#   --help              Display this help message
#
# Features:
#   - Automatic system detection
#   - Memory-based configuration
#   - Security hardening
#   - Performance optimization
#   - Monitoring setup
#   - Backup configuration
#
# Examples:
#   ./install_postgres.sh --version 16
#   ./install_postgres.sh --no-firewall --version 15
#
# Note: Requires root privileges
# =============================================================================

set -euo pipefail

# Configuration
POSTGRES_VERSION="16"  # Can be changed to 12, 13, 14, 15, 16
POSTGRES_USER="postgres"
DB_NAME="postgres"
INSTALL_DIR="/var/lib/postgresql/install"
STATE_FILE="$INSTALL_DIR/install_state.json"
LOG_FILE="$INSTALL_DIR/postgres_install.log"

# Installation state tracking
declare -A STEPS=(
    ["check_root"]=0
    ["detect_os"]=0
    ["update_system"]=0
    ["install_postgres"]=0
    ["configure_postgres"]=0
    ["start_service"]=0
    ["secure_postgres"]=0
    ["configure_firewall"]=0
    ["install_tools"]=0
    ["create_migration_user"]=0
)

# Function to initialize state file
init_state_file() {
    mkdir -p "$INSTALL_DIR"
    if [[ ! -f "$STATE_FILE" ]]; then
        log "Initializing new installation state"
        # Create initial state with all steps set to 0
        local json_content="{"
        local first=true
        for step in "${!STEPS[@]}"; do
            if [[ "$first" == true ]]; then
                first=false
            else
                json_content+=","
            fi
            json_content+="\"$step\": 0"
        done
        json_content+="}"
        echo "$json_content" > "$STATE_FILE"
    fi
}

# Function to save state
save_state() {
    local step=$1
    STEPS["$step"]=1
    
    # Read existing state
    local current_state
    if [[ -f "$STATE_FILE" ]]; then
        current_state=$(cat "$STATE_FILE")
    else
        current_state="{}"
    fi
    
    # Update the state for the completed step
    echo "$current_state" | jq --arg step "$step" '. + {($step): 1}' > "$STATE_FILE"
}

# Function to load state
load_state() {
    # Initialize state file if it doesn't exist
    init_state_file
    
    # Reset all steps to 0 first
    for step in "${!STEPS[@]}"; do
        STEPS["$step"]=0
    done
    
    # Load saved state if file exists
    if [[ -f "$STATE_FILE" ]]; then
        while IFS="=" read -r step value; do
            if [[ -n "$step" ]]; then
                STEPS["$step"]=$value
            fi
        done < <(jq -r 'to_entries | map("\(.key)=\(.value)") | .[]' "$STATE_FILE")
    fi
    
    # Log loaded state
    log "Loaded installation state:"
    for step in "${!STEPS[@]}"; do
        if [[ ${STEPS["$step"]} -eq 1 ]]; then
            log "  - $step: Completed"
        else
            log "  - $step: Pending"
        fi
    done
}

# Function to check if step is completed
is_step_completed() {
    local step=$1
    [[ ${STEPS["$step"]} -eq 1 ]]
}

# Function to run step if not completed
run_step() {
    local step=$1
    local step_name=$2
    shift 2
    
    if ! is_step_completed "$step"; then
        log "Running step: $step_name"
        if "$@"; then
            save_state "$step"
            success "Step completed: $step_name"
        else
            error "Step failed: $step_name"
            return 1
        fi
    else
        log "Skipping completed step: $step_name"
    fi
    return 0
}

# System configuration
TOTAL_MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
CPU_CORES=$(nproc)

# Backup configuration
BACKUP_DIR="/var/lib/postgresql/backups"
BACKUP_RETENTION_DAYS=7

# Security configuration
FAIL2BAN_ENABLED=true
SSL_ENABLED=true
PASSWORD_ENCRYPTION="scram-sha-256"  # More secure than md5

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Function to detect OS
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
        log "Detected OS: $OS $VER"
    else
        error "Cannot detect OS version"
        exit 1
    fi
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        echo "Please run: sudo $0"
        exit 1
    fi
}

# Function to update system packages
update_system() {
    log "Updating system packages..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update -y
        apt-get upgrade -y
        success "System packages updated"
    elif command -v yum &> /dev/null; then
        yum update -y
        success "System packages updated"
    else
        error "Package manager not found"
        exit 1
    fi
}

# Function to install PostgreSQL on Ubuntu/Debian
install_postgres_debian() {
    log "Installing PostgreSQL $POSTGRES_VERSION on Debian/Ubuntu..."
    
    # Install required packages
    apt-get install -y wget ca-certificates
    
    # Add PostgreSQL official APT repository
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    
    # Import repository signing key
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
    
    # Update package list
    apt-get update -y
    
    # Install PostgreSQL
    apt-get install -y postgresql-$POSTGRES_VERSION postgresql-client-$POSTGRES_VERSION postgresql-contrib-$POSTGRES_VERSION
    
    success "PostgreSQL $POSTGRES_VERSION installed successfully"
}

# Function to install PostgreSQL on CentOS/RHEL
install_postgres_rhel() {
    log "Installing PostgreSQL $POSTGRES_VERSION on CentOS/RHEL..."
    
    # Install PostgreSQL repository
    yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
    
    # Install PostgreSQL
    yum install -y postgresql${POSTGRES_VERSION}-server postgresql${POSTGRES_VERSION} postgresql${POSTGRES_VERSION}-contrib
    
    # Initialize database
    /usr/pgsql-${POSTGRES_VERSION}/bin/postgresql-${POSTGRES_VERSION}-setup initdb
    
    success "PostgreSQL $POSTGRES_VERSION installed successfully"
}

# Function to verify PostgreSQL version compatibility
check_version_compatibility() {
    log "Checking PostgreSQL version compatibility..."
    
    if [[ "$POSTGRES_VERSION" != "17" && "$POSTGRES_VERSION" != "16" && "$POSTGRES_VERSION" != "15" && "$POSTGRES_VERSION" != "14" && "$POSTGRES_VERSION" != "13" && "$POSTGRES_VERSION" != "12" ]]; then
        error "Unsupported PostgreSQL version: $POSTGRES_VERSION"
        exit 1
    fi
    
    # Check if upgrading from existing installation
    if command -v psql &> /dev/null; then
        local current_version=$(psql --version | awk '{print $3}' | cut -d. -f1)
        if [[ "$current_version" -gt "$POSTGRES_VERSION" ]]; then
            error "Cannot downgrade from PostgreSQL $current_version to $POSTGRES_VERSION"
            exit 1
        fi
    fi
}

# Function to configure PostgreSQL
configure_postgres() {
    log "Configuring PostgreSQL..."
    
    # Find PostgreSQL configuration directory
    local pg_version=$(sudo -u postgres psql -t -c "SELECT version();" | grep -oP '\d+\.\d+' | head -1)
    local config_dir="/etc/postgresql/$POSTGRES_VERSION/main"
    
    if [[ ! -d "$config_dir" ]]; then
        # Try alternative locations
        config_dir="/var/lib/pgsql/$POSTGRES_VERSION/data"
        if [[ ! -d "$config_dir" ]]; then
            config_dir=$(find /etc -name "postgresql.conf" -type f 2>/dev/null | head -1 | xargs dirname)
        fi
    fi
    
    if [[ -d "$config_dir" ]]; then
        log "PostgreSQL config directory: $config_dir"
        
        # Backup original configuration
        cp "$config_dir/postgresql.conf" "$config_dir/postgresql.conf.backup.$(date +%Y%m%d)"
        cp "$config_dir/pg_hba.conf" "$config_dir/pg_hba.conf.backup.$(date +%Y%m%d)"
        
        # Configure PostgreSQL for remote connections with optimized settings
        log "Configuring PostgreSQL for remote connections and performance..."
        
        # Calculate optimal settings based on system resources
        local shared_buffers=$((TOTAL_MEMORY_KB / 4))KB
        local effective_cache_size=$((TOTAL_MEMORY_KB * 3 / 4))KB
        local work_mem=$((TOTAL_MEMORY_KB / (CPU_CORES * 4)))KB
        local maintenance_work_mem=$((TOTAL_MEMORY_KB / 16))KB
        
        # Update postgresql.conf with optimized settings
        cat >> "$config_dir/postgresql.conf" <<EOL
# Connection Settings
listen_addresses = '*'
port = 5432
max_connections = $((CPU_CORES * 4))

# Memory Settings
shared_buffers = $shared_buffers
effective_cache_size = $effective_cache_size
work_mem = $work_mem
maintenance_work_mem = $maintenance_work_mem

# WAL Settings
wal_level = replica
wal_buffers = 16MB
checkpoint_completion_target = 0.9

# Security Settings
ssl = $SSL_ENABLED
password_encryption = $PASSWORD_ENCRYPTION
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0
EOL

        # Configure SSL if enabled
        if [[ "$SSL_ENABLED" == true ]]; then
            openssl req -new -x509 -days 365 -nodes \
                -out "$config_dir/server.crt" \
                -keyout "$config_dir/server.key" \
                -subj "/CN=postgresql"
            chmod 600 "$config_dir/server.key"
            chown postgres:postgres "$config_dir/server.key" "$config_dir/server.crt"
        fi
        
        # Update pg_hba.conf for authentication with secure settings
        cat > "$config_dir/pg_hba.conf" <<EOL
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections
local   all             all                                     peer

# IPv4 connections
hostssl all             all             127.0.0.1/32            $PASSWORD_ENCRYPTION
hostssl all             all             0.0.0.0/0               $PASSWORD_ENCRYPTION

# IPv6 connections
hostssl all             all             ::1/128                 $PASSWORD_ENCRYPTION
hostssl all             all             ::/0                    $PASSWORD_ENCRYPTION
EOL
        
        success "PostgreSQL configuration updated"
    else
        warning "Could not find PostgreSQL configuration directory"
    fi
}

# Function to start and enable PostgreSQL service
start_postgres_service() {
    log "Starting PostgreSQL service..."
    
    # Determine service name
    local service_name="postgresql"
    if systemctl list-unit-files | grep -q "postgresql-$POSTGRES_VERSION"; then
        service_name="postgresql-$POSTGRES_VERSION"
    fi
    
    # Start and enable service
    systemctl start $service_name
    systemctl enable $service_name
    
    # Check if service is running
    if systemctl is-active --quiet $service_name; then
        success "PostgreSQL service is running"
    else
        error "Failed to start PostgreSQL service"
        exit 1
    fi
}

# Function to secure PostgreSQL installation
secure_postgres() {
    log "Securing PostgreSQL installation..."
    
    # Generate random password for postgres user
    local postgres_password=$(openssl rand -base64 32)
    
    # Set password for postgres user
    sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$postgres_password';"
    
    # Save password to file (readable only by root)
    echo "PostgreSQL postgres user password: $postgres_password" > /root/postgres_password.txt
    chmod 600 /root/postgres_password.txt
    
    success "PostgreSQL secured. Password saved to /root/postgres_password.txt"
    
    # Create a database for applications
    log "Creating application database..."
    sudo -u postgres createdb appdb
    success "Application database 'appdb' created"
}

# Function to configure firewall
configure_firewall() {
    log "Configuring firewall for PostgreSQL..."
    
    if command -v ufw &> /dev/null; then
        # Ubuntu/Debian firewall
        ufw allow 5432/tcp
        success "UFW firewall rule added for PostgreSQL"
    elif command -v firewall-cmd &> /dev/null; then
        # CentOS/RHEL firewall
        firewall-cmd --permanent --add-port=5432/tcp
        firewall-cmd --reload
        success "Firewalld rule added for PostgreSQL"
    else
        warning "No firewall detected. Please manually open port 5432 if needed"
    fi
}

# Function to install additional tools
install_additional_tools() {
    log "Installing additional PostgreSQL tools..."
    
    # Install tools one by one to handle failures
    if command -v apt-get &> /dev/null; then
        local packages=(
            "postgresql-client-common"
            "pgcli"
            "prometheus-node-exporter"
            "fail2ban"
            "pgbackrest"
        )
        
        # Try to install pg-stat-monitor if available
        if apt-cache show postgresql-${POSTGRES_VERSION}-pg-stat-monitor &>/dev/null; then
            packages+=("postgresql-${POSTGRES_VERSION}-pg-stat-monitor")
        else
            warning "Package postgresql-${POSTGRES_VERSION}-pg-stat-monitor not available, skipping"
        fi
        
        # Install packages one by one
        for package in "${packages[@]}"; do
            log "Installing $package..."
            if ! apt-get install -y "$package"; then
                warning "Failed to install $package, continuing with remaining packages"
            fi
        done
    elif command -v yum &> /dev/null; then
        local packages=(
            "postgresql-client"
            "prometheus-node-exporter"
            "fail2ban"
            "pgbackrest"
            "python3-pip"
        )
        
        # Try to install pg-stat-monitor if available
        if yum info pg_stat_monitor_${POSTGRES_VERSION} &>/dev/null; then
            packages+=("pg_stat_monitor_${POSTGRES_VERSION}")
        else
            warning "Package pg_stat_monitor_${POSTGRES_VERSION} not available, skipping"
        fi
        
        # Install packages one by one
        for package in "${packages[@]}"; do
            log "Installing $package..."
            if ! yum install -y "$package"; then
                warning "Failed to install $package, continuing with remaining packages"
            fi
        done
        
        # Install pgcli via pip
        pip3 install --no-input pgcli || warning "Failed to install pgcli via pip"
    fi
    
    # Configure fail2ban if enabled
    if [[ "$FAIL2BAN_ENABLED" == true ]]; then
        cat > /etc/fail2ban/jail.d/postgresql.conf <<EOL
[postgresql]
enabled = true
filter = postgresql
action = iptables-multiport[name=postgresql, port="5432"]
logpath = /var/log/postgresql/postgresql-${POSTGRES_VERSION}-main.log
maxretry = 5
findtime = 600
bantime = 3600
EOL
        systemctl restart fail2ban
    fi
    
    # Configure backup system
    mkdir -p "$BACKUP_DIR"
    chown postgres:postgres "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    
    # Setup pgBackRest configuration
    cat > /etc/pgbackrest.conf <<EOL
[global]
repo1-path=$BACKUP_DIR
repo1-retention-full=$BACKUP_RETENTION_DAYS

[main]
db-path=/var/lib/postgresql/${POSTGRES_VERSION}/main
EOL
    
    # Setup daily backup cron job
    echo "0 1 * * * postgres pgbackrest --type=full --stanza=main backup" > /etc/cron.d/postgresql-backup
    
    success "Additional tools and monitoring installed"
}

# Function to create migration user
create_migration_user() {
    log "Creating migration user..."
    
    # Create migration user with replication privileges
    sudo -u postgres psql -c "CREATE USER migration_user WITH REPLICATION PASSWORD 'migration_pass_$(date +%s)';"
    sudo -u postgres psql -c "GRANT pg_read_all_data TO migration_user;"
    sudo -u postgres psql -c "ALTER USER migration_user CREATEDB;"
    
    success "Migration user created"
}

# Function to display installation summary
display_summary() {
    echo ""
    echo "======================================"
    echo "  PostgreSQL Installation Complete!"
    echo "======================================"
    echo ""
    echo "PostgreSQL Version: $POSTGRES_VERSION"
    echo "Service Status: $(systemctl is-active postgresql 2>/dev/null || systemctl is-active postgresql-$POSTGRES_VERSION 2>/dev/null)"
    echo "Port: 5432"
    echo "Config Location: $(find /etc -name "postgresql.conf" -type f 2>/dev/null | head -1)"
    echo "Data Directory: $(sudo -u postgres psql -t -c "SHOW data_directory;" 2>/dev/null | xargs)"
    echo ""
    echo "Credentials:"
    echo "  - Postgres user password: See /root/postgres_password.txt"
    echo "  - Migration user: migration_user (check logs for password)"
    echo ""
    echo "Databases:"
    echo "  - postgres (default)"
    echo "  - appdb (application database)"
    echo ""
    echo "Next Steps:"
    echo "  1. Review configuration in postgresql.conf"
    echo "  2. Test connection: psql -U postgres -h localhost"
    echo "  3. Run database migration script"
    echo ""
    echo "Log file: $LOG_FILE"
    echo "======================================"
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -v, --version VERSION    PostgreSQL version to install (default: 15)"
    echo "  --no-firewall           Skip firewall configuration"
    echo "  --no-remote             Don't configure for remote connections"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                      # Install PostgreSQL 15 with default settings"
    echo "  $0 -v 14               # Install PostgreSQL 14"
    echo "  $0 --no-firewall       # Install without configuring firewall"
}

# Parse command line arguments
CONFIGURE_FIREWALL=true
CONFIGURE_REMOTE=true

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version)
            POSTGRES_VERSION="$2"
            shift 2
            ;;
        --no-firewall)
            CONFIGURE_FIREWALL=false
            shift
            ;;
        --no-remote)
            CONFIGURE_REMOTE=false
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
    echo "  PostgreSQL Installation Script"
    echo "  Target Version: $POSTGRES_VERSION"
    echo "======================================"
    echo ""
    
    # Load previous state if exists
    load_state
    
    log "Starting/Resuming PostgreSQL installation process"
    
    # Pre-installation checks
    run_step "check_root" "Check root privileges" check_root || exit 1
    run_step "detect_os" "Detect operating system" detect_os || exit 1
    
    # Update system
    run_step "update_system" "Update system packages" update_system || exit 1
    
    # Install PostgreSQL based on OS
    case $OS in
        "Ubuntu"|"Debian"*)
            run_step "install_postgres" "Install PostgreSQL" install_postgres_debian || exit 1
            ;;
        "CentOS"*|"Red Hat"*|"Rocky"*|"AlmaLinux"*)
            run_step "install_postgres" "Install PostgreSQL" install_postgres_rhel || exit 1
            ;;
        *)
            error "Unsupported operating system: $OS"
            exit 1
            ;;
    esac
    
    # Configure PostgreSQL
    if [[ "$CONFIGURE_REMOTE" == true ]]; then
        run_step "configure_postgres" "Configure PostgreSQL" configure_postgres || exit 1
    fi
    
    # Start PostgreSQL service
    run_step "start_service" "Start PostgreSQL service" start_postgres_service || exit 1
    
    # Secure installation
    run_step "secure_postgres" "Secure PostgreSQL installation" secure_postgres || exit 1
    
    # Configure firewall
    if [[ "$CONFIGURE_FIREWALL" == true ]]; then
        run_step "configure_firewall" "Configure firewall" configure_firewall || exit 1
    fi
    
    # Install additional tools
    run_step "install_tools" "Install additional tools" install_additional_tools || exit 1
    
    # Create migration user
    run_step "create_migration_user" "Create migration user" create_migration_user || exit 1
    
    # Display summary
    display_summary
    
    # Clean up state file on successful completion
    if [[ -f "$STATE_FILE" ]]; then
        rm "$STATE_FILE"
    fi
    
    success "PostgreSQL installation completed successfully!"
}

# Run main function
main "$@"