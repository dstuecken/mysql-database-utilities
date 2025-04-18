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
  echo "  -w, --password PASS    Database password (default: prompt)"
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

# Prompt for password if not provided
if [ -z "$DB_PASS" ]; then
  echo -n "Enter password for MySQL user '$DB_USER': "
  read -s DB_PASS
  echo ""
fi

# Function to run MySQL commands with proper authentication
run_mysql_command() {
  local cmd=()
  local db_arg=""

  # Add password file as first argument if password is provided
  if [ -n "$MYSQL_PASS_FILE" ]; then
    cmd+=("--defaults-extra-file=$MYSQL_PASS_FILE")
  fi

  # Add other MySQL options
  cmd+=("-u$DB_USER")

  if [ -n "$DB_HOST" ]; then
    cmd+=("-h$DB_HOST")
  fi

  # Add the database if specified
  if [ -n "$1" ]; then
    db_arg="$1"
    shift
  fi

  # Add remaining arguments
  for arg in "$@"; do
    cmd+=("$arg")
  done

  # Execute the command with the database if provided
  if [ -n "$db_arg" ]; then
    mysql "${cmd[@]}" "$db_arg"
  else
    mysql "${cmd[@]}"
  fi
}

# Create password file for secure authentication
MYSQL_PASS_FILE=""
if [ -n "$DB_PASS" ]; then
  MYSQL_PASS_FILE=$(mktemp)
  echo "[client]" > "$MYSQL_PASS_FILE"
  echo "password=$DB_PASS" >> "$MYSQL_PASS_FILE"
  chmod 600 "$MYSQL_PASS_FILE"  # Set proper permissions
fi

if [ -n "$DB_HOST" ]; then
  CONNECTION_DESC="host '$DB_HOST'"
else
  CONNECTION_DESC="local socket"
fi

# Check if database exists
DB_EXISTS=$(run_mysql_command "" -e "SHOW DATABASES LIKE '$DB_NAME'" 2>/dev/null | grep -c "$DB_NAME" || true)

if [ "$DB_EXISTS" -gt 0 ] && [ "$FORCE" = false ]; then
  echo "Error: Database '$DB_NAME' already exists. Use --force to import anyway."
  # Clean up password file
  if [ -n "$MYSQL_PASS_FILE" ] && [ -f "$MYSQL_PASS_FILE" ]; then
    rm -f "$MYSQL_PASS_FILE"
  fi
  exit 1
fi

# Create database if it doesn't exist
if [ "$DB_EXISTS" -eq 0 ]; then
  echo "Creating database '$DB_NAME'..."
  run_mysql_command "" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`" || {
    echo "Error: Failed to create database '$DB_NAME'"
    # Clean up password file
    if [ -n "$MYSQL_PASS_FILE" ] && [ -f "$MYSQL_PASS_FILE" ]; then
      rm -f "$MYSQL_PASS_FILE"
    fi
    exit 1
  }
fi

# Show import information
echo "Importing into database '$DB_NAME' on $CONNECTION_DESC as user '$DB_USER'"
echo "Using max_allowed_packet: $MAX_ALLOWED_PACKET"
echo "Using net_buffer_length: $NET_BUFFER_LENGTH"

if [ "$DISABLE_KEYS" = true ]; then
  echo "Keys will be disabled during import"
fi

# Prepare the import environment
echo "Optimizing MySQL for import..."
run_mysql_command "" -e "SET GLOBAL max_allowed_packet=$MAX_ALLOWED_PACKET;" || echo "Warning: Could not set global max_allowed_packet"
run_mysql_command "" -e "SET GLOBAL net_buffer_length=$NET_BUFFER_LENGTH;" || echo "Warning: Could not set global net_buffer_length"

# Build MySQL import command function
run_mysql_import() {
  local cmd=()

  # Add password file as first argument if password is provided
  if [ -n "$MYSQL_PASS_FILE" ]; then
    cmd+=("--defaults-extra-file=$MYSQL_PASS_FILE")
  fi

  # Add other MySQL options
  cmd+=("-u$DB_USER")

  if [ -n "$DB_HOST" ]; then
    cmd+=("-h$DB_HOST")
  fi

  # Add import-specific options
  cmd+=("--max_allowed_packet=$MAX_ALLOWED_PACKET")
  cmd+=("--net_buffer_length=$NET_BUFFER_LENGTH")

  if [ "$DISABLE_KEYS" = true ]; then
    cmd+=("--disable-keys")
  fi

  if [ "$SHOW_PROGRESS" = true ]; then
    cmd+=("--show-warnings")
  else
    cmd+=("--silent")
  fi

  # Finally add the database name
  cmd+=("$DB_NAME")

  # Execute the command
  mysql "${cmd[@]}"
}

# Check if the file is gzipped
if [[ "$INPUT_FILE" == *.gz ]]; then
  echo "Detected gzipped SQL file, extracting during import..."
  echo "Starting import... This may take a while."

  if [ "$SHOW_PROGRESS" = true ]; then
    # With progress reporting - using pv if available
    if command -v pv >/dev/null 2>&1; then
      gunzip -c "$INPUT_FILE" | pv -s $(gzip -l "$INPUT_FILE" | sed -n 2p | awk '{print $2}') | run_mysql_import
    else
      echo "Note: Install 'pv' for better progress reporting"
      gunzip -c "$INPUT_FILE" | run_mysql_import
    fi
  else
    # Without progress reporting
    gunzip -c "$INPUT_FILE" | run_mysql_import
  fi
else
  echo "Starting import... This may take a while."

  if [ "$SHOW_PROGRESS" = true ]; then
    # With progress reporting - using pv if available
    if command -v pv >/dev/null 2>&1; then
      pv "$INPUT_FILE" | run_mysql_import
    else
      echo "Note: Install 'pv' for better progress reporting"
      run_mysql_import < "$INPUT_FILE"
    fi
  else
    # Without progress reporting
    run_mysql_import < "$INPUT_FILE"
  fi
fi

# Check import result
IMPORT_STATUS=$?

# Clean up password file
if [ -n "$MYSQL_PASS_FILE" ] && [ -f "$MYSQL_PASS_FILE" ]; then
  rm -f "$MYSQL_PASS_FILE"
fi

# Report on import result
if [ $IMPORT_STATUS -eq 0 ]; then
  echo "Import completed successfully!"
else
  echo "Error: Import failed."
  exit 1
fi

# Reset MySQL optimization settings
echo "Resetting MySQL optimization settings..."
run_mysql_command "" -e "FLUSH TABLES;" || echo "Warning: Could not flush tables"

echo "Done."