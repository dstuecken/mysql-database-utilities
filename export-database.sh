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
  echo "  -z, --compress          Compress output file with gzip"
  echo "  -m, --max-packet SIZE   Max allowed packet size (default: 1G)"
  echo "  -n, --net-buffer SIZE   Network buffer length (default: 16384)"
  echo "  -t, --lock-tables       Lock all tables during export (default: false)"
  echo "  -s, --skip-transaction  Skip using single transaction (default: use transaction)"
  echo "  -x, --exclude TABLES    Tables to exclude (comma-separated, format: db.table)"
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

# Build mysqldump command with basic options
MYSQLDUMP_CMD="mysqldump"

# Add credentials
if [ -n "$DB_HOST" ]; then
  MYSQLDUMP_CMD="$MYSQLDUMP_CMD -h\"$DB_HOST\""
fi

MYSQLDUMP_CMD="$MYSQLDUMP_CMD -u\"$DB_USER\""

if [ -n "$DB_PASS" ]; then
  MYSQLDUMP_CMD="$MYSQLDUMP_CMD -p\"$DB_PASS\""
fi

# Add performance optimization options
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --max_allowed_packet=$MAX_ALLOWED_PACKET"
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --net_buffer_length=$NET_BUFFER_LENGTH"
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --opt" # Enables several optimization options
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --quick" # Retrieves rows one by one
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --skip-extended-insert=FALSE" # Use multi-row INSERT syntax
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --compress" # Use compression in server/client protocol

# Add transaction handling options
if [ "$SINGLE_TRANSACTION" = true ]; then
  MYSQLDUMP_CMD="$MYSQLDUMP_CMD --single-transaction" # For InnoDB tables
else
  if [ "$LOCK_TABLES" = true ]; then
    MYSQLDUMP_CMD="$MYSQLDUMP_CMD --lock-tables=true"
  else
    MYSQLDUMP_CMD="$MYSQLDUMP_CMD --lock-tables=false"
  fi
fi

# Add database names
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --databases"
IFS=',' read -ra DB_ARRAY <<< "$DATABASES"
for db in "${DB_ARRAY[@]}"; do
  MYSQLDUMP_CMD="$MYSQLDUMP_CMD \"$db\""
done

# Add exclude tables if specified
if [ -n "$EXCLUDE_TABLES" ]; then
  IFS=',' read -ra EXCLUDE_ARRAY <<< "$EXCLUDE_TABLES"
  for table in "${EXCLUDE_ARRAY[@]}"; do
    MYSQLDUMP_CMD="$MYSQLDUMP_CMD --ignore-table=\"$table\""
  done
fi

# Build the full command with output redirection
if [ "$COMPRESS" = true ]; then
  FULL_CMD="$MYSQLDUMP_CMD | gzip > \"$FULL_OUTPUT_PATH\""
else
  FULL_CMD="$MYSQLDUMP_CMD > \"$FULL_OUTPUT_PATH\""
fi

# Display export information
echo "Exporting database(s): $DATABASES"
echo "Output file: $FULL_OUTPUT_PATH"

# Add database host info if specified
if [ -n "$DB_HOST" ]; then
  echo "Using database host: $DB_HOST"
else
  echo "Using local socket connection"
fi

# Show excluded tables if any
if [ -n "$EXCLUDE_TABLES" ]; then
  echo "Excluding tables: $EXCLUDE_TABLES"
fi

# Begin export
echo "Starting export process..."
start_time=$(date +%s)

# Execute the command
eval "$FULL_CMD"
EXPORT_RESULT=$?

end_time=$(date +%s)
elapsed_time=$((end_time - start_time))

# Check the result
if [ $EXPORT_RESULT -eq 0 ]; then
  # Calculate file size
  if [ "$COMPRESS" = true ]; then
    FILE_SIZE=$(du -h "$FULL_OUTPUT_PATH" | cut -f1)
  else
    FILE_SIZE=$(du -h "$FULL_OUTPUT_PATH" | cut -f1)
  fi

  echo "✅ Export completed successfully in $elapsed_time seconds"
  echo "Output file: $FULL_OUTPUT_PATH ($FILE_SIZE)"
else
  echo "❌ Export failed with error code: $EXPORT_RESULT"
  echo "Please check your credentials and database connection"
fi