#!/bin/bash

# Default values
DB_USER="root"
DB_PASS=""
DB_HOST=""  # Empty means use local socket
DB_NAME=""  # Database to import into
INPUT_FILE=""  # SQL file to import
MAX_ALLOWED_PACKET="1G"  # Maximum allowed packet size
NET_BUFFER_LENGTH="16384"  # Network buffer length
SHOW_PROGRESS=true  # Whether to show progress information
DISABLE_KEYS=true  # Whether to disable keys during import
FORCE=false  # Force import even if database exists

# Display usage instructions
usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -u, --user USERNAME    Database username (default: root)"
  echo "  -w, --password PASS    Database password (default: empty)"
  echo "  -h, --host HOST        Database host (default: local socket)"
  echo "  -n, --database NAME    Database to import into (required)"
  echo "  -i, --input FILE       SQL file to import (required)"
  echo "  -m, --max-packet SIZE  Max allowed packet size (default: 1G)"
  echo "  -b, --net-buffer SIZE  Network buffer length (default: 16384)"
  echo "  -k, --keep-keys        Don't disable keys during import (default: disable)"
  echo "  -f, --force            Force import even if database exists (default: false)"
  echo "  -q, --quiet            Disable progress reporting"
  echo "  --help                 Display this help message"
  exit 1
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -u|--user) DB_USER="$2"; shift ;;
    -w|--password) DB_PASS="$2"; shift ;;
    -h|--host) DB_HOST="$2"; shift ;;
    -n|--database) DB_NAME="$2"; shift ;;
    -i|--input) INPUT_FILE="$2"; shift ;;
    -m|--max-packet) MAX_ALLOWED_PACKET="$2"; shift ;;
    -b|--net-buffer) NET_BUFFER_LENGTH="$2"; shift ;;
    -k|--keep-keys) DISABLE_KEYS=false ;;
    -f|--force) FORCE=true ;;
    -q|--quiet) SHOW_PROGRESS=false ;;
    --help) usage ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
  shift
done

# Validate required parameters
if [ -z "$DB_NAME" ]; then
  echo "Error: No database specified. Please use -n or --database option."
  usage
fi

if [ -z "$INPUT_FILE" ]; then
  echo "Error: No input file specified. Please use -i or --input option."
  usage
fi

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: Input file '$INPUT_FILE' does not exist."
  exit 1
fi

# Get file size for reporting
FILE_SIZE=$(du -h "$INPUT_FILE" | cut -f1)
echo "Input file: $INPUT_FILE (Size: $FILE_SIZE)"

# Prepare MySQL connection options
MYSQL_OPTS="-u\"$DB_USER\""

if [ -n "$DB_PASS" ]; then
  MYSQL_OPTS+=" -p\"$DB_PASS\""
fi

if [ -n "$DB_HOST" ]; then
  MYSQL_OPTS+=" -h\"$DB_HOST\""
  CONNECTION_DESC="host '$DB_HOST'"
else
  CONNECTION_DESC="local socket"
fi

# Check if database exists
DB_EXISTS=$(mysql $MYSQL_OPTS -e "SHOW DATABASES LIKE '$DB_NAME'" 2>/dev/null | grep -c "$DB_NAME" || true)

if [ "$DB_EXISTS" -gt 0 ] && [ "$FORCE" = false ]; then
  echo "Error: Database '$DB_NAME' already exists. Use --force to import anyway."
  exit 1
fi

# Create database if it doesn't exist
if [ "$DB_EXISTS" -eq 0 ]; then
  echo "Creating database '$DB_NAME'..."
  mysql $MYSQL_OPTS -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`" || {
    echo "Error: Failed to create database '$DB_NAME'"
    exit 1
  }
fi

# Build MySQL import command
IMPORT_CMD="mysql $MYSQL_OPTS"
IMPORT_CMD+=" --max_allowed_packet=$MAX_ALLOWED_PACKET"
IMPORT_CMD+=" --net_buffer_length=$NET_BUFFER_LENGTH"

if [ "$DISABLE_KEYS" = true ]; then
  IMPORT_CMD+=" --disable-keys"
fi

if [ "$SHOW_PROGRESS" = true ]; then
  IMPORT_CMD+=" --show-warnings"
else
  IMPORT_CMD+=" --silent"
fi

IMPORT_CMD+=" $DB_NAME"

# Show import information
echo "Importing into database '$DB_NAME' on $CONNECTION_DESC as user '$DB_USER'"
echo "Using max_allowed_packet: $MAX_ALLOWED_PACKET"
echo "Using net_buffer_length: $NET_BUFFER_LENGTH"

if [ "$DISABLE_KEYS" = true ]; then
  echo "Keys will be disabled during import"
fi

# Prepare the import environment
echo "Optimizing MySQL for import..."
mysql $MYSQL_OPTS -e "SET GLOBAL max_allowed_packet=$MAX_ALLOWED_PACKET;" || echo "Warning: Could not set global max_allowed_packet"
mysql $MYSQL_OPTS -e "SET GLOBAL net_buffer_length=$NET_BUFFER_LENGTH;" || echo "Warning: Could not set global net_buffer_length"

# Check if the file is gzipped
if [[ "$INPUT_FILE" == *.gz ]]; then
  echo "Detected gzipped SQL file, extracting during import..."
  echo "Starting import... This may take a while."

  if [ "$SHOW_PROGRESS" = true ]; then
    # With progress reporting - using pv if available
    if command -v pv >/dev/null 2>&1; then
      gunzip -c "$INPUT_FILE" | pv -s $(gzip -l "$INPUT_FILE" | sed -n 2p | awk '{print $2}') | eval "$IMPORT_CMD"
    else
      echo "Note: Install 'pv' for better progress reporting"
      gunzip -c "$INPUT_FILE" | eval "$IMPORT_CMD"
    fi
  else
    # Without progress reporting
    gunzip -c "$INPUT_FILE" | eval "$IMPORT_CMD"
  fi
else
  echo "Starting import... This may take a while."

  if [ "$SHOW_PROGRESS" = true ]; then
    # With progress reporting - using pv if available
    if command -v pv >/dev/null 2>&1; then
      pv "$INPUT_FILE" | eval "$IMPORT_CMD"
    else
      echo "Note: Install 'pv' for better progress reporting"
      eval "$IMPORT_CMD < \"$INPUT_FILE\""
    fi
  else
    # Without progress reporting
    eval "$IMPORT_CMD < \"$INPUT_FILE\""
  fi
fi

# Check import result
if [ $? -eq 0 ]; then
  echo "Import completed successfully!"
else
  echo "Error: Import failed."
  exit 1
fi

# Reset MySQL optimization settings
echo "Resetting MySQL optimization settings..."
mysql $MYSQL_OPTS -e "FLUSH TABLES;" || echo "Warning: Could not flush tables"

echo "Done."