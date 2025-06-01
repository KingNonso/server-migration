#!/bin/bash

# =============================================================================
# NGINX SYMLINK AND MODULE REPAIR SCRIPT
# =============================================================================
# This script detects and fixes broken symlinks, missing modules, and 
# configuration issues in nginx installations
# Supports: Ubuntu/Debian, CentOS/RHEL, custom installations
# =============================================================================

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

success() {
    echo -e "${CYAN}[SUCCESS] $1${NC}"
}

# =============================================================================
# CONFIGURATION VARIABLES
# =============================================================================

# Common nginx paths to check
NGINX_PATHS=(
    "/etc/nginx"
    "/usr/local/nginx"
    "/opt/nginx"
    "/usr/share/nginx"
    "/var/lib/nginx"
)

# Common nginx binary locations
NGINX_BINARIES=(
    "/usr/sbin/nginx"
    "/usr/bin/nginx"
    "/usr/local/sbin/nginx"
    "/usr/local/bin/nginx"
    "/opt/nginx/sbin/nginx"
)

# Common nginx service files
NGINX_SERVICES=(
    "/etc/systemd/system/nginx.service"
    "/lib/systemd/system/nginx.service"
    "/usr/lib/systemd/system/nginx.service"
    "/etc/init.d/nginx"
)

# Log and backup directories
LOG_FILE="/var/log/nginx_repair.log"
BACKUP_DIR="/opt/nginx_repair_backup_$(date +%Y%m%d_%H%M%S)"
REPAIR_SUMMARY="/tmp/nginx_repair_summary.txt"

# System information
DISTRO=""
DISTRO_VERSION=""
PACKAGE_MANAGER=""
NGINX_VERSION=""
NGINX_BINARY=""
NGINX_CONFIG_DIR=""

# Counters
BROKEN_SYMLINKS_FOUND=0
BROKEN_SYMLINKS_FIXED=0
MISSING_MODULES_FOUND=0
MISSING_MODULES_FIXED=0
CONFIG_ISSUES_FOUND=0
CONFIG_ISSUES_FIXED=0

# =============================================================================
# SYSTEM DETECTION FUNCTIONS
# =============================================================================

detect_system() {
    log "Detecting system information..."
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="$ID"
        DISTRO_VERSION="$VERSION_ID"
    elif [[ -f /etc/redhat-release ]]; then
        DISTRO="centos"
        DISTRO_VERSION=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | head -1)
    else
        DISTRO="unknown"
        DISTRO_VERSION="unknown"
    fi
    
    # Determine package manager
    if command -v apt-get &> /dev/null; then
        PACKAGE_MANAGER="apt"
    elif command -v yum &> /dev/null; then
        PACKAGE_MANAGER="yum"
    elif command -v dnf &> /dev/null; then
        PACKAGE_MANAGER="dnf"
    elif command -v pacman &> /dev/null; then
        PACKAGE_MANAGER="pacman"
    else
        PACKAGE_MANAGER="unknown"
    fi
    
    info "Detected system: $DISTRO $DISTRO_VERSION"
    info "Package manager: $PACKAGE_MANAGER"
}

find_nginx_binary() {
    log "Locating nginx binary..."
    
    for binary in "${NGINX_BINARIES[@]}"; do
        if [[ -x "$binary" ]]; then
            NGINX_BINARY="$binary"
            NGINX_VERSION=$($binary -v 2>&1 | grep -o 'nginx/[0-9.]*' | cut -d'/' -f2)
            success "Found nginx binary: $NGINX_BINARY (version: $NGINX_VERSION)"
            return 0
        fi
    done
    
    # Try to find nginx in PATH
    if command -v nginx &> /dev/null; then
        NGINX_BINARY=$(command -v nginx)
        NGINX_VERSION=$(nginx -v 2>&1 | grep -o 'nginx/[0-9.]*' | cut -d'/' -f2)
        success "Found nginx binary in PATH: $NGINX_BINARY (version: $NGINX_VERSION)"
        return 0
    fi
    
    error "Nginx binary not found. Please install nginx first."
    return 1
}

find_nginx_config_dir() {
    log "Locating nginx configuration directory..."
    
    if [[ -n "$NGINX_BINARY" ]]; then
        # Get config path from nginx binary
        local config_test=$($NGINX_BINARY -t 2>&1 | grep "configuration file" | awk '{print $NF}')
        if [[ -n "$config_test" ]]; then
            NGINX_CONFIG_DIR=$(dirname "$config_test")
            success "Found nginx config directory: $NGINX_CONFIG_DIR"
            return 0
        fi
    fi
    
    # Fallback to common paths
    for path in "${NGINX_PATHS[@]}"; do
        if [[ -d "$path" && -f "$path/nginx.conf" ]]; then
            NGINX_CONFIG_DIR="$path"
            success "Found nginx config directory: $NGINX_CONFIG_DIR"
            return 0
        fi
    done
    
    error "Nginx configuration directory not found"
    return 1
}

# =============================================================================
# BACKUP FUNCTIONS
# =============================================================================

create_backup() {
    log "Creating backup of nginx configuration..."
    
    mkdir -p "$BACKUP_DIR"
    
    if [[ -n "$NGINX_CONFIG_DIR" && -d "$NGINX_CONFIG_DIR" ]]; then
        cp -r "$NGINX_CONFIG_DIR" "$BACKUP_DIR/nginx_config"
        info "Configuration backed up to: $BACKUP_DIR/nginx_config"
    fi
    
    # Backup systemd service files
    for service in "${NGINX_SERVICES[@]}"; do
        if [[ -f "$service" ]]; then
            cp "$service" "$BACKUP_DIR/$(basename $service).backup"
        fi
    done
    
    # Backup nginx binary if it's a symlink
    if [[ -L "$NGINX_BINARY" ]]; then
        cp -L "$NGINX_BINARY" "$BACKUP_DIR/nginx.binary.backup"
    fi
}

# =============================================================================
# SYMLINK DETECTION AND REPAIR FUNCTIONS
# =============================================================================

find_broken_symlinks() {
    log "Scanning for broken symlinks in nginx directories..."
    
    # Temporarily disable exit on error for this function
    set +e
    
    local broken_symlinks=()
    
    # Check nginx configuration directories
    for nginx_dir in "${NGINX_PATHS[@]}"; do
        if [[ -d "$nginx_dir" ]]; then
            info "Checking directory: $nginx_dir"
            
            # Find broken symlinks - safer approach
            local find_output
            find_output=$(find "$nginx_dir" -type l 2>/dev/null)
            
            if [[ -n "$find_output" ]]; then
                while IFS= read -r symlink; do
                    # Skip empty lines
                    if [[ -z "$symlink" ]]; then
                        continue
                    fi
                    
                    if [[ -L "$symlink" && ! -e "$symlink" ]]; then
                        broken_symlinks+=("$symlink")
                        ((BROKEN_SYMLINKS_FOUND++))
                        warning "Broken symlink found: $symlink -> $(readlink "$symlink" 2>/dev/null || echo 'unknown target')"
                    fi
                done <<< "$find_output"
            fi
        fi
    done
    
    # Check nginx binary
    if [[ -n "$NGINX_BINARY" && -L "$NGINX_BINARY" && ! -e "$NGINX_BINARY" ]]; then
        broken_symlinks+=("$NGINX_BINARY")
        ((BROKEN_SYMLINKS_FOUND++))
        warning "Broken nginx binary symlink: $NGINX_BINARY -> $(readlink "$NGINX_BINARY" 2>/dev/null || echo 'unknown target')"
    fi
    
    # Save broken symlinks to array for processing - handle empty array
    if [[ ${#broken_symlinks[@]} -gt 0 ]]; then
        printf '%s\n' "${broken_symlinks[@]}" > /tmp/broken_symlinks.txt
    else
        # Create empty file
        touch /tmp/broken_symlinks.txt
    fi
    
    info "Found $BROKEN_SYMLINKS_FOUND broken symlinks"
    
    # Re-enable exit on error
    set -e
    return 0
}

repair_broken_symlinks() {
    # Temporarily disable exit on error for this function
    set +e
    
    if [[ $BROKEN_SYMLINKS_FOUND -eq 0 ]]; then
        set -e
        return 0
    fi
    
    log "Repairing broken symlinks..."
    
    # Check if the file exists
    if [[ ! -f "/tmp/broken_symlinks.txt" ]]; then
        warning "Broken symlinks file not found. Creating empty file."
        touch /tmp/broken_symlinks.txt
    fi
    
    while IFS= read -r symlink; do
        # Skip empty lines
        if [[ -z "$symlink" ]]; then
            continue
        fi
        
        # Skip if symlink no longer exists
        if [[ ! -L "$symlink" && ! -e "$symlink" ]]; then
            warning "Symlink no longer exists: $symlink"
            continue
        fi
        
        local target=$(readlink "$symlink" 2>/dev/null || echo "unknown")
        local symlink_name=$(basename "$symlink")
        local symlink_dir=$(dirname "$symlink")
        
        info "Repairing: $symlink -> $target"
        
        # Try to find the correct target
        local new_target=""
        
        # For nginx config files
        if [[ "$symlink" == *"/sites-enabled/"* ]]; then
            local available_file="/etc/nginx/sites-available/$symlink_name"
            if [[ -f "$available_file" ]]; then
                new_target="$available_file"
            fi
        fi
        
        # For nginx modules
        if [[ "$symlink" == *"/modules/"* || "$symlink" == *"/modules-enabled/"* ]]; then
            local possible_targets=(
                "/usr/lib/nginx/modules/$symlink_name"
                "/usr/local/lib/nginx/modules/$symlink_name"
                "/etc/nginx/modules-available/$symlink_name"
                "/usr/share/nginx/modules/$symlink_name"
            )
            
            for possible_target in "${possible_targets[@]}"; do
                if [[ -f "$possible_target" ]]; then
                    new_target="$possible_target"
                    break
                fi
            done
        fi
        
        # For nginx binary
        if [[ "$symlink" == "$NGINX_BINARY" ]]; then
            local possible_binaries=(
                "/usr/sbin/nginx"
                "/usr/bin/nginx"
                "/usr/local/sbin/nginx"
                "/usr/local/bin/nginx"
            )
            
            for possible_binary in "${possible_binaries[@]}"; do
                if [[ -f "$possible_binary" && -x "$possible_binary" ]]; then
                    new_target="$possible_binary"
                    break
                fi
            done
        fi
        
        # Attempt repair
        if [[ -n "$new_target" && -e "$new_target" ]]; then
            # Remove symlink safely
            if [[ -L "$symlink" ]]; then
                rm "$symlink" 2>/dev/null || {
                    warning "Failed to remove symlink: $symlink"
                    continue
                }
            fi
            
            # Create new symlink
            ln -s "$new_target" "$symlink" 2>/dev/null || {
                warning "Failed to create new symlink: $symlink -> $new_target"
                continue
            }
            
            success "Fixed: $symlink -> $new_target"
            ((BROKEN_SYMLINKS_FIXED++))
        else
            # Try to recreate from package
            attempt_package_repair "$symlink"
        fi
        
    done < /tmp/broken_symlinks.txt
    
    info "Repaired $BROKEN_SYMLINKS_FIXED out of $BROKEN_SYMLINKS_FOUND broken symlinks"
    
    # Re-enable exit on error
    set -e
    return 0
}

# =============================================================================
# MODULE DETECTION AND REPAIR FUNCTIONS
# =============================================================================

check_nginx_modules() {
    log "Checking nginx modules..."
    
    if [[ -z "$NGINX_BINARY" ]]; then
        error "Nginx binary not found, cannot check modules"
        return 1
    fi
    
    # Get compiled modules
    local compiled_modules=$($NGINX_BINARY -V 2>&1 | grep -o 'with-[^[:space:]]*' | sed 's/with-//')
    
    info "Compiled-in modules:"
    echo "$compiled_modules" | while read -r module; do
        if [[ -n "$module" ]]; then
            info "  - $module"
        fi
    done
    
    # Check dynamic modules directory
    local modules_dir=""
    if [[ -d "/etc/nginx/modules" ]]; then
        modules_dir="/etc/nginx/modules"
    elif [[ -d "/usr/lib/nginx/modules" ]]; then
        modules_dir="/usr/lib/nginx/modules"
    elif [[ -d "/usr/local/lib/nginx/modules" ]]; then
        modules_dir="/usr/local/lib/nginx/modules"
    fi
    
    if [[ -n "$modules_dir" ]]; then
        info "Dynamic modules directory: $modules_dir"
        
        # Check for missing modules referenced in config
        check_missing_dynamic_modules "$modules_dir"
    fi
}

check_missing_dynamic_modules() {
    local modules_dir="$1"
    
    # Temporarily disable exit on error for this function
    set +e
    
    log "Checking for missing dynamic modules..."
    
    # Find load_module directives in nginx configs
    local load_module_directives=()
    
    if [[ -f "$NGINX_CONFIG_DIR/nginx.conf" ]]; then
        # Use grep to find load_module lines first (faster)
        local module_lines=$(grep -E "load_module" "$NGINX_CONFIG_DIR/nginx.conf" 2>/dev/null)
        
        if [[ -n "$module_lines" ]]; then
            while IFS= read -r line; do
                if [[ "$line" =~ load_module[[:space:]]+([^;]+) ]]; then
                    local module_path="${BASH_REMATCH[1]}"
                    module_path=$(echo "$module_path" | tr -d '"' | tr -d "'")
                    load_module_directives+=("$module_path")
                fi
            done <<< "$module_lines"
        fi
    fi
    
    # Check if referenced modules exist
    local module_count=${#load_module_directives[@]}
    local current=0
    
    for module_path in "${load_module_directives[@]}"; do
        ((current++))
        
        # Show progress
        if [[ $module_count -gt 5 ]]; then
            show_progress "Checking modules" "$current" "$module_count"
        fi
        
        # Handle relative paths
        if [[ "$module_path" != /* ]]; then
            module_path="$modules_dir/$module_path"
        fi
        
        if [[ ! -f "$module_path" ]]; then
            warning "\nMissing module: $module_path"
            ((MISSING_MODULES_FOUND++))
            attempt_module_installation "$(basename "$module_path")" || true
        else
            if [[ $module_count -le 5 ]]; then
                info "Module OK: $module_path"
            fi
        fi
    done
    
    # Also check modules-enabled directory for missing files
    check_modules_enabled_directory
    
    # Print newline after progress bar if we used it
    if [[ $module_count -gt 5 ]]; then
        echo ""
    fi
    
    # Re-enable exit on error
    set -e
    return 0
}

check_modules_enabled_directory() {
    log "Checking modules-enabled directory for missing configuration files..."
    
    # Check if modules-enabled directory exists
    if [[ -d "/etc/nginx/modules-enabled" ]]; then
        # Get a list of all module conf files referenced in nginx.conf
        local module_conf_files=()
        
        # Check nginx.conf for include directives pointing to modules-enabled
        if [[ -f "$NGINX_CONFIG_DIR/nginx.conf" ]]; then
            local include_lines=$(grep -E "include[[:space:]]+/etc/nginx/modules-enabled/" "$NGINX_CONFIG_DIR/nginx.conf" 2>/dev/null)
            
            if [[ -n "$include_lines" ]]; then
                while IFS= read -r line; do
                    if [[ "$line" =~ include[[:space:]]+([^;]+) ]]; then
                        local include_path="${BASH_REMATCH[1]}"
                        include_path=$(echo "$include_path" | tr -d '"' | tr -d "'")
                        
                        # If it's a wildcard, get all matching files
                        if [[ "$include_path" == "/etc/nginx/modules-enabled/*" || "$include_path" == "/etc/nginx/modules-enabled/*.conf" ]]; then
                            # Get all conf files that should exist by checking nginx test output
                            local test_output
                            test_output=$($NGINX_BINARY -t 2>&1)
                            local error_pattern=".*modules-enabled/[^:]+\.conf.*failed"
                            
                            while IFS= read -r error_line; do
                                if [[ "$error_line" =~ $error_pattern ]]; then
                                    # Extract the file path more reliably
                                    local file_path
                                    file_path=$(echo "$error_line" | grep -o '/etc/nginx/modules-enabled/[^[:space:]]*')
                                    if [[ -n "$file_path" ]]; then
                                        warning "Missing module configuration: $file_path"
                                        module_conf_files+=("$file_path")
                                    fi
                                fi
                            done < <(echo "$test_output")
                        else
                            # It's a specific file
                            if [[ ! -f "$include_path" ]]; then
                                warning "Missing module configuration: $include_path"
                                module_conf_files+=("$include_path")
                            fi
                        fi
                    fi
                done <<< "$include_lines"
            fi
        fi
        
        # Try to repair missing module conf files
        for conf_file in "${module_conf_files[@]}"; do
            repair_module_conf_file "$conf_file"
        done
    fi
}

# Split module installation into separate functions for better organization
attempt_module_installation() {
    local module_name="$1"
    
    # Temporarily disable exit on error for this function
    set +e
    
    info "Attempting to install missing module: $module_name"
    
    # Remove .so extension for package name matching
    local base_module_name=$(echo "$module_name" | sed 's/\.so$//')
    
    # Try multiple approaches in sequence
    if install_module_via_package "$base_module_name"; then
        # Test if nginx config is valid after installation
        if $NGINX_BINARY -t &>/dev/null; then
            success "Module installation successful and nginx config is valid"
            set -e
            return 0
        else
            info "Module installed but nginx config still has issues. Continuing with other repair methods..."
        fi
    fi
    
    if find_and_link_existing_module "$base_module_name"; then
        # Test if nginx config is valid after linking
        if $NGINX_BINARY -t &>/dev/null; then
            success "Module linking successful and nginx config is valid"
            set -e
            return 0
        else
            info "Module linked but nginx config still has issues. Continuing with other repair methods..."
        fi
    fi
    
    warning "Could not automatically install module: $module_name"
    
    # Re-enable exit on error
    set -e
    return 1
}

install_module_via_package() {
    local base_module_name="$1"
    
    case "$PACKAGE_MANAGER" in
        "apt")
            # Common nginx module packages in Ubuntu/Debian
            local possible_packages=(
                "libnginx-mod-$base_module_name"
                "nginx-module-$base_module_name"
                "nginx-extras"
                "nginx-full"
            )
            
            for package in "${possible_packages[@]}"; do
                if apt-cache show "$package" &>/dev/null; then
                    info "Installing package: $package"
                    if run_with_timeout "apt-get update && apt-get install -y $package" 120 "Installing $package"; then
                        success "Installed module package: $package"
                        ((MISSING_MODULES_FIXED++))
                        return 0
                    fi
                fi
            done
            ;;
            
        "yum"|"dnf")
            # Common nginx module packages in CentOS/RHEL/Fedora
            local possible_packages=(
                "nginx-mod-$base_module_name"
                "nginx-module-$base_module_name"
            )
            
            for package in "${possible_packages[@]}"; do
                if $PACKAGE_MANAGER list available "$package" &>/dev/null; then
                    info "Installing package: $package"
                    if run_with_timeout "$PACKAGE_MANAGER install -y $package" 120 "Installing $package"; then
                        success "Installed module package: $package"
                        ((MISSING_MODULES_FIXED++))
                        return 0
                    fi
                fi
            done
            ;;
    esac
    
    return 1
}

find_and_link_existing_module() {
    local base_module_name="$1"
    
    # Try to find module in system
    local found_modules=$(find /usr -name "*$base_module_name*.so" 2>/dev/null | head -5)
    if [[ -n "$found_modules" ]]; then
        info "Found potential module files:"
        local first_module=""
        while IFS= read -r found_module; do
            info "  - $found_module"
            if [[ -z "$first_module" ]]; then
                first_module="$found_module"
            fi
        done <<< "$found_modules"
        
        # If we found a module, try to link it
        if [[ -n "$first_module" ]]; then
            local modules_dir=""
            if [[ -d "/etc/nginx/modules" ]]; then
                modules_dir="/etc/nginx/modules"
            elif [[ -d "/usr/lib/nginx/modules" ]]; then
                modules_dir="/usr/lib/nginx/modules"
            elif [[ -d "/usr/local/lib/nginx/modules" ]]; then
                modules_dir="/usr/local/lib/nginx/modules"
            fi
            
            if [[ -n "$modules_dir" ]]; then
                # Create modules directory if it doesn't exist
                mkdir -p "$modules_dir" 2>/dev/null || true
                
                local target_file="$modules_dir/$(basename "$first_module")"
                if ln -sf "$first_module" "$target_file" 2>/dev/null; then
                    success "Linked module $first_module to $target_file"
                    ((MISSING_MODULES_FIXED++))
                    return 0
                else
                    warning "Failed to link module $first_module to $target_file"
                fi
            fi
        fi
    fi
    
    return 1
}

# =============================================================================
# CONFIGURATION REPAIR FUNCTIONS
# =============================================================================

check_nginx_configuration() {
    log "Checking nginx configuration syntax..."
    
    if [[ -z "$NGINX_BINARY" ]]; then
        error "Nginx binary not found"
        return 1
    fi
    
    # Test configuration
    local config_test_output
    if config_test_output=$($NGINX_BINARY -t 2>&1); then
        success "Nginx configuration syntax is OK"
        return 0
    else
        error "Nginx configuration has errors:"
        echo "$config_test_output" | while read -r line; do
            error "  $line"
        done
        ((CONFIG_ISSUES_FOUND++))
        
        # Try to automatically fix common issues
        if echo "$config_test_output" | grep -q "open() \"/etc/nginx/modules-enabled/.*\" failed"; then
            info "Attempting to fix missing module configuration files..."
            repair_missing_module_conf_files "$config_test_output"
            
            # Test again after repairs
            if $NGINX_BINARY -t &>/dev/null; then
                success "Fixed configuration issues with modules-enabled!"
                return 0
            else
                warning "Some configuration issues remain after module repairs"
            fi
        fi
        
        return 1
    fi
}

# Function to iteratively test and fix nginx configuration
iteratively_repair_nginx_config() {
    log "Iteratively testing and repairing nginx configuration..."
    
    local max_iterations=5
    local iteration=0
    local fixed_something=false
    
    while [[ $iteration -lt $max_iterations ]]; do
        ((iteration++))
        info "Repair iteration $iteration of $max_iterations"
        
        # Test configuration
        if $NGINX_BINARY -t &>/dev/null; then
            success "Nginx configuration is now valid!"
            return 0
        fi
        
        # Get error output
        local test_output=$($NGINX_BINARY -t 2>&1)
        
        # Try to fix issues based on error output
        fixed_something=false
        
        # Check for missing module configuration files
        if echo "$test_output" | grep -q "open() \"/etc/nginx/modules-enabled/.*\" failed"; then
            info "Fixing missing module configuration files..."
            repair_missing_module_conf_files "$test_output"
            fixed_something=true
        fi
        
        # Check for other common issues
        # Add more error patterns and fixes here
        
        # If we couldn't fix anything in this iteration, break the loop
        if [[ "$fixed_something" != "true" ]]; then
            warning "Could not fix any more issues automatically"
            break
        fi
    done
    
    # Final test
    if $NGINX_BINARY -t &>/dev/null; then
        success "Nginx configuration is now valid!"
        return 0
    else
        warning "Some configuration issues could not be fixed automatically"
        return 1
    fi
}

repair_common_config_issues() {
    log "Checking for common configuration issues..."
    
    # Temporarily disable exit on error for this function
    set +e
    
    if [[ ! -f "$NGINX_CONFIG_DIR/nginx.conf" ]]; then
        error "Main nginx.conf not found"
        set -e
        return 1
    fi
    
    local config_file="$NGINX_CONFIG_DIR/nginx.conf"
    local temp_config="/tmp/nginx.conf.repair"
    cp "$config_file" "$temp_config"
    
    local changes_made=false
    
    # Fix common path issues
    if grep -q "include /etc/nginx/sites-enabled/\*;" "$config_file" && [[ ! -d "/etc/nginx/sites-enabled" ]]; then
        if [[ -d "/etc/nginx/conf.d" ]]; then
            info "Fixing sites-enabled path to conf.d"
            sed -i 's|include /etc/nginx/sites-enabled/\*;|include /etc/nginx/conf.d/*.conf;|g' "$temp_config"
            changes_made=true
        else
            # Create sites-enabled directory if it doesn't exist
            info "Creating missing sites-enabled directory"
            mkdir -p "/etc/nginx/sites-enabled"
            changes_made=true
        fi
    fi
    
    # Fix modules-enabled issues
    if grep -q "include /etc/nginx/modules-enabled/\*;" "$config_file" || grep -q "include /etc/nginx/modules-enabled/\*.conf;" "$config_file"; then
        if [[ ! -d "/etc/nginx/modules-enabled" ]]; then
            info "Creating missing modules-enabled directory"
            mkdir -p "/etc/nginx/modules-enabled"
            changes_made=true
        fi
    fi
    
    # Check for missing module conf files
    local test_output=$($NGINX_BINARY -t 2>&1)
    if echo "$test_output" | grep -q "open() \"/etc/nginx/modules-enabled/.*\" failed"; then
        info "Detected missing module configuration files"
        repair_missing_module_conf_files "$test_output"
        changes_made=true
    fi
    
    # Fix missing directories
    local required_dirs=(
        "/var/log/nginx"
        "/var/cache/nginx"
        "/run/nginx"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            info "Creating missing directory: $dir"
            mkdir -p "$dir"
            chown -R www-data:www-data "$dir" 2>/dev/null || chown -R nginx:nginx "$dir" 2>/dev/null || true
        fi
    done
    
    # Apply changes if any were made
    if [[ "$changes_made" == "true" ]]; then
        mv "$temp_config" "$config_file"
        ((CONFIG_ISSUES_FIXED++))
        success "Applied configuration fixes"
    else
        rm "$temp_config"
    fi
    
    # Re-enable exit on error
    set -e
    return 0
}

repair_missing_module_conf_files() {
    local test_output="$1"
    
    log "Repairing missing module configuration files..."
    
    # Extract missing module conf files from nginx -t output
    local missing_files=()
    local error_pattern=".*modules-enabled/[^:]+\.conf.*failed"
    
    while IFS= read -r line; do
        if [[ "$line" =~ $error_pattern ]]; then
            # Extract the file path using grep
            local file_path
            file_path=$(echo "$line" | grep -o '/etc/nginx/modules-enabled/[^[:space:]]*')
            if [[ -n "$file_path" ]] && [[ "$file_path" == *".conf" ]]; then
                missing_files+=("$file_path")
                warning "Found missing module configuration: $file_path"
            fi
        fi
    done <<< "$test_output"
    
    # Try to repair each missing file
    for missing_file in "${missing_files[@]}"; do
        repair_module_conf_file "$missing_file"
    done
}

repair_module_conf_file() {
    local conf_file="$1"
    local module_name=$(basename "$conf_file" | sed 's/^[0-9]\+-mod-\|.conf$//g')
    
    info "Attempting to repair module configuration: $conf_file (module: $module_name)"
    
    # Create modules-enabled directory if it doesn't exist
    mkdir -p "/etc/nginx/modules-enabled" 2>/dev/null || true
    
    # Check if we can find the module in modules-available
    local available_conf="/etc/nginx/modules-available/$(basename "$conf_file")"
    if [[ -f "$available_conf" ]]; then
        info "Found module config in modules-available, creating symlink"
        ln -sf "$available_conf" "$conf_file"
        success "Created symlink for $conf_file"
        return 0
    fi
    
    # Try to find the module package and install it
    local module_packages=(
        "libnginx-mod-$module_name"
        "nginx-module-$module_name"
    )
    
    for package in "${module_packages[@]}"; do
        if [[ "$PACKAGE_MANAGER" == "apt" ]] && apt-cache show "$package" &>/dev/null; then
            info "Found package $package for module $module_name, installing..."
            if apt-get update -y && apt-get install -y "$package"; then
                success "Installed package $package for module $module_name"
                
                # Check if the conf file now exists
                if [[ -f "$conf_file" ]]; then
                    success "Module configuration file $conf_file now exists"
                    return 0
                fi
                
                # If not, check if it's in modules-available and create a symlink
                if [[ -f "/etc/nginx/modules-available/$(basename "$conf_file")" ]]; then
                    ln -sf "/etc/nginx/modules-available/$(basename "$conf_file")" "$conf_file"
                    success "Created symlink for $conf_file"
                    return 0
                fi
            fi
        elif [[ "$PACKAGE_MANAGER" == "yum" || "$PACKAGE_MANAGER" == "dnf" ]] && $PACKAGE_MANAGER list available "$package" &>/dev/null; then
            info "Found package $package for module $module_name, installing..."
            if $PACKAGE_MANAGER install -y "$package"; then
                success "Installed package $package for module $module_name"
                
                # Check if the conf file now exists
                if [[ -f "$conf_file" ]]; then
                    success "Module configuration file $conf_file now exists"
                    return 0
                fi
            fi
        fi
    done
    
    # If we couldn't install the package, create an empty conf file as a last resort
    warning "Could not find or install package for module $module_name, creating empty conf file"
    
    # Create a minimal module conf file
    cat > "$conf_file" << EOF
# Auto-generated by nginx repair script
# This is a placeholder for missing module: $module_name
# You may need to manually install the correct module package
# Commented out to prevent nginx from failing to start
# load_module modules/$module_name.so;
EOF
    
    chmod 644 "$conf_file"
    warning "Created placeholder conf file for $module_name. Nginx should now start, but the module will not be loaded."
    return 1
}

fix_permissions() {
    log "Fixing nginx file permissions..."
    
    # Fix nginx configuration permissions
    if [[ -d "$NGINX_CONFIG_DIR" ]]; then
        chmod -R 644 "$NGINX_CONFIG_DIR"/*.conf 2>/dev/null || true
        chmod 755 "$NGINX_CONFIG_DIR"
        find "$NGINX_CONFIG_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
    fi
    
    # Fix nginx binary permissions
    if [[ -f "$NGINX_BINARY" ]]; then
        chmod 755 "$NGINX_BINARY"
    fi
    
    # Fix log directory permissions
    if [[ -d "/var/log/nginx" ]]; then
        chown -R www-data:adm /var/log/nginx 2>/dev/null || chown -R nginx:nginx /var/log/nginx 2>/dev/null || true
        chmod 755 /var/log/nginx
    fi
    
    # Fix cache directory permissions
    if [[ -d "/var/cache/nginx" ]]; then
        chown -R www-data:www-data /var/cache/nginx 2>/dev/null || chown -R nginx:nginx /var/cache/nginx 2>/dev/null || true
    fi
}

# =============================================================================
# PACKAGE REPAIR FUNCTIONS
# =============================================================================

attempt_package_repair() {
    local broken_file="$1"
    
    info "Attempting package repair for: $broken_file"
    
    case "$PACKAGE_MANAGER" in
        "apt")
            # Try to reinstall nginx packages
            local nginx_packages=$(dpkg -l | grep nginx | awk '{print $2}')
            if [[ -n "$nginx_packages" ]]; then
                info "Reinstalling nginx packages..."
                apt-get install --reinstall $nginx_packages -y 2>/dev/null || true
            fi
            ;;
            
        "yum"|"dnf")
            # Try to reinstall nginx packages
            info "Reinstalling nginx packages..."
            $PACKAGE_MANAGER reinstall nginx -y 2>/dev/null || true
            ;;
    esac
}

reinstall_nginx_if_needed() {
    log "Checking if full nginx reinstallation is needed..."
    
    local critical_issues=0
    
    # Check if nginx binary is missing or broken
    if [[ ! -x "$NGINX_BINARY" ]]; then
        ((critical_issues++))
    fi
    
    # Check if main config is missing
    if [[ ! -f "$NGINX_CONFIG_DIR/nginx.conf" ]]; then
        ((critical_issues++))
    fi
    
    # Check if too many symlinks are broken
    if [[ $BROKEN_SYMLINKS_FOUND -gt 5 && $BROKEN_SYMLINKS_FIXED -lt $((BROKEN_SYMLINKS_FOUND / 2)) ]]; then
        ((critical_issues++))
    fi
    
    if [[ $critical_issues -ge 2 ]]; then
        warning "Multiple critical issues detected. Consider full nginx reinstallation."
        
        read -p "Do you want to reinstall nginx completely? (y/N): " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            info "Performing full nginx reinstallation..."
            
            case "$PACKAGE_MANAGER" in
                "apt")
                    systemctl stop nginx 2>/dev/null || true
                    apt-get remove --purge nginx nginx-common nginx-core -y
                    apt-get autoremove -y
                    apt-get update
                    apt-get install nginx -y
                    systemctl enable nginx
                    systemctl start nginx
                    ;;
                    
                "yum"|"dnf")
                    systemctl stop nginx 2>/dev/null || true
                    $PACKAGE_MANAGER remove nginx -y
                    $PACKAGE_MANAGER install nginx -y
                    systemctl enable nginx
                    systemctl start nginx
                    ;;
            esac
            
            success "Nginx reinstallation completed"
        fi
    fi
}

# =============================================================================
# SERVICE MANAGEMENT FUNCTIONS
# =============================================================================

check_nginx_service() {
    log "Checking nginx service status..."
    
    # Check if systemd service exists
    local service_file=""
    for service in "${NGINX_SERVICES[@]}"; do
        if [[ -f "$service" ]]; then
            service_file="$service"
            break
        fi
    done
    
    if [[ -z "$service_file" ]]; then
        warning "Nginx systemd service file not found"
        create_nginx_service
    else
        info "Found nginx service file: $service_file"
    fi
    
    # Check service status
    if systemctl is-active nginx &>/dev/null; then
        success "Nginx service is running"
    else
        warning "Nginx service is not running"
        
        # Try to start nginx
        if systemctl start nginx 2>/dev/null; then
            success "Started nginx service"
        else
            error "Failed to start nginx service"
            systemctl status nginx --no-pager -l || true
        fi
    fi
    
    # Enable nginx service
    if ! systemctl is-enabled nginx &>/dev/null; then
        info "Enabling nginx service"
        systemctl enable nginx 2>/dev/null || true
    fi
}

create_nginx_service() {
    info "Creating nginx systemd service file..."
    
    local service_file="/etc/systemd/system/nginx.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=The nginx HTTP and reverse proxy server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=$NGINX_BINARY -t
ExecStart=$NGINX_BINARY
ExecReload=/bin/kill -s HUP \$MAINPID
KillSignal=SIGQUIT
TimeoutStopSec=5
KillMode=mixed
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    success "Created nginx service file: $service_file"
}

# =============================================================================
# REPORTING FUNCTIONS
# =============================================================================

generate_repair_report() {
    log "Generating repair report..."
    
    cat > "$REPAIR_SUMMARY" << EOF
=============================================================================
NGINX REPAIR SUMMARY REPORT
=============================================================================
Repair Date: $(date)
System: $DISTRO $DISTRO_VERSION
Package Manager: $PACKAGE_MANAGER
Nginx Version: $NGINX_VERSION
Nginx Binary: $NGINX_BINARY
Nginx Config: $NGINX_CONFIG_DIR

REPAIR STATISTICS:
- Broken Symlinks Found: $BROKEN_SYMLINKS_FOUND
- Broken Symlinks Fixed: $BROKEN_SYMLINKS_FIXED
- Missing Modules Found: $MISSING_MODULES_FOUND
- Missing Modules Fixed: $MISSING_MODULES_FIXED
- Config Issues Found: $CONFIG_ISSUES_FOUND
- Config Issues Fixed: $CONFIG_ISSUES_FIXED

NGINX STATUS:
$(systemctl status nginx --no-pager -l 2>/dev/null | head -10 || echo "Service status unavailable")

CONFIGURATION TEST:
$($NGINX_BINARY -t 2>&1 || echo "Configuration test failed")

BACKUP LOCATION: $BACKUP_DIR
LOG FILE: $LOG_FILE

RECOMMENDATIONS:
$(if [[ $BROKEN_SYMLINKS_FIXED -lt $BROKEN_SYMLINKS_FOUND ]]; then
    echo "- Some broken symlinks could not be automatically repaired"
fi)
$(if [[ $MISSING_MODULES_FIXED -lt $MISSING_MODULES_FOUND ]]; then
    echo "- Some missing modules could not be automatically installed"
fi)
$(if [[ $CONFIG_ISSUES_FOUND -gt 0 ]]; then
    echo "- Review nginx configuration for remaining issues"
fi)

NEXT STEPS:
1. Test nginx configuration: nginx -t
2. Restart nginx service: systemctl restart nginx
3. Check nginx status: systemctl status nginx
4. Monitor nginx logs: tail -f /var/log/nginx/error.log
5. Test website functionality
EOF
    
    info "Repair report saved to: $REPAIR_SUMMARY"
    cat "$REPAIR_SUMMARY"
}

# =============================================================================
# MAIN EXECUTION FUNCTION
# =============================================================================

main() {
    echo "==============================================================================" | tee -a "$LOG_FILE"
    echo "NGINX SYMLINK AND MODULE REPAIR SCRIPT - $(date)" | tee -a "$LOG_FILE"
    echo "==============================================================================" | tee -a "$LOG_FILE"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    # System detection
    detect_system || {
        warning "System detection failed, using defaults"
    }
    
    # Find nginx installation
    if ! find_nginx_binary; then
        error "Cannot proceed without nginx binary"
        exit 1
    fi
    
    if ! find_nginx_config_dir; then
        error "Cannot proceed without nginx configuration directory"
        exit 1
    fi
    
    # Create backup
    create_backup || {
        warning "Failed to create complete backup, but continuing"
    }
    
    # Perform repairs - continue even if individual steps fail
    find_broken_symlinks || warning "Error during symlink detection, continuing with repair"
    repair_broken_symlinks || warning "Error during symlink repair, continuing with other repairs"
    check_nginx_modules || warning "Error during module check, continuing with other repairs"
    repair_common_config_issues || warning "Error during config repair, continuing with other repairs"
    fix_permissions || warning "Error during permission fixes, continuing with other repairs"
    check_nginx_service || warning "Error during service check, continuing with other repairs"
    
    # Iteratively test and repair nginx configuration
    info "Starting iterative configuration repair process..."
    iteratively_repair_nginx_config || warning "Some configuration issues could not be fixed automatically"
    
    # Final configuration check
    if check_nginx_configuration; then
        success "Nginx configuration is now valid"
    else
        warning "Nginx configuration still has issues - manual intervention may be required"
        
        # Show detailed error information
        local test_output=$($NGINX_BINARY -t 2>&1)
        echo "\nDetailed configuration errors:"
        echo "$test_output"
        echo ""
        
        # Provide specific recommendations based on error patterns
        if echo "$test_output" | grep -q "open() \"/etc/nginx/modules-enabled/.*\" failed"; then
            info "Recommendation: Install the missing module packages or create the required configuration files manually"
            echo "You can try: apt-get install libnginx-mod-* nginx-extras"
        fi
        
        # Ask about reinstallation as a last resort
        reinstall_nginx_if_needed || warning "Reinstallation attempt failed"
    fi
    
    # Generate report
    generate_repair_report || warning "Failed to generate complete report"
    
    log "Nginx repair process completed!"
    info "Check the repair report above for details and recommendations"
    
    return 0
}

# Add a helper function to handle timeouts
run_with_timeout() {
    local cmd="$1"
    local timeout="$2"
    local description="$3"
    
    info "Running: $description"
    timeout "$timeout" bash -c "$cmd" 2>/dev/null
    local status=$?
    
    if [[ $status -eq 124 ]]; then
        warning "Command timed out after ${timeout}s: $description"
        return 1
    elif [[ $status -ne 0 ]]; then
        warning "Command failed with status $status: $description"
        return $status
    fi
    
    return 0
}

# Add a progress display function
show_progress() {
    local message="$1"
    local current="$2"
    local total="$3"
    local width=50
    
    # Calculate percentage
    local percent=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    # Create progress bar
    local bar="["
    for ((i=0; i<filled; i++)); do bar+="#"; done
    for ((i=0; i<empty; i++)); do bar+=" "; done
    bar+="]"
    
    # Print progress
    printf "\r${BLUE}[INFO]${NC} %s: %s %3d%% (%d/%d)" "$message" "$bar" "$percent" "$current" "$total"
}

# More robust error handling
trap 'last_status=$?; error "Repair script failed at line $LINENO with status $last_status. Check $LOG_FILE for details."; exit $last_status' ERR

# Execute main function
main "$@" 2>&1 | tee -a "$LOG_FILE"