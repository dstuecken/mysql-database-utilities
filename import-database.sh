#!/bin/bash
set -euo pipefail

# Default values
DB_USER="root"
DB_PASS=""
DB_HOST=""  # Empty means use local socket
DB_PORT="3306"
DB_NAME=""  # Database to import into
INPUT_FILE=""  # SQL file to import
MAX_ALLOWED_PACKET="1073741824"  # 1GB in bytes
NET_BUFFER_LENGTH="16384"  # Network buffer length
SHOW_PROGRESS=true  # Whether to show progress information
DISABLE_KEYS=true  # Whether to disable keys during import
FORCE=false  # Force import even if database exists
IGNORE_ERRORS=false  # Continue importing even when errors occur
USE_MYSQL_PASS_FILE=false

# Convert human-readable sizes to bytes
convert_to_bytes() {
  local size=$1
  local value=${size%[KMGTkmgt]*}
  local unit=${size##*[0-9]}

  case $unit in
    [Kk]) echo $((value * 1024)) ;;
    [Mm]) echo $((value * 1024 * 1024)) ;;
    [Gg]) echo $((value * 1024 * 1024 * 1024)) ;;
    [Tt]) echo $((value * 1024 * 1024 * 1024 * 1024)) ;;
    *) echo $value ;;  # Assume it's already in bytes if no unit
  esac
}

# Display usage instructions
usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -u, --user USERNAME    Database username (default: root)"
  echo "  -p, --password PASS    Database password (default: prompt)"
  echo "  -h, --host HOST        Database host (default: local socket)"
  echo "  -P, --port PORT        Database port (default: 3306)"
  echo "  -d, --database NAME    Database to import into (required)"
  echo "  -i, --input FILE       SQL file to import (required)"
  echo "  -m, --max-packet SIZE  Max allowed packet size (default: 1G)"
  echo "  -b, --net-buffer SIZE  Network buffer length (default: 16384)"
  echo "  -k, --keep-keys        Don't disable keys during import (default: disable)"
  echo "  -f, --force            Force import even if database exists (default: false)"
  echo "  -q, --quiet            Disable progress reporting"
  echo "  --ignore-errors        Continue importing even when errors occur (uses --force flag on mysql)"
  echo "  --help                 Display this help message"
  exit 1
}

cleanup_pass_file() {
  if [ -n "$MYSQL_PASS_FILE" ] && [ -f "$MYSQL_PASS_FILE" ]; then
    rm -f "$MYSQL_PASS_FILE"
  fi
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -u|--user) DB_USER="$2"; shift ;;
    -p|--password) DB_PASS="$2"; shift ;;
    -h|--host) DB_HOST="$2"; shift ;;
    -P|--port) DB_PORT="$2"; shift ;;
    -d|--database) DB_NAME="$2"; shift ;;
    -i|--input) INPUT_FILE="$2"; shift ;;
    -m|--max-packet)
      MAX_ALLOWED_PACKET=$(convert_to_bytes "$2")
      shift ;;
    -b|--net-buffer)
      NET_BUFFER_LENGTH=$(convert_to_bytes "$2")
      shift ;;
    -k|--keep-keys) DISABLE_KEYS=false ;;
    -f|--force) FORCE=true ;;
    -q|--quiet) SHOW_PROGRESS=false ;;
    --ignore-errors) IGNORE_ERRORS=true ;;
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

# Create password file for secure authentication
MYSQL_PASS_FILE=""
if [ -n "$DB_PASS" ] && [ "$USE_MYSQL_PASS_FILE" = true ]; then
  MYSQL_PASS_FILE=$(mktemp)
  echo "[client]" > "$MYSQL_PASS_FILE"
  echo "password=$DB_PASS" >> "$MYSQL_PASS_FILE"
  chmod 600 "$MYSQL_PASS_FILE"  # Set proper permissions
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

  if [ -n "$DB_PORT" ]; then
    cmd+=("-P$DB_PORT")
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

if [ -n "$DB_HOST" ]; then
  CONNECTION_DESC="host '$DB_HOST'"
else
  CONNECTION_DESC="local socket"
fi

# Check user privileges
echo "Checking privileges for user '$DB_USER'..."
HAS_SUPER_PRIVILEGE=$(run_mysql_command "" -e "SELECT IF(COUNT(*) > 0, 'YES', 'NO') AS has_super FROM information_schema.user_privileges WHERE GRANTEE LIKE '%''$DB_USER''%' AND PRIVILEGE_TYPE = 'SUPER'" 2>/dev/null | grep -v "has_super" | grep -v "row" | tr -d ' ')

if [ "$HAS_SUPER_PRIVILEGE" = "YES" ]; then
  echo "User has SUPER privileges. Global settings can be modified."
  CAN_MODIFY_GLOBALS=true
else
  echo "User does not have SUPER privileges. Will not attempt to modify MySQL variables."
  CAN_MODIFY_GLOBALS=false
fi

# Check if database exists
DB_EXISTS=$(run_mysql_command "" -e "SHOW DATABASES LIKE '$DB_NAME'" 2>/dev/null | grep -c "$DB_NAME" || true)

if [ "$DB_EXISTS" -gt 0 ] && [ "$FORCE" = false ]; then
  echo "Error: Database '$DB_NAME' already exists. Use --force to import anyway."
  cleanup_pass_file
  exit 1
fi

# Check if the user has privileges to create a database
if [ "$DB_EXISTS" -eq 0 ]; then
  echo "Database does not exist. Checking if user can create database..."
  CAN_CREATE_DB=$(run_mysql_command "" -e "SHOW GRANTS" 2>/dev/null | grep -E "ALL PRIVILEGES|CREATE" | grep -c "." || true)

  if [ "$CAN_CREATE_DB" -eq 0 ]; then
    echo "Error: User '$DB_USER' does not have permission to create database '$DB_NAME'."
    cleanup_pass_file
    exit 1
  fi

  echo "Creating database '$DB_NAME'..."
  run_mysql_command "" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`" || {
    echo "Error: Failed to create database '$DB_NAME'"
    cleanup_pass_file
    exit 1
  }
fi

# Show import information
echo "Importing into database '$DB_NAME' on $CONNECTION_DESC as user '$DB_USER'"

# Only try to set packet size if we have SUPER privileges
if [ "$CAN_MODIFY_GLOBALS" = true ]; then
  echo "Using max_allowed_packet: $MAX_ALLOWED_PACKET bytes"
  echo "Using net_buffer_length: $NET_BUFFER_LENGTH bytes"
fi

if [ "$DISABLE_KEYS" = true ]; then
  echo "Keys will be temporarily disabled during import"
fi

# Prepare the import environment
if [ "$CAN_MODIFY_GLOBALS" = true ]; then
  echo "Optimizing MySQL for import..."
  run_mysql_command "" -e "SET GLOBAL max_allowed_packet=$MAX_ALLOWED_PACKET;" || echo "Warning: Could not set global max_allowed_packet"
  run_mysql_command "" -e "SET GLOBAL net_buffer_length=$NET_BUFFER_LENGTH;" || echo "Warning: Could not set global net_buffer_length"
fi

# If disabling keys, prepare the command
if [ "$DISABLE_KEYS" = true ] && [ "$DB_EXISTS" -gt 0 ]; then
  # Check if the user has ALTER privilege
  CAN_ALTER=$(run_mysql_command "" -e "SHOW GRANTS" 2>/dev/null | grep -E "ALL PRIVILEGES|ALTER" | grep -c "." || true)

  if [ "$CAN_ALTER" -gt 0 ]; then
    echo "Disabling keys on existing tables..."
    TABLES=$(run_mysql_command "$DB_NAME" -e "SHOW TABLES\G" | grep -v "Tables_in" | grep -v "row" | tr -d ' ' | tr -d '*')
    for TABLE in $TABLES; do
      run_mysql_command "$DB_NAME" -e "ALTER TABLE \`$TABLE\` DISABLE KEYS;" || echo "Warning: Could not disable keys for table $TABLE"
    done
  else
    echo "Warning: User does not have ALTER privilege. Cannot disable keys on existing tables."
    DISABLE_KEYS=false
  fi
fi

# Build MySQL import command function
run_mysql_import() {
  local cmd=()

  # Add password file as first argument if password is provided
  if [ -n "$MYSQL_PASS_FILE" ]; then
    cmd+=("--defaults-extra-file=$MYSQL_PASS_FILE")
  else
    cmd+=("-p$DB_PASS")
  fi

  # Add other MySQL options
  cmd+=("-u$DB_USER")

  if [ -n "$DB_HOST" ]; then
    cmd+=("-h$DB_HOST")
  fi

  # Add max_allowed_packet directly to command line if we have SUPER privileges
  if [ "$CAN_MODIFY_GLOBALS" = true ]; then
    cmd+=("--max_allowed_packet=$MAX_ALLOWED_PACKET")
    cmd+=("--net_buffer_length=$NET_BUFFER_LENGTH")
  fi

  if [ "$IGNORE_ERRORS" = true ]; then
    cmd+=("--force")
    echo "Note: --ignore-errors option is enabled. MySQL will continue on errors."
  fi


  if [ "$SHOW_PROGRESS" = false ]; then
    cmd+=("--silent")
  fi

  # Finally add the database name
  cmd+=("$DB_NAME")

  # Execute the command
  mysql "${cmd[@]}"
}

# Prepare the SQL commands
SET_VARS_SQL=""
if [ "$DISABLE_KEYS" = true ]; then
  SET_VARS_SQL="${SET_VARS_SQL}SET FOREIGN_KEY_CHECKS=0;\n"
  RESET_VARS_SQL="SET FOREIGN_KEY_CHECKS=1;\n"
else
  RESET_VARS_SQL=""
fi

# Check if the file is gzipped
if [[ "$INPUT_FILE" == *.gz ]]; then
  echo "Detected gzipped SQL file, extracting during import..."
  echo "Starting import... This may take a while."

  if [ "$SHOW_PROGRESS" = true ]; then
    # With progress reporting - using pv if available
    if command -v pv >/dev/null 2>&1; then
      (echo -e "$SET_VARS_SQL"; gunzip -c "$INPUT_FILE"; echo -e "$RESET_VARS_SQL") | \
      pv -s $(($(gzip -l "$INPUT_FILE" | sed -n 2p | awk '{print $2}')+100)) | run_mysql_import
    else
      echo "Note: Install 'pv' for better progress reporting"
      (echo -e "$SET_VARS_SQL"; gunzip -c "$INPUT_FILE"; echo -e "$RESET_VARS_SQL") | run_mysql_import
    fi
  else
    # Without progress reporting
    (echo -e "$SET_VARS_SQL"; gunzip -c "$INPUT_FILE"; echo -e "$RESET_VARS_SQL") | run_mysql_import
  fi
else
  echo "Starting import... This may take a while."

  if [ "$SHOW_PROGRESS" = true ]; then
    # With progress reporting - using pv if available
    if command -v pv >/dev/null 2>&1; then
      (echo -e "$SET_VARS_SQL"; cat "$INPUT_FILE"; echo -e "$RESET_VARS_SQL") | \
      pv -s $(($(stat -f%z "$INPUT_FILE" 2>/dev/null || stat -c%s "$INPUT_FILE")+100)) | run_mysql_import
    else
      echo "Note: Install 'pv' for better progress reporting"
      (echo -e "$SET_VARS_SQL"; cat "$INPUT_FILE"; echo -e "$RESET_VARS_SQL") | run_mysql_import
    fi
  else
    # Without progress reporting
    (echo -e "$SET_VARS_SQL"; cat "$INPUT_FILE"; echo -e "$RESET_VARS_SQL") | run_mysql_import
  fi
fi

# Check import result
IMPORT_STATUS=$?

# If disabling keys was enabled, re-enable the keys
if [ "$DISABLE_KEYS" = true ] && [ "$DB_EXISTS" -gt 0 ] && [ "$CAN_ALTER" -gt 0 ]; then
  echo "Re-enabling keys on tables..."
  TABLES=$(run_mysql_command "$DB_NAME" -e "SHOW TABLES\G" | grep -v "Tables_in" | grep -v "row" | tr -d ' ' | tr -d '*')
  for TABLE in $TABLES; do
    run_mysql_command "$DB_NAME" -e "ALTER TABLE \`$TABLE\` ENABLE KEYS;" || echo "Warning: Could not enable keys for table $TABLE"
  done
fi

cleanup_pass_file

# Report on import result
if [ $IMPORT_STATUS -eq 0 ]; then
  echo "Import completed successfully!"
else
  echo "Error: Import failed."
  exit 1
fi

# Reset MySQL optimization settings
if [ "$CAN_MODIFY_GLOBALS" = true ]; then
  echo "Resetting MySQL optimization settings..."
  run_mysql_command "" -e "FLUSH TABLES;" || echo "Warning: Could not flush tables"
fi

echo "Done."