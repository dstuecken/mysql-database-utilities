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
MAX_ALLOWED_PACKET="2073741824"  # ~2GB default
SLEEP_SECONDS=3  # Sleep time between chunks

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
echo "Sleep between chunks: $SLEEP_SECONDS seconds"

# Function to check if user has SUPER privileges
check_super_privileges() {
  local has_super=0

  if [ -z "$DB_HOST" ]; then
    has_super=$(mysql -u"$DB_USER" ${DB_PASS:+-p"$DB_PASS"} -e "SELECT COUNT(*) FROM information_schema.user_privileges WHERE GRANTEE LIKE CONCAT('''', SUBSTRING_INDEX(CURRENT_USER(), '@', 1), '''@%''') AND PRIVILEGE_TYPE = 'SUPER'" 2>/dev/null | grep -v "COUNT" | tr -d ' ' || echo "0")
  else
    has_super=$(mysql -h"$DB_HOST" -u"$DB_USER" ${DB_PASS:+-p"$DB_PASS"} -e "SELECT COUNT(*) FROM information_schema.user_privileges WHERE GRANTEE LIKE CONCAT('''', SUBSTRING_INDEX(CURRENT_USER(), '@', 1), '''@%''') AND PRIVILEGE_TYPE = 'SUPER'" 2>/dev/null | grep -v "COUNT" | tr -d ' ' || echo "0")
  fi

  if [ "$has_super" -gt 0 ]; then
    return 0  # Success - has super privileges
  else
    return 1  # Failure - no super privileges
  fi
}

# Check for SUPER privileges
HAS_SUPER=false
if check_super_privileges; then
  HAS_SUPER=true
  echo "User has SUPER privileges. Will execute commands requiring SUPER privileges."
else
  echo "User does not have SUPER privileges. Commands requiring SUPER privileges will be skipped."
fi

# Function to clean up MySQL's memory usage
clear_mysql_cache() {
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would clear MySQL cache"
    return
  fi

  if [ "$HAS_SUPER" = true ]; then
    echo "Clearing MySQL cache to free memory..."
    if [ -z "$DB_HOST" ]; then
      mysql -u"$DB_USER" ${DB_PASS:+-p"$DB_PASS"} -e "FLUSH TABLES;" 2>/dev/null || true
      # RESET QUERY CACHE is only available in older MySQL versions
      mysql -u"$DB_USER" ${DB_PASS:+-p"$DB_PASS"} -e "RESET QUERY CACHE;" 2>/dev/null || true
    else
      mysql -h"$DB_HOST" -u"$DB_USER" ${DB_PASS:+-p"$DB_PASS"} -e "FLUSH TABLES;" 2>/dev/null || true
      mysql -h"$DB_HOST" -u"$DB_USER" ${DB_PASS:+-p"$DB_PASS"} -e "RESET QUERY CACHE;" 2>/dev/null || true
    fi
  else
    echo "Skipping cache clearing (requires SUPER privileges)"
  fi
}

# Function to import a chunk file with proper settings
import_chunk() {
  local chunk_file="$1"
  local chunk_num="$2"

  echo "Importing chunk $chunk_num: $chunk_file"

  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would import $chunk_file"
    return 0
  fi

  # Create a temporary file for the filtered SQL
  local temp_sql=$(mktemp)

  # Filter the SQL file based on user privileges
  if [ "$HAS_SUPER" = true ]; then
    # User has SUPER privileges, no need to filter
    cp "$chunk_file" "$temp_sql"
  else
    # User doesn't have SUPER privileges, filter out commands requiring them
    echo "Filtering SQL statements that require SUPER privileges..."

    # Process the file line by line to properly handle multi-line statements
    local in_global_statement=false
    while IFS= read -r line || [ -n "$line" ]; do
      # Skip empty lines or comments
      if [[ -z "$line" || "$line" =~ ^[[:space:]]*-- ]]; then
        echo "$line" >> "$temp_sql"
        continue
      fi

      # Check if this line contains a statement requiring SUPER privileges
      if [[ "$line" =~ (SET[[:space:]]+GLOBAL|SET[[:space:]]+@@GLOBAL) ]]; then
        echo "  - Skipping line requiring SUPER privileges: $line"
        in_global_statement=true
        continue
      fi

      # If we're in a multi-line statement that requires SUPER, continue skipping
      if [ "$in_global_statement" = true ]; then
        # Check if this line ends the statement
        if [[ "$line" =~ \;[[:space:]]*$ ]]; then
          in_global_statement=false
        fi
        echo "  - Skipping continuation line: $line"
        continue
      fi

      # This line doesn't require SUPER privileges, add it to the output
      echo "$line" >> "$temp_sql"
    done < "$chunk_file"
  fi

  # Build MySQL command
  local mysql_cmd="mysql"

  if [ -n "$DB_HOST" ]; then
    mysql_cmd+=" -h\"$DB_HOST\""
  fi

  mysql_cmd+=" -u\"$DB_USER\""

  if [ -n "$DB_PASS" ]; then
    mysql_cmd+=" -p\"$DB_PASS\""
  fi

  if [ -n "$DB_NAME" ]; then
    mysql_cmd+=" \"$DB_NAME\""
  fi

  # Import the filtered chunk file
  echo "Executing SQL import..."
  cat "$temp_sql" | eval $mysql_cmd
  local import_status=$?

  # Clean up temp file
  rm -f "$temp_sql"

  # Return the status of the import command
  return $import_status
}

# Check if we're in dry run mode
if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] No actual imports will be performed"
fi

# Count the chunks to process
CHUNKS_TO_PROCESS=$((TO_CHUNK - FROM_CHUNK + 1))
echo "Will process $CHUNKS_TO_PROCESS chunks"

# Create a temp file for MySQL password
if [ -n "$DB_PASS" ]; then
  MYSQL_DEFAULTS_FILE=$(mktemp)
  echo "[client]" > "$MYSQL_DEFAULTS_FILE"
  echo "password=$DB_PASS" >> "$MYSQL_DEFAULTS_FILE"
  chmod 600 "$MYSQL_DEFAULTS_FILE"
  MYSQL_AUTH="--defaults-extra-file=$MYSQL_DEFAULTS_FILE"
else
  MYSQL_AUTH=""
fi

# Process each chunk file
CURRENT_CHUNK=0
for chunk_file in $CHUNK_FILES; do
  CURRENT_CHUNK=$((CURRENT_CHUNK + 1))

  # Skip chunks before FROM_CHUNK
  if [ "$CURRENT_CHUNK" -lt "$FROM_CHUNK" ]; then
    continue
  fi

  # Stop after TO_CHUNK
  if [ "$CURRENT_CHUNK" -gt "$TO_CHUNK" ]; then
    break
  fi

  # Get chunk number from filename
  CHUNK_NUM=$(basename "$chunk_file" | sed -E 's/chunk_([0-9]+)\.sql/\1/')

  echo "--- Processing chunk $CURRENT_CHUNK of $CHUNKS_TO_PROCESS (file: $chunk_file) ---"

  # Import the chunk
  if import_chunk "$chunk_file" "$CHUNK_NUM"; then
    echo "Chunk $CHUNK_NUM imported successfully"
  else
    echo "ERROR: Failed to import chunk $CHUNK_NUM"
    if [ -n "$MYSQL_DEFAULTS_FILE" ] && [ -f "$MYSQL_DEFAULTS_FILE" ]; then
      rm -f "$MYSQL_DEFAULTS_FILE"
    fi
    exit 1
  fi

  # Clear cache to free memory
  clear_mysql_cache

  # Sleep between chunks if not the last one
  if [ "$CURRENT_CHUNK" -lt "$TO_CHUNK" ]; then
    echo "Sleeping for $SLEEP_SECONDS seconds before next chunk..."
    sleep "$SLEEP_SECONDS"
  fi
done

# Clean up temp file
if [ -n "$MYSQL_DEFAULTS_FILE" ] && [ -f "$MYSQL_DEFAULTS_FILE" ]; then
  rm -f "$MYSQL_DEFAULTS_FILE"
fi

echo "All chunks imported successfully!"
exit 0