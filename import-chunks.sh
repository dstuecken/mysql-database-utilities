#!/bin/bash

# Default values
DRY_RUN=false
FROM_CHUNK=1
TO_CHUNK=0  # 0 means all chunks
CHUNKS_DIR="./chunks"
DB_USER="root"
DB_PASS=""
DB_NAME=""
DB_HOST=""  # Empty means use local socket
SLEEP_SECONDS=3  # Sleep time between chunks
MAX_PACKET="2073741824"  # Default max allowed packet size (2GB)
MOVE_IMPORTED=false
COMPLETED_DIR=""

# Display usage instructions
usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -f, --from NUMBER     Start importing from chunk number (default: 1)"
  echo "  -t, --to NUMBER       Stop importing at chunk number (default: all chunks)"
  echo "  -d, --dry-run         Show what would be imported without actually importing"
  echo "  -p, --path DIRECTORY  Directory containing chunk files (default: ./chunks)"
  echo "  -u, --user USERNAME   Database username (default: root)"
  echo "  -w, --password PASS   Database password"
  echo "  -n, --database NAME   Database name (default: )"
  echo "  -h, --host HOST       Database host (default: local socket)"
  echo "  -m, --max-packet SIZE Max allowed packet size in bytes (default: 2073741824)"
  echo "  -s, --sleep SECONDS   Sleep time between chunks in seconds (default: 3)"
  echo "  --move-imported DIR   Move successfully imported chunks to specified directory"
  echo "  --help                Display this help message"
  echo ""
  echo "Example: $0 --from 3 --to 7 --user dbadmin --password secret --database mydb --host dbserver --move-imported ./completed"
  exit 1
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -f|--from) FROM_CHUNK="$2"; shift ;;
    -t|--to) TO_CHUNK="$2"; shift ;;
    -d|--dry-run) DRY_RUN=true ;;
    -p|--path) CHUNKS_DIR="$2"; shift ;;
    -u|--user) DB_USER="$2"; shift ;;
    -w|--password) DB_PASS="$2"; shift ;;
    -n|--database) DB_NAME="$2"; shift ;;
    -h|--host) DB_HOST="$2"; shift ;;
    -m|--max-packet) MAX_PACKET="$2"; shift ;;
    -s|--sleep) SLEEP_SECONDS="$2"; shift ;;
    --move-imported) MOVE_IMPORTED=true; COMPLETED_DIR="$2"; shift ;;
    --help) usage ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
  shift
done

# Validate chunks directory
if [ ! -d "$CHUNKS_DIR" ]; then
  echo "Error: Chunks directory '$CHUNKS_DIR' does not exist."
  exit 1
fi

# Validate completed directory if move-imported is enabled
if [ "$MOVE_IMPORTED" = true ]; then
  if [ -z "$COMPLETED_DIR" ]; then
    echo "Error: No directory specified for --move-imported option."
    exit 1
  fi

  # Create the directory if it doesn't exist
  if [ ! -d "$COMPLETED_DIR" ]; then
    echo "Creating directory for completed chunks: $COMPLETED_DIR"
    mkdir -p "$COMPLETED_DIR"
    if [ $? -ne 0 ]; then
      echo "Error: Failed to create directory '$COMPLETED_DIR'"
      exit 1
    fi
  fi

  # Check if the destination directory is writable
  if [ ! -w "$COMPLETED_DIR" ]; then
    echo "Error: Directory '$COMPLETED_DIR' is not writable."
    exit 1
  fi
fi

# Find all chunk files and sort them
CHUNK_FILES=$(find "$CHUNKS_DIR" -name "chunk_*.sql" | sort)
TOTAL_CHUNKS=$(echo "$CHUNK_FILES" | wc -l)

if [ "$TOTAL_CHUNKS" -eq 0 ]; then
  echo "Error: No chunk files found in '$CHUNKS_DIR'"
  exit 1
fi

echo "Found $TOTAL_CHUNKS chunk files in $CHUNKS_DIR"

# If TO_CHUNK is 0, set it to the total number of chunks
if [ "$TO_CHUNK" -eq 0 ]; then
  TO_CHUNK=$TOTAL_CHUNKS
fi

# Validate chunk range
if [ "$FROM_CHUNK" -lt 1 ] || [ "$FROM_CHUNK" -gt "$TOTAL_CHUNKS" ]; then
  echo "Error: From chunk ($FROM_CHUNK) is out of range (1-$TOTAL_CHUNKS)"
  exit 1
fi

if [ "$TO_CHUNK" -lt "$FROM_CHUNK" ] || [ "$TO_CHUNK" -gt "$TOTAL_CHUNKS" ]; then
  echo "Error: To chunk ($TO_CHUNK) is out of range ($FROM_CHUNK-$TOTAL_CHUNKS)"
  exit 1
fi

# Set connection description based on host setting
if [ -z "$DB_HOST" ]; then
  CONNECTION_DESC="local socket"
else
  CONNECTION_DESC="host '$DB_HOST'"
fi

echo "Preparing to import chunks $FROM_CHUNK to $TO_CHUNK into database '$DB_NAME' on $CONNECTION_DESC as user '$DB_USER'"
echo "Sleep between chunks: $SLEEP_SECONDS seconds"

if [ "$MOVE_IMPORTED" = true ]; then
  echo "Successfully imported chunks will be moved to: $COMPLETED_DIR"
fi

# Function to create MySQL command with appropriate host, user, password params
create_mysql_command() {
  local cmd="mysql"

  # Add host if specified
  if [ -n "$DB_HOST" ]; then
    cmd="$cmd -h\"$DB_HOST\""
  fi

  # Add user
  cmd="$cmd -u\"$DB_USER\""

  # Add password if specified
  if [ -n "$DB_PASS" ]; then
    cmd="$cmd -p\"$DB_PASS\""
  fi

  echo "$cmd"
}

# Function to check if user has SUPER privileges
check_super_privileges() {
  local mysql_base_cmd=$(create_mysql_command)
  local has_super=0

  has_super=$(eval "$mysql_base_cmd -e \"SELECT COUNT(*) FROM information_schema.user_privileges WHERE GRANTEE LIKE CONCAT('''', SUBSTRING_INDEX(CURRENT_USER(), '@', 1), '''@%''') AND PRIVILEGE_TYPE = 'SUPER'\"" 2>/dev/null | grep -v "COUNT" | tr -d ' ' || echo "0")

  if [ "$has_super" -gt 0 ]; then
    return 0  # Success - has super privileges
  else
    return 1  # Failure - no super privileges
  fi
}

# Check for SUPER privileges
if check_super_privileges; then
  echo "User has SUPER privileges - all statements will be executed"
else
  echo "Warning: User does not have SUPER privileges - some statements might fail"
  echo "  Consider using remove-super-statements-from-chunks.sh script first"
fi

# Import chunks
CURRENT=0
for chunk_file in $CHUNK_FILES; do
  CURRENT=$((CURRENT + 1))

  # Skip chunks before FROM_CHUNK
  if [ "$CURRENT" -lt "$FROM_CHUNK" ]; then
    continue
  fi

  # Stop if we've reached TO_CHUNK
  if [ "$CURRENT" -gt "$TO_CHUNK" ]; then
    break
  fi

  echo "Importing chunk $CURRENT of $TO_CHUNK: $(basename "$chunk_file")"

  # Construct command to import the chunk
  mysql_base_cmd=$(create_mysql_command)
  IMPORT_CMD="$mysql_base_cmd --max_allowed_packet=$MAX_PACKET \"$DB_NAME\" < \"$chunk_file\""

  # Execute the import unless dry run is enabled
  if [ "$DRY_RUN" = true ]; then
    echo "Would execute: $IMPORT_CMD"
    if [ "$MOVE_IMPORTED" = true ]; then
      echo "Would move $(basename "$chunk_file") to $COMPLETED_DIR after successful import"
    fi
  else
    echo "Executing: $IMPORT_CMD"
    eval "$IMPORT_CMD"

    # Check the exit status
    if [ $? -eq 0 ]; then
      echo "Successfully imported chunk $CURRENT"

      # Move the file if requested
      if [ "$MOVE_IMPORTED" = true ]; then
        echo "Moving $(basename "$chunk_file") to $COMPLETED_DIR"
        mv "$chunk_file" "$COMPLETED_DIR/"
        if [ $? -ne 0 ]; then
          echo "Warning: Failed to move chunk file to $COMPLETED_DIR"
        fi
      fi

    else
      echo "Error importing chunk $CURRENT"
      echo "You may want to retry from this chunk: $0 --from $CURRENT --to $TO_CHUNK --user \"$DB_USER\" --password \"$DB_PASS\" --database \"$DB_NAME\" ${DB_HOST:+--host \"$DB_HOST\"} ${MOVE_IMPORTED:+--move-imported \"$COMPLETED_DIR\"}"
      exit 1
    fi

    # Sleep between chunks unless this is the last one
    if [ "$CURRENT" -lt "$TO_CHUNK" ]; then
      echo "Sleeping for $SLEEP_SECONDS seconds..."
      sleep "$SLEEP_SECONDS"
    fi
  fi
done

if [ "$DRY_RUN" = true ]; then
  echo "Dry run completed. No data was imported."
else
  echo "All chunks imported successfully!"
fi

exit 0