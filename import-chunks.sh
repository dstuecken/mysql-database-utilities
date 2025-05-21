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
  echo "  -u, --user USERNAME   Database username (default: root)"
  echo "  -p, --password PASS   Database password"
  echo "  -d, --database NAME   Database name (required)"
  echo "  -h, --host HOST       Database host (default: local socket)"
  echo "  -m, --max-packet SIZE Max allowed packet size in bytes (default: 2073741824)"
  echo "  -s, --sleep SECONDS   Sleep time between chunks in seconds (default: 3)"
  echo "  --path DIRECTORY      Directory containing chunk files (default: ./chunks)"
  echo "  --dry-run             Show what would be imported without actually importing"
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
    -u|--user) DB_USER="$2"; shift ;;
    -p|--password) DB_PASS="$2"; shift ;;
    -d|--database) DB_NAME="$2"; shift ;;
    -h|--host) DB_HOST="$2"; shift ;;
    -m|--max-packet) MAX_PACKET="$2"; shift ;;
    -s|--sleep) SLEEP_SECONDS="$2"; shift ;;
    --path) CHUNKS_DIR="$2"; shift ;;
    --dry-run) DRY_RUN=true ;;
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

# Find all chunk files and sort them numerically based on chunk number
CHUNK_FILES=$(find "$CHUNKS_DIR" -name "chunk_*.sql" | sort -V)
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

# Generate an array of chunk numbers in the correct order
declare -a CHUNK_NUMBERS
for CHUNK_FILE in $CHUNK_FILES; do
  # Extract the chunk number from filename (between "chunk_" and ".sql")
  CHUNK_NUM=$(basename "$CHUNK_FILE" | sed -E 's/chunk_([0-9]+)\.sql/\1/')
  # Remove leading zeros
  CHUNK_NUM=$((10#$CHUNK_NUM))
  CHUNK_NUMBERS+=($CHUNK_NUM)
done

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
echo

# Create MySQL connection parameters
# Build the MySQL connection parameters
MYSQL_PARAMS=()
MYSQL_PARAMS+=("-u${DB_USER}")
if [ -n "$DB_PASS" ]; then
  MYSQL_PARAMS+=("-p${DB_PASS}")
fi
if [ -n "$DB_HOST" ]; then
  MYSQL_PARAMS+=("-h${DB_HOST}")
fi
MYSQL_PARAMS+=("--max_allowed_packet=${MAX_PACKET}")
MYSQL_PARAMS+=("${DB_NAME}")

# Function to import a single chunk
import_chunk() {
  local chunk_num=$1
  local chunk_file=$(printf "%s/chunk_%d.sql" "$CHUNKS_DIR" $chunk_num)

  # Skip if file doesn't exist
  if [ ! -f "$chunk_file" ]; then
    echo "Warning: Chunk file $chunk_file does not exist. Skipping."
    return 1
  fi

  # Execute import or show dry run information
  if [ "$DRY_RUN" = true ]; then
    # Just simulate import for dry run
    sleep 1
    echo "✅ Successfully simulated import of chunk $chunk_num (Dry Run)"
    return 0
  else
    # Actually import the chunk - redirect stderr to a temporary file to capture errors
    ERROR_FILE=$(mktemp)

    if cat "$chunk_file" | mysql "${MYSQL_PARAMS[@]}" 2>"$ERROR_FILE"; then
      # Move the file if requested and successful
      if [ "$MOVE_IMPORTED" = true ]; then
        mv "$chunk_file" "$COMPLETED_DIR/"
        if [ $? -eq 0 ]; then
          echo "✅ Successfully imported and moved chunk $chunk_num"
        else
          echo "✅ Successfully imported chunk $chunk_num (but move failed)"
        fi
      else
        echo "✅ Successfully imported chunk $chunk_num"
      fi

      # Clean up error file
      rm -f "$ERROR_FILE"
      return 0
    else
      echo "❌ Failed to import chunk $chunk_num"
      echo "MySQL Error Output:"
      cat "$ERROR_FILE"

      # Clean up error file
      rm -f "$ERROR_FILE"

      # Return the chunk number as exit code + 100 so we can extract it later
      # (We add 100 to avoid confusion with standard exit codes)
      return $((chunk_num + 100))
    fi
  fi
}

# Export function and variables for parallel
export -f import_chunk
export CHUNKS_DIR DB_USER DB_PASS DB_HOST DB_NAME MAX_PACKET DRY_RUN MOVE_IMPORTED COMPLETED_DIR
export MYSQL_PARAMS

# Calculate total chunks to import
CHUNKS_TO_IMPORT=$((TO_CHUNK - FROM_CHUNK + 1))

# Serial processing
CURRENT_CHUNK=0

# Function to update progress display
update_progress() {
  local chunk_num=$1
  local status=$2
  printf "\rProcessing: %d%% (%d/%d chunks) | Current: chunk_%d.sql | Status: %s   " \
    $(( (CURRENT_CHUNK) * 100 / CHUNKS_TO_IMPORT )) $CURRENT_CHUNK $CHUNKS_TO_IMPORT $chunk_num "$status"
}

SORTED_INDEX=0
for CHUNK_NUM in "${CHUNK_NUMBERS[@]}"; do
  SORTED_INDEX=$((SORTED_INDEX + 1))

  # Skip chunks before FROM_CHUNK or after TO_CHUNK
  if [ "$SORTED_INDEX" -lt "$FROM_CHUNK" ] || [ "$SORTED_INDEX" -gt "$TO_CHUNK" ]; then
    continue
  fi

  CHUNK_FILE=$(printf "%s/chunk_%d.sql" "$CHUNKS_DIR" $CHUNK_NUM)

  # Skip if file doesn't exist
  if [ ! -f "$CHUNK_FILE" ]; then
    echo "Warning: Chunk file $CHUNK_FILE does not exist. Skipping."
    continue
  fi

  CURRENT_CHUNK=$((CURRENT_CHUNK + 1))
  SUCCESS=false

  # Update progress as "Processing"
  update_progress $CHUNK_NUM "Processing"

  # Execute import or show dry run information
  if [ "$DRY_RUN" = true ]; then
    # Just simulate import for dry run
    sleep 1
    update_progress $CHUNK_NUM "Simulated (Dry Run)"
    echo -e "\n✅ Successfully simulated import of chunk $CHUNK_NUM (Dry Run)"
    SUCCESS=true
  else
    # Capture error output to a temporary file
    ERROR_FILE=$(mktemp)

    # Actually import the chunk
    if cat "$CHUNK_FILE" | mysql "${MYSQL_PARAMS[@]}" 2>"$ERROR_FILE"; then
      update_progress $CHUNK_NUM "Imported"
      SUCCESS=true

      # Move the file if requested and successful
      if [ "$MOVE_IMPORTED" = true ]; then
        mv "$CHUNK_FILE" "$COMPLETED_DIR/"
        if [ $? -eq 0 ]; then
          update_progress $CHUNK_NUM "Imported & Moved"
        else
          update_progress $CHUNK_NUM "Imported (Move Failed)"
        fi
      fi

      # Show success message on a new line
      # echo -e "\n✅ Successfully imported chunk $CHUNK_NUM"

      # Clean up error file
      rm -f "$ERROR_FILE"
    else
      update_progress $CHUNK_NUM "FAILED"
      # Clear the progress line before showing the error
      echo -e "\n❌ Failed to import chunk $CHUNK_NUM"

      # Display the MySQL error
      echo "MySQL Error Output:"
      cat "$ERROR_FILE"
      echo ""

      # Clean up error file
      rm -f "$ERROR_FILE"

      # Display retry message with all relevant parameters
      echo "You may want to retry from this chunk: $0 --from $CHUNK_NUM --to $TO_CHUNK --user \"$DB_USER\" --password \"$DB_PASS\" --database \"$DB_NAME\" ${DB_HOST:+--host \"$DB_HOST\"} ${MOVE_IMPORTED:+--move-imported \"$COMPLETED_DIR\"}"
      exit 1
    fi
  fi

  # Sleep between chunks if not the last chunk
  if [ "$SORTED_INDEX" -lt "$TO_CHUNK" ]; then
    sleep $SLEEP_SECONDS
  fi
done

# Final newline after progress display
echo -e "\nImport completed successfully for $CURRENT_CHUNK chunks."
if [ "$MOVE_IMPORTED" = true ]; then
  echo "Imported chunks have been moved to: $COMPLETED_DIR"
fi