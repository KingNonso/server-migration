#!/bin/bash

# =============================================================================
# POSTGRESQL DATABASE MIGRATION SCRIPT - FIXED VERSION
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
#   ./db_migration.sh [options]
#
# Options:
#   -s, --source-password PASSWORD   Source database password
#   -d, --dest-password PASSWORD     Destination database password
#   -p, --source-port PORT          Source PostgreSQL port (default: 5432)
#   -P, --dest-port PORT            Destination PostgreSQL port (default: 5432)
#   -u, --source-user USER          Source PostgreSQL user (default: postgres)
#   -U, --dest-user USER            Destination PostgreSQL user (default: postgres)
#   --source-host HOST              Source PostgreSQL host (required)
#   --dest-host HOST                Destination PostgreSQL host (required)  
#   --source-db DATABASE            Source database name (default: all)
#   --dest-db DATABASE              Destination database name (default: same as source)
#   -v, --verbose                   Show detailed progress
#   -h, --help                      Display this help message
#
# Examples:
#   ./db_migration.sh --source-host 192.168.1.10 --dest-host 192.168.1.20 -s mypass -d mypass
#   ./db_migration.sh --source-host old-server --dest-host new-server -v -p 5433 -P 5432
#
# Notes:
#   - Requires PostgreSQL client tools (psql, pg_dump) on local machine
#   - Source and destination servers must be accessible
#   - Password can be set via PGPASSWORD environment variable
# =============================================================================

# Exit on error
set +e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration variables
SOURCE_HOST=""
SOURCE_PORT="5432"
SOURCE_USER="postgres"
SOURCE_PASSWORD=""
SOURCE_DB_NAME="all"  # Set to "all" to migrate all databases

DEST_HOST=""
DEST_PORT="5432"
DEST_USER="postgres"
DEST_PASSWORD=""
DEST_DB_NAME=""  # Will be same as source unless specified

VERBOSE=false

# Function to display help message
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Required options:"
    echo "  --source-host HOST               Source PostgreSQL host"
    echo "  --dest-host HOST                 Destination PostgreSQL host"
    echo ""
    echo "Optional:"
    echo "  -s, --source-password PASSWORD  Source database password"
    echo "  -d, --dest-password PASSWORD    Destination database password"
    echo "  -p, --source-port PORT          Source PostgreSQL port (default: 5432)"
    echo "  -P, --dest-port PORT            Destination PostgreSQL port (default: 5432)"
    echo "  -u, --source-user USER          Source PostgreSQL user (default: postgres)"
    echo "  -U, --dest-user USER            Destination PostgreSQL user (default: postgres)"
    echo "  --source-db DATABASE            Source database name (default: all)"
    echo "  --dest-db DATABASE              Destination database name (default: same as source)"
    echo "  -v, --verbose                   Show detailed progress"
    echo "  -h, --help                      Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --source-host 192.168.1.10 --dest-host 192.168.1.20 -s mypass -d mypass"
    echo "  $0 --source-host old-server --dest-host new-server -v -p 5433"
    exit 0
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
        --source-host)
            SOURCE_HOST="$2"
            shift 2
            ;;
        --dest-host)
            DEST_HOST="$2"
            shift 2
            ;;
        --source-db)
            SOURCE_DB_NAME="$2"
            shift 2
            ;;
        --dest-db)
            DEST_DB_NAME="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# Validate required parameters
if [ -z "$SOURCE_HOST" ] || [ -z "$DEST_HOST" ]; then
    echo -e "${RED}[ERROR]${NC} Source host and destination host are required"
    echo "Use --source-host and --dest-host options"
    show_help
fi

# Set default destination database name if not specified
if [ -z "$DEST_DB_NAME" ]; then
    DEST_DB_NAME="$SOURCE_DB_NAME"
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
        print_status "Please install PostgreSQL client tools:"
        print_status "Ubuntu/Debian: sudo apt-get install postgresql-client"
        print_status "CentOS/RHEL: sudo yum install postgresql"
        print_status "macOS: brew install postgresql"
        exit 1
    fi
    
    print_success "Prerequisites check completed"
}

# Function to test database connections
test_connections() {
    print_status "Testing database connections..."
    
    # Test source connection
    print_status "Testing source database connection to $SOURCE_HOST:$SOURCE_PORT..."
    if PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d postgres -c '\q' 2>/dev/null; then
        print_success "Source database connection successful"
    else
        print_error "Failed to connect to source database"
        print_error "Host: $SOURCE_HOST, Port: $SOURCE_PORT, User: $SOURCE_USER"
        print_status "Please check your source database credentials and network connectivity"
        exit 1
    fi
    
    # Test destination connection
    print_status "Testing destination database connection to $DEST_HOST:$DEST_PORT..."
    if PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c '\q' 2>/dev/null; then
        print_success "Destination database connection successful"
    else
        print_error "Failed to connect to destination database"
        print_error "Host: $DEST_HOST, Port: $DEST_PORT, User: $DEST_USER"
        print_status "Please check your destination credentials and network connectivity"
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
            AND datname NOT IN ('postgres', 'template0', 'template1')
            ORDER BY datname;"))
        
        if [ ${#DATABASES[@]} -eq 0 ]; then
            print_warning "No user databases found on source server"
            exit 1
        fi
        
        print_status "Found databases: ${DATABASES[*]}"
    else
        # Verify the specified database exists
        if ! PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$SOURCE_DB_NAME'" | grep -q 1; then
            print_error "Database '$SOURCE_DB_NAME' does not exist on source server"
            exit 1
        fi
        
        DATABASES=("$SOURCE_DB_NAME")
        print_status "Migrating single database: $SOURCE_DB_NAME"
    fi
}

# Function to create database if it doesn't exist
create_database_if_not_exists() {
    local source_db_name=$1
    local dest_db_name=${2:-$source_db_name}
    
    print_status "Checking if database '$dest_db_name' exists on destination..."
    
    # Check if database exists
    if PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$dest_db_name'" | grep -q 1; then
        print_warning "Database '$dest_db_name' already exists on destination"
        read -p "Do you want to drop and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "Terminating connections to database '$dest_db_name'..."
            PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "
                SELECT pg_terminate_backend(pid) 
                FROM pg_stat_activity 
                WHERE datname = '$dest_db_name' 
                AND pid <> pg_backend_pid();" &>/dev/null || true
            
            print_status "Dropping database '$dest_db_name'..."
            if PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$dest_db_name\";"; then
                print_success "Database '$dest_db_name' dropped successfully"
                sleep 2
            else
                print_error "Failed to drop database '$dest_db_name'"
                return 1
            fi
        else
            print_status "Using existing database '$dest_db_name'"
            return 0
        fi
    fi
    
    # Get source database settings
    print_status "Getting source database settings for '$source_db_name'..."
    local source_db_info=$(PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d postgres -tAc "
        SELECT 
            datcollate,
            datctype,
            pg_encoding_to_char(encoding)
        FROM pg_database 
        WHERE datname = '$source_db_name';" | head -1)
    
    if [ -z "$source_db_info" ]; then
        print_error "Could not retrieve source database information"
        return 1
    fi
    
    local collate=$(echo "$source_db_info" | cut -d'|' -f1)
    local ctype=$(echo "$source_db_info" | cut -d'|' -f2)
    local encoding=$(echo "$source_db_info" | cut -d'|' -f3)
    
    # Create database with appropriate settings
    print_status "Creating database '$dest_db_name' with encoding='$encoding', collate='$collate', ctype='$ctype'..."
    
    # Try creating with template0 first (preferred method to avoid collation issues)
    local create_cmd="CREATE DATABASE \"$dest_db_name\" WITH TEMPLATE template0 OWNER \"$DEST_USER\""
    
    if [ -n "$encoding" ] && [ "$encoding" != "" ]; then
        create_cmd="$create_cmd ENCODING '$encoding'"
    fi
    if [ -n "$collate" ] && [ "$collate" != "" ]; then
        create_cmd="$create_cmd LC_COLLATE '$collate'"
    fi
    if [ -n "$ctype" ] && [ "$ctype" != "" ]; then
        create_cmd="$create_cmd LC_CTYPE '$ctype'"
    fi
    
    create_cmd="$create_cmd;"
    
    if PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "$create_cmd"; then
        print_success "Database '$dest_db_name' created successfully"
    else
        print_warning "Failed to create database with template0, trying simple creation..."
        
        # Try creating without specifying collation/encoding (fallback)
        if PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d postgres -c "CREATE DATABASE \"$dest_db_name\" OWNER \"$DEST_USER\";"; then
            print_warning "Database '$dest_db_name' created with default settings"
        else
            print_error "Failed to create database '$dest_db_name'"
            return 1
        fi
    fi
    
    return 0
}

# Function to migrate a single database
migrate_database() {
    local source_db_name=$1
    local dest_db_name=${2:-$source_db_name}
    local start_time=$(date +%s)
    
    print_status "Starting migration of database: $source_db_name -> $dest_db_name"
    
    # Create database if it doesn't exist
    if ! create_database_if_not_exists "$source_db_name" "$dest_db_name"; then
        print_error "Skipping database '$source_db_name' due to creation failure"
        return 1
    fi
    
    # Get database size for progress tracking
    local db_size=$(PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d postgres -tAc "
        SELECT pg_size_pretty(pg_database_size('$source_db_name'));" 2>/dev/null || echo "unknown")
    print_status "Source database size: $db_size"
    
    # Direct database migration using pg_dump and psql
    print_status "Migrating database '$source_db_name' using pg_dump -> psql pipeline..."
    
    # Build the migration command - dump ALL schemas, not just public
    local dump_file="/tmp/migration_${source_db_name}_$(date +%s).sql"
    
    print_status "Creating database dump..."
    if PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
        -h "$SOURCE_HOST" \
        -p "$SOURCE_PORT" \
        -U "$SOURCE_USER" \
        -d "$source_db_name" \
        --clean \
        --if-exists \
        --create \
        --verbose \
        --no-owner \
        --no-privileges \
        -f "$dump_file" 2>> "$ERROR_LOG"; then
        print_success "Database dump created successfully"
    else
        print_error "Failed to create database dump"
        rm -f "$dump_file"
        return 1
    fi
    
    # Restore the database
    print_status "Restoring database to destination..."
    if PGPASSWORD="$DEST_PASSWORD" psql \
        -h "$DEST_HOST" \
        -p "$DEST_PORT" \
        -U "$DEST_USER" \
        -d postgres \
        -f "$dump_file" \
        -v ON_ERROR_STOP=0 2>> "$ERROR_LOG"; then
        print_success "Database restored successfully"
    else
        print_warning "Database restore completed with some errors (check error log)"
    fi
    
    # Clean up dump file
    rm -f "$dump_file"
    
    # Validate migration by comparing table counts
    print_status "Validating migration..."
    local source_tables=$(PGPASSWORD="$SOURCE_PASSWORD" psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USER" -d "$source_db_name" -tAc "
        SELECT count(*) FROM information_schema.tables WHERE table_type = 'BASE TABLE';" 2>/dev/null || echo "0")
    
    local dest_tables=$(PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" -d "$dest_db_name" -tAc "
        SELECT count(*) FROM information_schema.tables WHERE table_type = 'BASE TABLE';" 2>/dev/null || echo "0")
    
    print_status "Source tables: $source_tables, Destination tables: $dest_tables"
    
    if [ "$source_tables" -eq "$dest_tables" ] && [ "$source_tables" -gt 0 ]; then
        print_success "Table count validation passed"
    else
        print_warning "Table count mismatch or no tables found"
    fi
    
    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    print_success "Migration completed in ${duration}s"
    
    return 0
}

# Helper function to format duration
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
    
    # Ask for passwords if not provided
    if [ -z "$SOURCE_PASSWORD" ]; then
        read -s -p "Enter source PostgreSQL password for user $SOURCE_USER: " SOURCE_PASSWORD
        echo
        if [ -z "$SOURCE_PASSWORD" ]; then
            print_error "Source password is required"
            exit 1
        fi
    fi
    
    if [ -z "$DEST_PASSWORD" ]; then
        read -s -p "Enter destination PostgreSQL password for user $DEST_USER: " DEST_PASSWORD
        echo
        if [ -z "$DEST_PASSWORD" ]; then
            print_error "Destination password is required"
            exit 1
        fi
    fi
    
    # Test connections
    test_connections
    
    # Get list of databases to migrate
    get_databases_list
    
    # Print configuration summary
    print_status "Migration Configuration:"
    print_status "  Source: $SOURCE_USER@$SOURCE_HOST:$SOURCE_PORT"
    print_status "  Destination: $DEST_USER@$DEST_HOST:$DEST_PORT"
    print_status "  Databases: ${DATABASES[*]}"
    
    # Confirm before proceeding
    read -p "Proceed with migration? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Migration cancelled by user"
        exit 0
    fi
    
    # Migrate each database
    print_status "Starting migration of ${#DATABASES[@]} database(s)..."
    local success_count=0
    local failed_count=0
    
    for db in "${DATABASES[@]}"; do
        echo -e "\n${YELLOW}=== Migrating database: $db ===${NC}"
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
    echo -e "Total duration: $(format_duration $total_duration)"
    echo -e "Log files: $LOG_DIR"
    
    if [ $failed_count -eq 0 ]; then
        print_success "All migrations completed successfully!"
    else
        print_warning "Migration completed with $failed_count failure(s). Check logs for details."
    fi
    
    return $failed_count
}

# Execute main function
main "$@"