#!/bin/bash

# =============================================================================
# POSTGRESQL DATABASE MIGRATION SCRIPT
# =============================================================================
#
# Description:
#   Efficient PostgreSQL database migration tool that performs:
#   - Direct table and data copying using pg_dump/psql
#   - Automatic database creation with proper encoding
#   - Version compatibility checks
#   - Progress monitoring and reporting
#
# Usage:
#   ./db_migration.sh [options] [source_host] [dest_host]
#
# Arguments:
#   source_host     Source server hostname/IP (required)
#   dest_host       Destination server hostname/IP (required)
#
# Options:
#   -s, --source-password PASSWORD   Source database password
#   -d, --dest-password PASSWORD     Destination database password
#   -p, --source-port PORT          Source PostgreSQL port (default: 5432)
#   -P, --dest-port PORT            Destination PostgreSQL port (default: 5432)
#   -u, --source-user USER          Source PostgreSQL user (default: postgres)
#   -U, --dest-user USER            Destination PostgreSQL user (default: postgres)
#   -v, --verbose                   Show detailed progress
#   -h, --help                      Display this help message
#
# Examples:
#   ./db_migration.sh -s mypass -d mypass 192.168.1.10 192.168.1.20
#   ./db_migration.sh -v -p 5433 -P 5432 old-server new-server
#
# Notes:
#   - Requires PostgreSQL client tools (psql, pg_dump) on local machine
#   - Source and destination servers must be accessible
#   - Password can be set via PGPASSWORD environment variable
# =============================================================================

# Don't exit on error, we'll handle errors manually
set +e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables - MODIFY THESE
SOURCE_HOST="178.128.169.33"
SOURCE_PORT="5432"
SOURCE_USER="postgres"
SOURCE_DB_NAME="all"  # Set to "all" to migrate all databases

DEST_HOST="localhost"  # Usually localhost on destination server
DEST_PORT="5432"
DEST_USER="postgres"
DEST_DB_NAME="$SOURCE_DB_NAME"  # Will be same as source unless specified

# Parse command line arguments
SOURCE_PASSWORD=""
DEST_PASSWORD=""
VERBOSE=false

# Function to display help message
show_help() {
    echo "Usage: $0 [options] source_host dest_host"
    echo ""
    echo "Arguments:"
    echo "  source_host     Source server hostname/IP (required)"
    echo "  dest_host       Destination server hostname/IP (required)"
    echo ""
    echo "Options:"
    echo "  -s, --source-password PASSWORD   Source database password"
    echo "  -d, --dest-password PASSWORD     Destination database password"
    echo "  -p, --source-port PORT          Source PostgreSQL port (default: 5432)"
    echo "  -P, --dest-port PORT            Destination PostgreSQL port (default: 5432)"
    echo "  -u, --source-user USER          Source PostgreSQL user (default: postgres)"
    echo "  -U, --dest-user USER            Destination PostgreSQL user (default: postgres)"
    echo "  -v, --verbose                   Show detailed progress"
    echo "  -h, --help                      Display this help message"
    echo ""
    echo "Example:"
    echo "  $0 -s mypass -d mypass -p 5433 old-server new-server"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--source-password)
            SOURCE_PASSWORD="$2"
            shift 2
            ;;
        -d|--dest-password)
            DEST_PASSWORD="$2"
            shift 2
            ;;
        -p|--source-port)
            SOURCE_PORT="$2"
            shift 2
            ;;
        -P|--dest-port)
            DEST_PORT="$2"
            shift 2
            ;;
        -u|--source-user)
            SOURCE_USER="$2"
            shift 2
            ;;
        -U|--dest-user)
            DEST_USER="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        -*)
            echo "Unknown option: $1"
            show_help
            ;;
        *)
            if [ -z "$SOURCE_HOST" ]; then
                SOURCE_HOST="$1"
            elif [ -z "$DEST_HOST" ]; then
                DEST_HOST="$1"
            else
                echo "Error: Unexpected argument '$1'"
                show_help
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$SOURCE_HOST" ] || [ -z "$DEST_HOST" ]; then
    echo "Error: Both source_host and dest_host are required"
    show_help
fi

# Simple logging setup
LOG_DIR="/tmp/postgres_migration_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/migration.log"
ERROR_LOG="$LOG_DIR/errors.log"

# Function to initialize logging
init_logging() {
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    # Create or clear log files
    : > "$LOG_FILE"
    : > "$ERROR_LOG"
    
    # Set permissions
    chmod 700 "$LOG_DIR"
    chmod 600 "$LOG_FILE" "$ERROR_LOG"
    
    echo -e "${BLUE}[INFO]${NC} Logging initialized in: $LOG_DIR"
}

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

# Check if required tools are installed
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Required tools
    local required_tools=("pg_dump" "psql")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_status "Installing missing tools..."
        sudo apt-get update
        sudo apt-get install -y postgresql-client
        
        # Check again after installation
        for tool in "${required_tools[@]}"; do
            if ! command -v "$tool" &> /dev/null; then
                print_error "Failed to install $tool. Exiting."
                exit 1
            fi
        done
    fi
    
    print_success "Prerequisites check completed"
}

# Function to test database connections
test_connections() {
    print_status "Testing database connections..."
    
    # Test source connection
    print_status "Testing source database connection..."
    if PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d postgres -c '\q' 2>/dev/null; then
        print_success "Source database connection successful"
    else
        print_error "Failed to connect to source database"
        print_status "Please check your source database credentials and network connectivity"
        exit 1
    fi
    
    # Test destination connection
    print_status "Testing destination database connection..."
    if PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c '\q' 2>/dev/null; then
        print_success "Destination database connection successful"
    else
        print_error "Failed to connect to destination database"
        print_status "Please check your destination credentials"
        exit 1
    fi
}

# Get list of databases to migrate
get_databases_list() {
    if [ "$SOURCE_DB_NAME" = "all" ]; then
        print_status "Getting list of all databases from source..."
        
        # Get database names, excluding system databases
        DATABASES=($(PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d postgres -tAc "
            SELECT datname FROM pg_database 
            WHERE datistemplate = false 
            AND datname NOT IN ('postgres', 'template0', 'template1');"))
        
        print_status "Found databases: ${DATABASES[*]}"
    else
        DATABASES=("$SOURCE_DB_NAME")
        print_status "Migrating single database: $SOURCE_DB_NAME"
    fi
}

# Function to create database if it doesn't exist
create_database_if_not_exists() {
    local db_name=$1
    
    print_status "Checking if database '$db_name' exists on destination..."
    
    # Check if database exists
    if PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$db_name'" | grep -q 1; then
        print_warning "Database '$db_name' already exists on destination"
        read -p "Do you want to drop and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "Dropping existing database '$db_name'..."
            # Terminate all connections to the database
            PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "
                SELECT pg_terminate_backend(pid) 
                FROM pg_stat_activity 
                WHERE datname = '$db_name' 
                AND pid <> pg_backend_pid();"
            
            # Drop the database
            PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$db_name\";"
            
            # Add a small delay to ensure the database is fully dropped
            sleep 2
        else
            print_status "Using existing database '$db_name'"
            return 0
        fi
    fi
    
    # Create the database using template0 to avoid collation issues
    print_status "Creating database '$db_name'..."
    PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "CREATE DATABASE \"$db_name\" TEMPLATE template0;"
    
    if [ $? -eq 0 ]; then
        print_success "Database '$db_name' created successfully"
        return 0
    else
        print_error "Failed to create database '$db_name'"
        # Try a simpler approach
        print_status "Trying simplified database creation..."
        PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "CREATE DATABASE \"$db_name\";"
        
        if [ $? -eq 0 ]; then
            print_success "Database '$db_name' created with simplified command"
            return 0
        else
            print_error "All attempts to create database '$db_name' failed"
            return 1
        fi
    fi
}

# Function to migrate a single database
migrate_database() {
    local db_name=$1
    local start_time=$(date +%s)
    
    print_status "Starting migration of database: $db_name"
    
    # Create database if it doesn't exist
    if ! create_database_if_not_exists "$db_name"; then
        print_error "Skipping database '$db_name' due to creation failure"
        return 1
    fi
    
    # Migrate extensions if they exist
    print_status "Checking for extensions in database '$db_name'..."
    local extensions=$(PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d "$db_name" -tAc "
        SELECT extname FROM pg_extension WHERE extname NOT IN ('plpgsql');")
    
    while IFS= read -r ext; do
        ext=$(echo "$ext" | tr -d ' ')
        if [ ! -z "$ext" ]; then
            print_status "Installing extension: $ext"
            PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d "$db_name" -c "CREATE EXTENSION IF NOT EXISTS \"$ext\";"
        fi
    done <<< "$extensions"
    
    # Direct database migration using pg_dump and pg_restore
    print_status "Migrating database '$db_name'..."
    
    # First migrate global objects (roles, tablespaces)
    print_status "Migrating global objects..."
    # Dump global objects but filter out CREATE ROLE statements for existing roles
    PGPASSWORD="$SOURCE_PASSWORD" pg_dumpall -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" --globals-only | \
    grep -v '^CREATE ROLE' | \
    PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres 2>&1 | \
    grep -v 'ERROR:.*role.*already exists'

    # Get source database size for progress tracking
    local db_size=$(PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d "$db_name" -tAc "SELECT pg_database_size('$db_name')")
    print_status "Database size: $(numfmt --to=iec-i --suffix=B $db_size)"

    # Create temporary directory with cleanup trap
    local tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT
    local dump_file="$tmp_dir/${db_name}_dump"

    # Build and execute dump command with progress tracking
    print_status "Dumping database..."
    local dump_cmd="PGPASSWORD=\"$SOURCE_PASSWORD\" pg_dump \
        -h \"$SOURCE_HOST\" \
        -p \"$SOURCE_PORT\" \
        -U \"$SOURCE_USER\" \
        -d \"$db_name\" \
        --clean \
        --if-exists \
        --create \
        --format=custom \
        -Z 9 \
        -F c \
        -b \
        -v \
        -f \"$dump_file\""

    # Log the command (without passwords)
    local log_cmd=$(echo "$dump_cmd" | sed "s/PGPASSWORD=\"[^\"]*\"/PGPASSWORD=\"******\"/g")
    print_status "Running: $log_cmd"

    # Execute dump with progress tracking
    local dump_result=0
    eval "$dump_cmd" 2>> "$ERROR_LOG" || dump_result=$?

    # Validate dump file
    if [ $dump_result -eq 0 ] && [ -f "$dump_file" ]; then
        # Get file size in a cross-platform way (works on both macOS and Linux)
        local dump_size
        if [[ "$(uname)" == "Darwin" ]]; then
            dump_size=$(stat -f%z "$dump_file")
        else
            dump_size=$(stat --format=%s "$dump_file")
        fi
        print_status "Dump file size: $(numfmt --to=iec-i --suffix=B $dump_size)"
        
        if [ $dump_size -eq 0 ]; then
            print_error "Dump file is empty. Migration failed."
            return 1
        fi

        # Build and execute restore command
        print_status "Restoring database..."
        local restore_cmd="PGPASSWORD=\"$DEST_PASSWORD\" pg_restore \
            -h \"$DEST_HOST\" \
            -p \"$DEST_PORT\" \
            -U \"$DEST_USER\" \
            -d postgres \
            --clean \
            --if-exists \
            --create \
            -v \
            \"$dump_file\""

        # Log the command (without passwords)
        local log_cmd=$(echo "$restore_cmd" | sed "s/PGPASSWORD=\"[^\"]*\"/PGPASSWORD=\"******\"/g")
        print_status "Running: $log_cmd"

        # Execute restore with retry logic
        local restore_result=0
        local retry_count=0
        local max_retries=3

        while [ $retry_count -lt $max_retries ]; do
            eval "$restore_cmd" 2>> "$ERROR_LOG" && break
            restore_result=$?
            ((retry_count++))
            
            if [ $retry_count -lt $max_retries ]; then
                print_warning "Restore attempt $retry_count failed. Retrying in 5 seconds..."
                sleep 5
            fi
        done

        if [ $retry_count -eq $max_retries ]; then
            print_error "Failed to restore database after $max_retries attempts"
            return 1
        fi

        local migration_result=$restore_result
    else
        print_error "Failed to create dump file"
        return 1
    fi
    
    if [ $migration_result -eq 0 ]; then
        print_success "Database '$db_name' migrated successfully"
    else
        print_error "Failed to migrate database '$db_name' (error code: $migration_result)"
        print_error "Check $ERROR_LOG for details"
        return $migration_result
    fi
    
    # Update sequences
    print_status "Updating sequences for database '$db_name'..."
    PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d "$db_name" -c "
        DO $$
        DECLARE
            seq_record RECORD;
        BEGIN
            FOR seq_record IN 
                SELECT n.nspname as schema_name, c.relname as seq_name, 
                       replace(c.relname, '_seq', '') as table_name
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind = 'S'
                AND n.nspname NOT IN ('pg_catalog', 'information_schema')
            LOOP
                BEGIN
                    EXECUTE 'SELECT setval(''' || 
                            seq_record.schema_name || '.' || 
                            seq_record.seq_name || ''', 
                            (SELECT COALESCE(MAX(id), 1) FROM ' || 
                            seq_record.schema_name || '.' || 
                            seq_record.table_name || '), false)';
                EXCEPTION WHEN OTHERS THEN
                    -- Ignore errors
                    RAISE NOTICE 'Could not update sequence %', seq_record.seq_name;
                END;
            END LOOP;
        END $$;
    " 2>/dev/null
    
    # Validate migration
    local table_count=$(PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d "$db_name" -tAc "
        SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")
    
    print_status "Database '$db_name' migrated with $table_count tables"
    
    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    print_success "Migration completed in $duration seconds"
    
    return 0
}

# Main function to orchestrate the migration process
main() {
    local start_time=$(date +%s)
    
    # Print banner
    echo -e "\n${BLUE}=========================================${NC}"
    echo -e "${BLUE}  PostgreSQL Database Migration Tool    ${NC}"
    echo -e "${BLUE}=========================================${NC}\n"
    
    # Initialize logging
    init_logging
    
    # Check prerequisites
    check_prerequisites
    
    # Ask for passwords if not provided via command-line arguments
    if [ -z "$SOURCE_PASSWORD" ]; then
        read -s -p "Enter source PostgreSQL password for user $SOURCE_USER: " SOURCE_PASSWORD
        echo
        if [ -z "$SOURCE_PASSWORD" ]; then
            print_error "Source password is required"
            exit 1
        fi
    else
        print_status "Using provided source password from command-line arguments"
    fi
    
    if [ -z "$DEST_PASSWORD" ]; then
        read -s -p "Enter destination PostgreSQL password for user $DEST_USER: " DEST_PASSWORD
        echo
        if [ -z "$DEST_PASSWORD" ]; then
            print_error "Destination password is required"
            exit 1
        fi
    else
        print_status "Using provided destination password from command-line arguments"
    fi
    
    # Test connections
    test_connections
    
    # Get list of databases to migrate
    get_databases_list
    
    # Migrate each database
    print_status "Starting migration of ${#DATABASES[@]} databases..."
    local success_count=0
    local failed_count=0
    
    for db in "${DATABASES[@]}"; do
        print_status "\n${YELLOW}=== Migrating database: $db ===${NC}"
        if migrate_database "$db"; then
            success_count=$((success_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi
    done
    
    # Calculate total duration
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    
    # Print summary
    echo -e "\n${BLUE}=========================================${NC}"
    echo -e "${BLUE}  Migration Summary                    ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo -e "Total databases: ${#DATABASES[@]}"
    echo -e "Successfully migrated: $success_count"
    echo -e "Failed: $failed_count"
    echo -e "Total duration: $total_duration seconds"
    echo -e "Log files are available in: $LOG_DIR"
    
    if [ $failed_count -eq 0 ]; then
        print_success "\nMigration completed successfully!"
    else
        print_warning "\nMigration completed with issues. Check logs for details."
    fi
    
    return $failed_count
}

# Execute main function
main

# Get list of databases to migrate
get_databases_list() {
    if [ "$SOURCE_DB_NAME" = "all" ]; then
        print_status "Getting list of all databases from source..."
        
        # Get database names, excluding system databases
        DATABASES=($(PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d postgres -tAc "
            SELECT datname FROM pg_database 
            WHERE datistemplate = false 
            AND datname NOT IN ('postgres', 'template0', 'template1');"))
        
        print_status "Found databases: ${DATABASES[*]}"
    else
        DATABASES=("$SOURCE_DB_NAME")
        print_status "Migrating single database: $SOURCE_DB_NAME"
    fi
}

# Function to create database if it doesn't exist
create_database_if_not_exists() {
    local db_name=$1
    
    print_status "Checking if database '$db_name' exists on destination..."
    
    # Check if database exists
    if PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
        print_warning "Database '$db_name' already exists on destination"
        read -p "Do you want to drop and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "Terminating connections to database '$db_name'..."
            PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "
                SELECT pg_terminate_backend(pid) 
                FROM pg_stat_activity 
                WHERE datname = '$db_name' 
                AND pid <> pg_backend_pid();" > /dev/null 2>&1
            
            print_status "Dropping database '$db_name'..."
            if PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "DROP DATABASE \"$db_name\";"; then
                print_success "Database '$db_name' dropped successfully"
                # Add a small delay to ensure the database is fully dropped
                sleep 2
            else
                print_error "Failed to drop database '$db_name'"
                return 1
            fi
        else
            print_status "Using existing database '$db_name'"
            return 0
        fi
    fi
    
    # Get source database settings
    local source_db_info=$(PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d postgres -tAc "
        SELECT 
            datcollate,
            datctype,
            pg_encoding_to_char(encoding)
        FROM pg_database 
        WHERE datname = '$db_name';")
    
    local collate=$(echo "$source_db_info" | awk -F'|' '{print $1}' | tr -d ' ')
    local ctype=$(echo "$source_db_info" | awk -F'|' '{print $2}' | tr -d ' ')
    local encoding=$(echo "$source_db_info" | awk -F'|' '{print $3}' | tr -d ' ')
    
    # Create database with appropriate settings
    print_status "Creating database '$db_name' with LC_COLLATE='$collate', LC_CTYPE='$ctype', ENCODING='$encoding'..."
    
    # Try creating with template0 first (preferred method to avoid collation issues)
    if PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "CREATE DATABASE \"$db_name\" WITH TEMPLATE template0 OWNER \"$DEST_USER\" LC_COLLATE '$collate' LC_CTYPE '$ctype' ENCODING '$encoding';"; then
        print_success "Database '$db_name' created successfully with template0"
    else
        print_warning "Failed to create database with template0, trying alternative method..."
        
        # Try creating without specifying collation/encoding (fallback)
        if PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "CREATE DATABASE \"$db_name\" OWNER \"$DEST_USER\";"; then
            print_warning "Database '$db_name' created with default settings (collation/encoding may differ from source)"
        else
            print_error "Failed to create database '$db_name'"
            return 1
        fi
    fi
    
    return 0
}

# Function to check PostgreSQL version compatibility
check_pg_version_compatibility() {
    print_status "Checking PostgreSQL version compatibility..."
    
    # Get source version
    local source_version=$(PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d postgres -tAc "SHOW server_version;" | awk -F. '{print $1}')
    
    # Get destination version
    local dest_version=$(PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -tAc "SHOW server_version;" | awk -F. '{print $1}')
    
    print_status "Source PostgreSQL version: $source_version, Destination PostgreSQL version: $dest_version"
    
    # Check if versions are compatible
    if [ "$source_version" != "$dest_version" ]; then
        print_warning "PostgreSQL major versions are different. This may cause compatibility issues."
        print_warning "Source: $source_version, Destination: $dest_version"
        
        if [ "$source_version" -gt "$dest_version" ]; then
            print_error "Source version is newer than destination. Migration may fail."
            print_error "Consider upgrading destination PostgreSQL to version $source_version or higher."
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_error "Migration aborted due to version incompatibility"
                exit 1
            fi
        else
            print_warning "Destination version is newer than source. Some features may not be migrated correctly."
            read -p "Continue? (Y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                print_error "Migration aborted by user"
                exit 1
            fi
        fi
    else
        print_success "PostgreSQL versions are compatible"
    fi
}
                echo "    - Size: $size"
                echo "    - Tables: $tables"
# Helper function to format duration in human-readable format
format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    
    if [ $hours -gt 0 ]; then
        printf "%dh %dm %ds" $hours $minutes $secs
    elif [ $minutes -gt 0 ]; then
        printf "%dm %ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

# Execute main function
main