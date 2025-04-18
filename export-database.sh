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
  echo "  -w, --password PASS     Database password (default: prompt)"
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
  echo "Error: You cannot use both --structure-only and --data-only options at the same time."
  exit 1
fi

# Prompt for password if not provided
if [ -z "$DB_PASS" ]; then
  echo -n "Enter password for MySQL user '$DB_USER': "
  read -s DB_PASS
  echo ""
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Build mysqldump command with appropriate options
DUMP_CMD="mysqldump -u\"$DB_USER\""

# Use secure password file instead of command line parameter
if [ -n "$DB_PASS" ]; then
  MYSQL_PASS_FILE=$(mktemp)
  echo "[client]" > "$MYSQL_PASS_FILE"
  echo "password=\"$DB_PASS\"" >> "$MYSQL_PASS_FILE"
  DUMP_CMD+=" --defaults-extra-file=\"$MYSQL_PASS_FILE\""
fi

if [ -n "$DB_HOST" ]; then
  DUMP_CMD+=" -h\"$DB_HOST\""
fi

# Add MySQL option flags to the dump command
DUMP_CMD+=" --max_allowed_packet=$MAX_ALLOWED_PACKET"
DUMP_CMD+=" --net_buffer_length=$NET_BUFFER_LENGTH"

if [ "$SINGLE_TRANSACTION" = true ]; then
  DUMP_CMD+=" --single-transaction"
fi

if [ "$LOCK_TABLES" = true ]; then
  DUMP_CMD+=" --lock-tables"
fi

if [ "$SKIP_ADD_LOCKS" = true ]; then
  DUMP_CMD+=" --skip-add-locks"
fi

if [ "$NO_CREATE_INFO" = true ]; then
  DUMP_CMD+=" --no-create-info"
fi

if [ "$SKIP_LOCK_TABLES" = true ]; then
  DUMP_CMD+=" --skip-lock-tables"
fi

if [ "$NO_TABLESPACES" = true ]; then
  DUMP_CMD+=" --no-tablespaces"
fi

if [ "$STRUCTURE_ONLY" = true ]; then
  DUMP_CMD+=" --no-data"
fi

if [ "$DATA_ONLY" = true ]; then
  DUMP_CMD+=" --no-create-info"
fi

# Add common export options
DUMP_CMD+=" --opt --routines --events --triggers --create-options --extended-insert"

# Exclude tables if specified
if [ -n "$EXCLUDE_TABLES" ]; then
  IFS=',' read -r -a EXCLUDE_ARRAY <<< "$EXCLUDE_TABLES"
  for TABLE in "${EXCLUDE_ARRAY[@]}"; do
    DUMP_CMD+=" --ignore-table=$TABLE"
  done
fi

# Prepare database list
IFS=',' read -r -a DB_ARRAY <<< "$DATABASES"

# Determine output path
OUTPUT_PATH="$OUTPUT_DIR/$OUTPUT_FILE"

# Show export information
echo "Exporting database(s): ${DATABASES}"
echo "Output file: $OUTPUT_PATH"

if [ "$COMPRESS" = true ]; then
  echo "Output will be compressed with gzip"
  OUTPUT_PATH="${OUTPUT_PATH}.gz"
fi

# Perform the export
if [ "$COMPRESS" = true ]; then
  if [ "$SHOW_PROGRESS" = true ] && command -v pv >/dev/null 2>&1; then
    eval "$DUMP_CMD ${DB_ARRAY[@]}" | pv | gzip > "$OUTPUT_PATH"
  else
    eval "$DUMP_CMD ${DB_ARRAY[@]}" | gzip > "$OUTPUT_PATH"
  fi
else
  if [ "$SHOW_PROGRESS" = true ] && command -v pv >/dev/null 2>&1; then
    eval "$DUMP_CMD ${DB_ARRAY[@]}" | pv > "$OUTPUT_PATH"
  else
    eval "$DUMP_CMD ${DB_ARRAY[@]}" > "$OUTPUT_PATH"
  fi
fi

# Check export result
EXPORT_STATUS=$?

# Clean up password file
if [ -n "$MYSQL_PASS_FILE" ] && [ -f "$MYSQL_PASS_FILE" ]; then
  rm -f "$MYSQL_PASS_FILE"
fi

# Report on export result
if [ $EXPORT_STATUS -eq 0 ]; then
  echo "Export completed successfully!"
  echo "Exported to: $OUTPUT_PATH"

  # Show file size information
  if [ -f "$OUTPUT_PATH" ]; then
    FILE_SIZE=$(du -h "$OUTPUT_PATH" | cut -f1)
    echo "File size: $FILE_SIZE"
  fi
else
  echo "Error: Export failed."
  exit 1
fi

echo "Done."