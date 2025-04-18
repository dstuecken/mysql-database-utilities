#!/bin/bash

# Default values
DB_USER="root"
DB_PASS=""
DB_HOST=""  # Empty means use local socket
DATABASES=""  # List of databases to export (comma-separated)
OUTPUT_FILE="database_export.sql"  # Default output file name
OUTPUT_DIR="./exports"  # Default output directory
COMPRESS=false  # Whether to compress the output file
MAX_ALLOWED_PACKET="1G"  # Maximum allowed packet size
NET_BUFFER_LENGTH="16384"  # Network buffer length
SINGLE_TRANSACTION=true  # Use single transaction for InnoDB
LOCK_TABLES=false  # Whether to lock tables during export
EXCLUDE_TABLES=""  # Tables to exclude (comma-separated)
SHOW_PROGRESS=true  # Whether to show progress information
# New MySQL option flags
SKIP_ADD_LOCKS=false    # Whether to skip adding locks in SQL output
NO_CREATE_INFO=false    # Whether to skip table creation statements
SKIP_LOCK_TABLES=false  # Whether to skip locking tables during export
NO_TABLESPACES=false    # Whether to skip tablespace information
# Data and structure export options
STRUCTURE_ONLY=false    # Whether to export only the database structure
DATA_ONLY=false         # Whether to export only the data

# Display usage instructions
usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -u, --user USERNAME     Database username (default: root)"
  echo "  -w, --password PASS     Database password (default: empty)"
  echo "  -h, --host HOST         Database host (default: local socket)"
  echo "  -d, --databases DB[,DB] Databases to export (comma-separated, required)"
  echo "  -f, --file FILENAME     Output file name (default: database_export.sql)"
  echo "  -o, --output DIR        Output directory (default: ./exports)"
  echo "  -z, --compress          Compress output file(s) with gzip"
  echo "  -m, --max-packet SIZE   Max allowed packet size (default: 1G)"
  echo "  -n, --net-buffer SIZE   Network buffer length (default: 16384)"
  echo "  -t, --lock-tables       Lock all tables during export (default: false)"
  echo "  -s, --skip-transaction  Skip using single transaction (default: use transaction)"
  echo "  -x, --exclude TABLES    Tables to exclude (comma-separated, format: db.table)"
  echo "  -q, --quiet             Disable progress reporting"
  echo "  --skip-add-locks        Skip adding locks in SQL output"
  echo "  --no-create-info        Skip table creation information"
  echo "  --skip-lock-tables      Skip locking tables during export"
  echo "  --no-tablespaces        Skip tablespace information"
  echo "  --structure-only        Export only the database structure (no data)"
  echo "  --data-only             Export only the data (no create statements)"
  echo "  --help                  Display this help message"
  exit 1
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -u|--user) DB_USER="$2"; shift ;;
    -w|--password) DB_PASS="$2"; shift ;;
    -h|--host) DB_HOST="$2"; shift ;;
    -d|--databases) DATABASES="$2"; shift ;;
    -f|--file) OUTPUT_FILE="$2"; shift ;;
    -o|--output) OUTPUT_DIR="$2"; shift ;;
    -z|--compress) COMPRESS=true ;;
    -m|--max-packet) MAX_ALLOWED_PACKET="$2"; shift ;;
    -n|--net-buffer) NET_BUFFER_LENGTH="$2"; shift ;;
    -t|--lock-tables) LOCK_TABLES=true ;;
    -s|--skip-transaction) SINGLE_TRANSACTION=false ;;
    -x|--exclude) EXCLUDE_TABLES="$2"; shift ;;
    -q|--quiet) SHOW_PROGRESS=false ;;
    --skip-add-locks) SKIP_ADD_LOCKS=true ;;
    --no-create-info) NO_CREATE_INFO=true ;;
    --skip-lock-tables) SKIP_LOCK_TABLES=true ;;
    --no-tablespaces) NO_TABLESPACES=true ;;
    --structure-only) STRUCTURE_ONLY=true ;;
    --data-only) DATA_ONLY=true ;;
    --help) usage ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
  shift
done

# Validate required parameters
if [ -z "$DATABASES" ]; then
  echo "Error: No database(s) specified. Please use -d or --databases option."
  usage
fi

# Check for conflicting options
if [ "$STRUCTURE_ONLY" = true ] && [ "$DATA_ONLY" = true ]; then
  echo "Error: You cannot use both --structure-only and --data-only at the same time."
  usage
fi

# Data-only implies no create info
if [ "$DATA_ONLY" = true ]; then
  NO_CREATE_INFO=true
fi

# Check required utilities
if [ "$SHOW_PROGRESS" = true ]; then
  if ! command -v pv >/dev/null 2>&1; then
    echo "Warning: 'pv' command is not installed. Progress monitoring will be limited."
    HAVE_PV=false
  else
    HAVE_PV=true
  fi
fi

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"
if [ ! -d "$OUTPUT_DIR" ]; then
  echo "Error: Could not create output directory '$OUTPUT_DIR'"
  exit 1
fi

# Full output path
FULL_OUTPUT_PATH="$OUTPUT_DIR/$OUTPUT_FILE"
if [ "$COMPRESS" = true ]; then
  FULL_OUTPUT_PATH="${FULL_OUTPUT_PATH}.gz"
fi

# Configure mysqldump options
MYSQLDUMP_OPTIONS=""
MYSQLDUMP_OPTIONS+=" --user=$DB_USER"
[ -n "$DB_PASS" ] && MYSQLDUMP_OPTIONS+=" --password=$DB_PASS"
[ -n "$DB_HOST" ] && MYSQLDUMP_OPTIONS+=" --host=$DB_HOST"
MYSQLDUMP_OPTIONS+=" --max-allowed-packet=$MAX_ALLOWED_PACKET"
MYSQLDUMP_OPTIONS+=" --net-buffer-length=$NET_BUFFER_LENGTH"

# Add transactional options
if [ "$SINGLE_TRANSACTION" = true ]; then
  MYSQLDUMP_OPTIONS+=" --single-transaction"
fi

if [ "$LOCK_TABLES" = true ]; then
  MYSQLDUMP_OPTIONS+=" --lock-tables"
fi

if [ "$SKIP_LOCK_TABLES" = true ]; then
  MYSQLDUMP_OPTIONS+=" --skip-lock-tables"
fi

# Add formatting options
if [ "$SKIP_ADD_LOCKS" = true ]; then
  MYSQLDUMP_OPTIONS+=" --skip-add-locks"
fi

if [ "$NO_CREATE_INFO" = true ]; then
  MYSQLDUMP_OPTIONS+=" --no-create-info"
fi

if [ "$NO_TABLESPACES" = true ]; then
  MYSQLDUMP_OPTIONS+=" --no-tablespaces"
fi

# Add structure/data only options
if [ "$STRUCTURE_ONLY" = true ]; then
  MYSQLDUMP_OPTIONS+=" --no-data"
fi

# Process excluded tables
EXCLUDE_OPTIONS=""
if [ -n "$EXCLUDE_TABLES" ]; then
  IFS=',' read -ra EXCLUDED <<< "$EXCLUDE_TABLES"
  for table in "${EXCLUDED[@]}"; do
    EXCLUDE_OPTIONS+=" --ignore-table=$table"
  done
fi

# Process databases
IFS=',' read -ra DB_LIST <<< "$DATABASES"
DB_COUNT=${#DB_LIST[@]}

# Export each database
if [ "$DB_COUNT" -gt 1 ] || [ "$SHOW_PROGRESS" = false ]; then
  # Multiple databases or no progress - export separately
  for db in "${DB_LIST[@]}"; do
    echo "Exporting database: $db"

    # Set filename for this database
    if [ "$DB_COUNT" -gt 1 ]; then
      DB_OUTPUT_FILE="${db}_export.sql"
      if [ "$COMPRESS" = true ]; then
        DB_OUTPUT_FILE="${DB_OUTPUT_FILE}.gz"
      fi
      DB_FULL_PATH="$OUTPUT_DIR/$DB_OUTPUT_FILE"
    else
      DB_FULL_PATH="$FULL_OUTPUT_PATH"
    fi

    # Export command
    if [ "$COMPRESS" = true ]; then
      if [ "$SHOW_PROGRESS" = true ] && [ "$HAVE_PV" = true ]; then
        mysqldump $MYSQLDUMP_OPTIONS $EXCLUDE_OPTIONS "$db" | pv -N "$db" | gzip > "$DB_FULL_PATH"
      else
        mysqldump $MYSQLDUMP_OPTIONS $EXCLUDE_OPTIONS "$db" | gzip > "$DB_FULL_PATH"
      fi
    else
      if [ "$SHOW_PROGRESS" = true ] && [ "$HAVE_PV" = true ]; then
        mysqldump $MYSQLDUMP_OPTIONS $EXCLUDE_OPTIONS "$db" | pv -N "$db" > "$DB_FULL_PATH"
      else
        mysqldump $MYSQLDUMP_OPTIONS $EXCLUDE_OPTIONS "$db" > "$DB_FULL_PATH"
      fi
    fi

    if [ $? -ne 0 ]; then
      echo "Error: Failed to export database $db"
      exit 1
    fi

    echo "Export of $db completed to $DB_FULL_PATH"
  done
else
  # Single database with progress
  db=${DB_LIST[0]}
  echo "Exporting database: $db"

  # Get database size for progress estimation
  if [ "$SHOW_PROGRESS" = true ] && [ "$HAVE_PV" = true ]; then
    # Get size in bytes
    if [ -z "$DB_HOST" ]; then
      # Local database
      SIZE=$(mysql -u "$DB_USER" ${DB_PASS:+-p"$DB_PASS"} -e "SELECT SUM(data_length + index_length) FROM information_schema.tables WHERE table_schema='$db'" -sN)
    else
      # Remote database
      SIZE=$(mysql -u "$DB_USER" ${DB_PASS:+-p"$DB_PASS"} -h "$DB_HOST" -e "SELECT SUM(data_length + index_length) FROM information_schema.tables WHERE table_schema='$db'" -sN)
    fi

    if [ -z "$SIZE" ]; then
      SIZE=0
    fi

    # Export with progress
    if [ "$COMPRESS" = true ]; then
      mysqldump $MYSQLDUMP_OPTIONS $EXCLUDE_OPTIONS "$db" | pv -N "$db" -s "$SIZE" | gzip > "$FULL_OUTPUT_PATH"
    else
      mysqldump $MYSQLDUMP_OPTIONS $EXCLUDE_OPTIONS "$db" | pv -N "$db" -s "$SIZE" > "$FULL_OUTPUT_PATH"
    fi
  else
    # Export without progress
    if [ "$COMPRESS" = true ]; then
      mysqldump $MYSQLDUMP_OPTIONS $EXCLUDE_OPTIONS "$db" | gzip > "$FULL_OUTPUT_PATH"
    else
      mysqldump $MYSQLDUMP_OPTIONS $EXCLUDE_OPTIONS "$db" > "$FULL_OUTPUT_PATH"
    fi
  fi

  if [ $? -ne 0 ]; then
    echo "Error: Failed to export database $db"
    exit 1
  fi

  echo "Export of $db completed to $FULL_OUTPUT_PATH"
fi

echo "Database export completed successfully."