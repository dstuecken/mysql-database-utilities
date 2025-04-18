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
HAVE_PV=false  # Whether pv command is available for progress display
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
  echo "Error: You cannot use both --structure-only and --data-only options."
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

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Create temporary file for MySQL password
MYSQL_PASS_FILE=$(mktemp)
trap 'rm -f "$MYSQL_PASS_FILE"' EXIT
cat > "$MYSQL_PASS_FILE" << EOF
[client]
user=$DB_USER
password=$DB_PASS
EOF

if [ -n "$DB_HOST" ]; then
  echo "host=$DB_HOST" >> "$MYSQL_PASS_FILE"
fi

# Process databases
IFS=',' read -ra DB_ARRAY <<< "$DATABASES"
for db in "${DB_ARRAY[@]}"; do
  echo "Exporting database: $db"

  # Determine output filename
  if [ "${#DB_ARRAY[@]}" -gt 1 ]; then
    # Multiple databases, use database name as filename
    CURRENT_OUTPUT_FILE="$OUTPUT_DIR/${db}.sql"
  else
    # Single database, use the specified filename
    CURRENT_OUTPUT_FILE="$OUTPUT_DIR/$OUTPUT_FILE"
  fi

  # Build the mysqldump command directly with an array
  cmd=(
    "mysqldump"
    "--defaults-file=$MYSQL_PASS_FILE"
    "--max_allowed_packet=$MAX_ALLOWED_PACKET"
    "--net_buffer_length=$NET_BUFFER_LENGTH"
  )

  # Add options based on user selection
  if [ "$SINGLE_TRANSACTION" = true ]; then
    cmd+=("--single-transaction")
  fi

  if [ "$LOCK_TABLES" = true ]; then
    cmd+=("--lock-tables=true")
  else
    cmd+=("--lock-tables=false")
  fi

  if [ "$SKIP_ADD_LOCKS" = true ]; then
    cmd+=("--skip-add-locks")
  fi

  if [ "$NO_CREATE_INFO" = true ]; then
    cmd+=("--no-create-info")
  fi

  if [ "$SKIP_LOCK_TABLES" = true ]; then
    cmd+=("--skip-lock-tables")
  fi

  if [ "$NO_TABLESPACES" = true ]; then
    cmd+=("--no-tablespaces")
  fi

  if [ "$STRUCTURE_ONLY" = true ]; then
    cmd+=("--no-data")
  fi

  if [ "$DATA_ONLY" = true ]; then
    cmd+=("--no-create-info")
  fi

  # Add excluded tables
  if [ -n "$EXCLUDE_TABLES" ]; then
    IFS=',' read -ra EXCLUDE_ARRAY <<< "$EXCLUDE_TABLES"
    for table in "${EXCLUDE_ARRAY[@]}"; do
      cmd+=("--ignore-table=$table")
    done
  fi

  # Add database name
  cmd+=("$db")

  # Execute the dump command with progress indicator if available
  if [ "$COMPRESS" = true ]; then
    echo "Exporting to: ${CURRENT_OUTPUT_FILE}.gz"
    if [ "$SHOW_PROGRESS" = true ] && [ "$HAVE_PV" = true ]; then
      "${cmd[@]}" | pv -cN mysqldump | gzip > "${CURRENT_OUTPUT_FILE}.gz"
    else
      "${cmd[@]}" | gzip > "${CURRENT_OUTPUT_FILE}.gz"
    fi
  else
    echo "Exporting to: $CURRENT_OUTPUT_FILE"
    if [ "$SHOW_PROGRESS" = true ] && [ "$HAVE_PV" = true ]; then
      "${cmd[@]}" | pv -cN mysqldump > "$CURRENT_OUTPUT_FILE"
    else
      "${cmd[@]}" > "$CURRENT_OUTPUT_FILE"
    fi
  fi

  EXPORT_STATUS=$?
  if [ $EXPORT_STATUS -eq 0 ]; then
    echo "Export of $db completed successfully."
  else
    echo "Error exporting $db. Exit code: $EXPORT_STATUS"
  fi
done

echo "All database exports completed."