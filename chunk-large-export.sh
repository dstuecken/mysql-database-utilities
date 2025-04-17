#!/bin/bash

# Default values
DB_USER="root"
DB_PASS=""
DB_NAME=""
DB_HOST=""  # Empty means use local socket
CHUNK_SIZE=200  # Number of INSERT statements per chunk
INPUT_FILE="dump.sql"  # Default input file
REPLACE_MODE=false
CHUNKS_DIR="./chunks"  # Default output directory

# Display usage instructions
usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -r, --replace-into    Convert INSERT INTO statements to REPLACE INTO"
  echo "  -u, --user USERNAME   Database username (default: root)"
  echo "  -w, --password PASS   Database password (default: )"
  echo "  -n, --database NAME   Database name (default: )"
  echo "  -h, --host HOST       Database host (default: local socket)"
  echo "  -c, --chunk-size SIZE Number of INSERT statements per chunk (default: 200)"
  echo "  -i, --input FILE      Input SQL file to process (default: dump.sql)"
  echo "  -o, --output DIR      Output directory for chunks (default: ./chunks)"
  echo "  --help                Display this help message"
  exit 1
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -r|--replace-into) REPLACE_MODE=true ;;
    -u|--user) DB_USER="$2"; shift ;;
    -w|--password) DB_PASS="$2"; shift ;;
    -n|--database) DB_NAME="$2"; shift ;;
    -h|--host) DB_HOST="$2"; shift ;;
    -c|--chunk-size) CHUNK_SIZE="$2"; shift ;;
    -i|--input) INPUT_FILE="$2"; shift ;;
    -o|--output) CHUNKS_DIR="$2"; shift ;;
    --help) usage ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
  shift
done

if [ "$REPLACE_MODE" = true ]; then
  echo "Converting INSERT INTO statements to REPLACE INTO"
fi

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: Input file '$INPUT_FILE' does not exist."
  exit 1
fi

echo "Database connection: ${DB_USER}@${DB_HOST:-localhost}/${DB_NAME}"
echo "Chunk size: $CHUNK_SIZE INSERT statements per chunk"
echo "Output directory: $CHUNKS_DIR"

# Create temp directory
TEMP_DIR=$(mktemp -d)
echo "Working in: $TEMP_DIR"

# Create initial settings file
cat > "$TEMP_DIR/settings.sql" << EOL
SET foreign_key_checks=0;
SET unique_checks=0;
SET autocommit=0;
SET GLOBAL max_allowed_packet=1073741824;
SET GLOBAL innodb_flush_log_at_trx_commit=2;
SET sql_log_bin=0;
EOL

# Process INSERT statements
CHUNK_NUM=1
INSERT_COUNT=0

# Format chunk number with leading zero if needed
format_chunk_num() {
    if [ "$1" -lt 10 ]; then
        echo "0$1"
    else
        echo "$1"
    fi
}

FORMATTED_CHUNK_NUM=$(format_chunk_num $CHUNK_NUM)
CURRENT_CHUNK="$TEMP_DIR/chunk_$FORMATTED_CHUNK_NUM.sql"

# Start with settings
cat "$TEMP_DIR/settings.sql" > "$CURRENT_CHUNK"

# State tracking
in_insert=0
insert_buffer=""

echo "Scanning file for INSERT statements..."

# Process the file line by line
while IFS= read -r line; do
    # Check if line contains an INSERT statement (more flexible matching)
    if [[ "$line" =~ [Ii][Nn][Ss][Ee][Rr][Tt].[Ii][Nn][Tt][Oo] ]]; then
        # If we were already processing an INSERT, save it first
        if [ $in_insert -eq 1 ]; then
            # Apply REPLACE conversion if needed
            if [ "$REPLACE_MODE" = true ]; then
                insert_buffer=$(echo "$insert_buffer" | sed 's/[Ii][Nn][Ss][Ee][Rr][Tt].[Ii][Nn][Tt][Oo]/REPLACE INTO/g')
            fi

            echo "$insert_buffer" >> "$CURRENT_CHUNK"
            INSERT_COUNT=$((INSERT_COUNT + 1))

            # Check if we need to start a new chunk
            if [ $INSERT_COUNT -ge $CHUNK_SIZE ]; then
                # Add commit to the end of the chunk
                echo "COMMIT;" >> "$CURRENT_CHUNK"
                echo "Created chunk $FORMATTED_CHUNK_NUM with $INSERT_COUNT INSERT statements"
                CHUNK_NUM=$((CHUNK_NUM + 1))
                FORMATTED_CHUNK_NUM=$(format_chunk_num $CHUNK_NUM)
                CURRENT_CHUNK="$TEMP_DIR/chunk_$FORMATTED_CHUNK_NUM.sql"
                cat "$TEMP_DIR/settings.sql" > "$CURRENT_CHUNK"
                INSERT_COUNT=0
            fi
        fi

        # Start tracking a new INSERT
        in_insert=1

        # Apply REPLACE conversion if needed
        if [ "$REPLACE_MODE" = true ]; then
            line=$(echo "$line" | sed 's/[Ii][Nn][Ss][Ee][Rr][Tt].[Ii][Nn][Tt][Oo]/REPLACE INTO/g')
        fi

        insert_buffer="$line"

        # If the line already ends with a semicolon, it's a complete statement
        if [[ "$line" =~ \;$ ]]; then
            echo "$insert_buffer" >> "$CURRENT_CHUNK"
            INSERT_COUNT=$((INSERT_COUNT + 1))
            in_insert=0
            insert_buffer=""

            # Check if we need to start a new chunk
            if [ $INSERT_COUNT -ge $CHUNK_SIZE ]; then
                # Add commit to the end of the chunk
                echo "COMMIT;" >> "$CURRENT_CHUNK"
                echo "Created chunk $FORMATTED_CHUNK_NUM with $INSERT_COUNT INSERT statements"
                CHUNK_NUM=$((CHUNK_NUM + 1))
                FORMATTED_CHUNK_NUM=$(format_chunk_num $CHUNK_NUM)
                CURRENT_CHUNK="$TEMP_DIR/chunk_$FORMATTED_CHUNK_NUM.sql"
                cat "$TEMP_DIR/settings.sql" > "$CURRENT_CHUNK"
                INSERT_COUNT=0
            fi
        fi
    elif [ $in_insert -eq 1 ]; then
        # Continue adding to current INSERT statement
        insert_buffer="$insert_buffer
$line"

        # Check if this line ends the INSERT statement
        if [[ "$line" =~ \;$ ]]; then
            # Apply REPLACE conversion if needed before saving
            if [ "$REPLACE_MODE" = true ]; then
                insert_buffer=$(echo "$insert_buffer" | sed 's/[Ii][Nn][Ss][Ee][Rr][Tt].[Ii][Nn][Tt][Oo]/REPLACE INTO/g')
            fi

            echo "$insert_buffer" >> "$CURRENT_CHUNK"
            INSERT_COUNT=$((INSERT_COUNT + 1))
            in_insert=0
            insert_buffer=""

            # Check if we need to start a new chunk
            if [ $INSERT_COUNT -ge $CHUNK_SIZE ]; then
                # Add commit to the end of the chunk
                echo "COMMIT;" >> "$CURRENT_CHUNK"
                echo "Created chunk $FORMATTED_CHUNK_NUM with $INSERT_COUNT INSERT statements"
                CHUNK_NUM=$((CHUNK_NUM + 1))
                FORMATTED_CHUNK_NUM=$(format_chunk_num $CHUNK_NUM)
                CURRENT_CHUNK="$TEMP_DIR/chunk_$FORMATTED_CHUNK_NUM.sql"
                cat "$TEMP_DIR/settings.sql" > "$CURRENT_CHUNK"
                INSERT_COUNT=0
            fi
        fi
    fi
done < "$INPUT_FILE"

# Handle any remaining INSERT statement
if [ $in_insert -eq 1 ] && [ ! -z "$insert_buffer" ]; then
    # Apply REPLACE conversion if needed
    if [ "$REPLACE_MODE" = true ]; then
        insert_buffer=$(echo "$insert_buffer" | sed 's/[Ii][Nn][Ss][Ee][Rr][Tt].[Ii][Nn][Tt][Oo]/REPLACE INTO/g')
    fi

    echo "$insert_buffer" >> "$CURRENT_CHUNK"
    INSERT_COUNT=$((INSERT_COUNT + 1))
fi

# Add commit to the final chunk
echo "COMMIT;" >> "$CURRENT_CHUNK"

echo "Created final chunk $FORMATTED_CHUNK_NUM with $INSERT_COUNT INSERT statements"
echo "Total chunks created: $CHUNK_NUM"

# Copy the files to the output directory
mkdir -p "$CHUNKS_DIR"
cp "$TEMP_DIR"/chunk_*.sql "$CHUNKS_DIR/"
echo "All chunks copied to $CHUNKS_DIR directory"

# Display import instructions
echo "Chunks have been created in the $CHUNKS_DIR directory."
if [ -z "$DB_HOST" ]; then
    echo "To import later, run: for f in $CHUNKS_DIR/chunk_*.sql; do mysql -u$DB_USER -p$DB_PASS $DB_NAME < \$f; done"
else
    echo "To import later, run: for f in $CHUNKS_DIR/chunk_*.sql; do mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME < \$f; done"
fi

# Clean up temporary files
rm -rf "$TEMP_DIR"
echo "Temporary files cleaned up"