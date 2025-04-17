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
  echo "  --skip-lock-tables      Skip locking tables during export (use if you get error: 1109)"
  echo "  --no-tablespaces        Skip tablespace information"
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

# Build mysqldump command with basic options
MYSQLDUMP_CMD="mysqldump"

# Add credentials
if [ -n "$DB_HOST" ]; then
  MYSQLDUMP_CMD="$MYSQLDUMP_CMD -h \"$DB_HOST\""
fi

MYSQLDUMP_CMD="$MYSQLDUMP_CMD -u \"$DB_USER\""

if [ -n "$DB_PASS" ]; then
  MYSQLDUMP_CMD="$MYSQLDUMP_CMD -p\"$DB_PASS\""
fi

# Add performance optimization options
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --max_allowed_packet=$MAX_ALLOWED_PACKET"
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --net_buffer_length=$NET_BUFFER_LENGTH"
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --opt" # Enables several optimization options
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --quick" # Retrieves rows one by one
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --skip-extended-insert=FALSE" # Use multi-row INSERT syntax

# Add the new MySQL options
if [ "$SKIP_ADD_LOCKS" = true ]; then
  MYSQLDUMP_CMD="$MYSQLDUMP_CMD --skip-add-locks"
fi

if [ "$NO_CREATE_INFO" = true ]; then
  MYSQLDUMP_CMD="$MYSQLDUMP_CMD --no-create-info"
fi

if [ "$SKIP_LOCK_TABLES" = true ]; then
  MYSQLDUMP_CMD="$MYSQLDUMP_CMD --skip-lock-tables"
fi

if [ "$NO_TABLESPACES" = true ]; then
  MYSQLDUMP_CMD="$MYSQLDUMP_CMD --no-tablespaces"
fi

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
MYSQLDUMP_CMD="$MYSQLDUMP_CMD --databases $DATABASES"

# Add excluded tables
if [ -n "$EXCLUDE_TABLES" ]; then
  IFS=',' read -ra EXCLUDE_ARRAY <<< "$EXCLUDE_TABLES"
  for table in "${EXCLUDE_ARRAY[@]}"; do
    MYSQLDUMP_CMD="$MYSQLDUMP_CMD --ignore-table=$table"
  done
fi

# Calculate database size for progress estimation
if [ "$SHOW_PROGRESS" = true ]; then
  echo "Calculating database size for progress estimation..."

  # Build MySQL command to get total size
  SIZE_CMD="mysql"
  if [ -n "$DB_HOST" ]; then
    SIZE_CMD="$SIZE_CMD -h \"$DB_HOST\""
  fi
  SIZE_CMD="$SIZE_CMD -u \"$DB_USER\""
  if [ -n "$DB_PASS" ]; then
    SIZE_CMD="$SIZE_CMD -p\"$DB_PASS\""
  fi

  # Split the databases string
  IFS=',' read -ra DB_ARRAY <<< "$DATABASES"

  # Construct a query to get the total database size
  SIZE_QUERY="SELECT SUM(data_length + index_length) FROM information_schema.TABLES WHERE table_schema IN ("

  # Add each database name surrounded by quotes
  first=true
  for db in "${DB_ARRAY[@]}"; do
    if [ "$first" = true ]; then
      first=false
    else
      SIZE_QUERY+=","
    fi
    SIZE_QUERY+="'$db'"
  done

  SIZE_QUERY+=");"

  # Run the query to get total size in bytes
  TOTAL_BYTES=$(eval "$SIZE_CMD -N -e \"$SIZE_QUERY\"")

  # Handle empty result or errors
  if [ -z "$TOTAL_BYTES" ] || [ "$TOTAL_BYTES" = "NULL" ]; then
    echo "Warning: Couldn't determine database size. Progress monitoring will be limited."
    TOTAL_BYTES=0
  else
    # Convert to human readable format
    if [ "$TOTAL_BYTES" -gt 1073741824 ]; then
      TOTAL_SIZE=$(echo "scale=2; $TOTAL_BYTES / 1073741824" | bc)
      echo "Total database size: ${TOTAL_SIZE}GB"
    elif [ "$TOTAL_BYTES" -gt 1048576 ]; then
      TOTAL_SIZE=$(echo "scale=2; $TOTAL_BYTES / 1048576" | bc)
      echo "Total database size: ${TOTAL_SIZE}MB"
    elif [ "$TOTAL_BYTES" -gt 1024 ]; then
      TOTAL_SIZE=$(echo "scale=2; $TOTAL_BYTES / 1024" | bc)
      echo "Total database size: ${TOTAL_SIZE}KB"
    else
      echo "Total database size: ${TOTAL_BYTES}B"
    fi
  fi
fi

# Execute the mysqldump command with progress reporting
echo "Starting database export..."

# Start time for progress tracking
START_TIME=$(date +%s)

# Status reporting function
print_status() {
  local current_time=$(date +%s)
  local elapsed=$((current_time - START_TIME))
  local hours=$((elapsed / 3600))
  local minutes=$(( (elapsed % 3600) / 60 ))
  local seconds=$((elapsed % 60))

  echo -ne "\rExport in progress... Time elapsed: ${hours}h:${minutes}m:${seconds}s"
}

# Setup progress monitor
if [ "$SHOW_PROGRESS" = true ] && [ "$HAVE_PV" = true ] && [ "$TOTAL_BYTES" -gt 0 ]; then
  # Use pv with size indication for accurate progress bar
  progress_cmd="pv -s $TOTAL_BYTES -i 1"
else
  # Simple periodic status update
  progress_cmd="cat"
  # Start a background process to print status every second
  if [ "$SHOW_PROGRESS" = true ]; then
    (
      while true; do
        print_status
        sleep 1
      done
    ) &
    PROGRESS_PID=$!
    # Ensure we kill the progress process when the script exits
    trap "kill $PROGRESS_PID 2>/dev/null" EXIT
  fi
fi

# Print command for debugging
echo "Command: $MYSQLDUMP_CMD"

# Run the export with progress monitoring
if [ "$COMPRESS" = true ]; then
  if [ "$SHOW_PROGRESS" = true ] && [ "$HAVE_PV" = true ]; then
    eval "$MYSQLDUMP_CMD" | $progress_cmd | gzip > "$FULL_OUTPUT_PATH"
  else
    eval "$MYSQLDUMP_CMD" | gzip > "$FULL_OUTPUT_PATH"
  fi
  echo -e "\nExport completed and compressed to $FULL_OUTPUT_PATH"
else
  if [ "$SHOW_PROGRESS" = true ] && [ "$HAVE_PV" = true ]; then
    eval "$MYSQLDUMP_CMD" | $progress_cmd > "$FULL_OUTPUT_PATH"
  else
    eval "$MYSQLDUMP_CMD" > "$FULL_OUTPUT_PATH"
  fi
  echo -e "\nExport completed to $FULL_OUTPUT_PATH"
fi

# Calculate and show elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
HOURS=$((ELAPSED / 3600))
MINUTES=$(( (ELAPSED % 3600) / 60 ))
SECONDS=$((ELAPSED % 60))
echo "Total export time: ${HOURS}h:${MINUTES}m:${SECONDS}s"

# If the file was created successfully, display its size
if [ -f "$FULL_OUTPUT_PATH" ]; then
  FILE_SIZE=$(du -h "$FULL_OUTPUT_PATH" | cut -f1)
  echo "Output file size: $FILE_SIZE"
fi

echo "Done!"