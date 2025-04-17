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
MAX_ALLOWED_PACKET="2073741824"  # 1GB default
SLEEP_SECONDS=3  # Sleep time between chunks

# Display usage instructions
usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -f, --from NUMBER     Start importing from chunk number (default: 1)"
  echo "  -t, --to NUMBER       Stop importing at chunk number (default: all chunks)"
  echo "  -d, --dry-run         Show what would be imported without actually importing"
  echo "  -p, --path DIRECTORY  Directory containing chunk files (default: ./import_chunks)"
  echo "  -u, --user USERNAME   Database username (default: root)"
  echo "  -w, --password PASS   Database password"
  echo "  -n, --database NAME   Database name (default: )"
  echo "  -h, --host HOST       Database host (default: local socket)"
  echo "  -m, --max-packet SIZE Max allowed packet size in bytes (default: 1073741824)"
  echo "  -s, --sleep SECONDS   Sleep time between chunks in seconds (default: 3)"
  echo "  --help                Display this help message"
  echo ""
  echo "Example: $0 --from 3 --to 7 --user dbadmin --password secret --database mydb --host dbserver"
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
    -m|--max-packet) MAX_ALLOWED_PACKET="$2"; shift ;;
    -s|--sleep) SLEEP_SECONDS="$2"; shift ;;
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

# Prepare connection string based on host setting
if [ -z "$DB_HOST" ]; then
  HOST_PARAM=""
  CONNECTION_DESC="local socket"
else
  HOST_PARAM="-h\"$DB_HOST\""
  CONNECTION_DESC="host '$DB_HOST'"
fi

echo "Preparing to import chunks $FROM_CHUNK to $TO_CHUNK into database '$DB_NAME' on $CONNECTION_DESC as user '$DB_USER'"
echo "Using max_allowed_packet size: $MAX_ALLOWED_PACKET bytes"
echo "Sleep between chunks: $SLEEP_SECONDS seconds"

# Function to clean up MySQL's memory usage
clear_mysql_cache() {
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would clear MySQL cache"
    return
  fi

  echo "Clearing MySQL cache to free memory..."
  if [ -z "$DB_HOST" ]; then
    mysql -u"$DB_USER" -p"$DB_PASS" -e "RESET QUERY CACHE;" 2>/dev/null || true
    mysql -u"$DB_USER" -p"$DB_PASS" -e "FLUSH TABLES;" 2>/dev/null || true
  else
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -e "RESET QUERY CACHE;" 2>/dev/null || true
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -e "FLUSH TABLES;" 2>/dev/null || true
  fi
}

# Function to import a chunk file with proper settings
import_chunk() {
  local chunk_file="$1"
  local chunk_num="$2"

  echo "Importing chunk $chunk_num: $chunk_file"

  if [ "$DRY_RUN" = true ]; then
    if [ -z "$DB_HOST" ]; then
      echo "[DRY RUN] Would execute: mysql -u$DB_USER -p**** $DB_NAME using local socket"
    else
      echo "[DRY RUN] Would execute: mysql -h$DB_HOST -u$DB_USER -p**** $DB_NAME"
    fi
  else
    # Create a temp file with settings and commit
    local temp_import_file=$(mktemp)

    cat > "$temp_import_file" << EOL
SET foreign_key_checks=0;
SET unique_checks=0;
SET autocommit=0;
SET GLOBAL max_allowed_packet=$MAX_ALLOWED_PACKET;
SET GLOBAL innodb_flush_log_at_trx_commit=2;
SET sql_log_bin=0;
SOURCE $chunk_file;
COMMIT;
EOL

    # Run the import with or without host parameter
    local attempts=0
    local max_attempts=3
    local success=false

    while [ $attempts -lt $max_attempts ] && [ "$success" = false ]; do
      if [ -z "$DB_HOST" ]; then
        mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$temp_import_file"
      else
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$temp_import_file"
      fi

      local result=$?

      if [ $result -eq 0 ]; then
        success=true
      else
        attempts=$((attempts + 1))
        echo "❌ Attempt $attempts failed. Waiting 10 seconds before retrying..."
        clear_mysql_cache
        sleep 10
      fi
    done

    rm -f "$temp_import_file"

    if [ "$success" = true ]; then
      echo "✅ Successfully imported chunk $chunk_num"
    else
      echo "❌ Failed to import chunk $chunk_num after $max_attempts attempts"
      exit 1
    fi
  fi
}

# Process each chunk file
for chunk_file in $CHUNK_FILES; do
  chunk_basename=$(basename "$chunk_file")

  # Extract the chunk number
  if [[ $chunk_basename =~ chunk_([0-9]+)\.sql ]]; then
    chunk_num=${BASH_REMATCH[1]#0}  # Remove leading zeros

    # Check if this chunk is in our target range
    if [ "$chunk_num" -ge "$FROM_CHUNK" ] && [ "$chunk_num" -le "$TO_CHUNK" ]; then
      import_chunk "$chunk_file" "$chunk_num"

      # Sleep between chunks to allow memory recovery
      if [ "$chunk_num" -lt "$TO_CHUNK" ]; then
        echo "Sleeping for $SLEEP_SECONDS seconds before next chunk..."
        sleep $SLEEP_SECONDS

        # Attempt to clear MySQL cache to free memory
        clear_mysql_cache
      fi
    fi
  fi
done

# Reset database settings if not in dry run mode
if [ "$DRY_RUN" = false ]; then
  echo "Resetting database settings..."

  # Run with or without host parameter
  if [ -z "$DB_HOST" ]; then
    mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SET foreign_key_checks=1; SET unique_checks=1; SET autocommit=1;"
  else
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SET foreign_key_checks=1; SET unique_checks=1; SET autocommit=1;"
  fi
fi

echo "Import process completed."