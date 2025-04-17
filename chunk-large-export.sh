#!/bin/bash

# Default values
CHUNK_SIZE=200  # Number of INSERT statements per chunk
INPUT_FILE="dump.sql"  # Default input file
REPLACE_MODE=false
CHUNKS_DIR="./chunks"  # Default output directory
DEBUG_MODE=false

# Display usage instructions
usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -r, --replace-into    Convert INSERT INTO statements to REPLACE INTO"
  echo "  -c, --chunk-size SIZE Number of INSERT statements per chunk (default: 200)"
  echo "  -i, --input FILE      Input SQL file to process (default: dump.sql)"
  echo "  -o, --output DIR      Output directory for chunks (default: ./chunks)"
  echo "  -d, --debug           Enable debug mode with verbose output"
  echo "  --help                Display this help message"
  exit 1
}

# Debug echo function
debug_echo() {
  if [ "$DEBUG_MODE" = true ]; then
    echo "[DEBUG] $1"
  fi
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -r|--replace-into) REPLACE_MODE=true ;;
    -c|--chunk-size) CHUNK_SIZE="$2"; shift ;;
    -i|--input) INPUT_FILE="$2"; shift ;;
    -o|--output) CHUNKS_DIR="$2"; shift ;;
    -d|--debug) DEBUG_MODE=true ;;
    --help) usage ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
  shift
done

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: Input file '$INPUT_FILE' does not exist."
  exit 1
fi

echo "Chunk size: $CHUNK_SIZE INSERT statements per chunk"
echo "Output directory: $CHUNKS_DIR"
if [ "$DEBUG_MODE" = true ]; then
  echo "Debug mode: ENABLED"
fi

# Create output directory if it doesn't exist
mkdir -p "$CHUNKS_DIR"

# Get file size for reporting
FILE_SIZE=$(du -h "$INPUT_FILE" | cut -f1)
echo "File size: $FILE_SIZE"

# Create SQL header with settings
SQL_HEADER="SET foreign_key_checks=0;\nSET unique_checks=0;\nSET autocommit=0;\nSET GLOBAL max_allowed_packet=1073741824;\nSET GLOBAL innodb_flush_log_at_trx_commit=2;\nSET sql_log_bin=0;\n"

# Create SQL footer with commit
SQL_FOOTER="\nCOMMIT;\nSET foreign_key_checks=1;\nSET unique_checks=1;\nSET autocommit=1;"

debug_echo "SQL Header: $SQL_HEADER"
debug_echo "SQL Footer: $SQL_FOOTER"

echo "Processing SQL file in a single pass..."

# Count total inserts first for progress reporting
echo "Counting INSERT statements (may take a moment for large files)..."
TOTAL_INSERTS=$(grep -c -i "INSERT INTO" "$INPUT_FILE")
echo "Found approximately $TOTAL_INSERTS INSERT statements"

# Exit if no INSERT statements found
if [ "$TOTAL_INSERTS" -eq 0 ]; then
  echo "No INSERT statements found in the file. Exiting."
  exit 1
fi

debug_echo "Total INSERT statements: $TOTAL_INSERTS"

# Variables for chunking
CHUNK_NUM=1
INSERT_COUNT=0
CURRENT_CHUNK_FILE="${CHUNKS_DIR}/chunk_$(printf "%02d" $CHUNK_NUM).sql"

debug_echo "Initial chunk file: $CURRENT_CHUNK_FILE"

# Start with header for first chunk
echo -e "$SQL_HEADER" > "$CURRENT_CHUNK_FILE"

# Process the file line by line - much faster single-pass approach
echo "Creating chunks..."
LINE_NUM=0
while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))

    # Debug every Nth line to avoid excessive output
    if [ "$DEBUG_MODE" = true ] && [ $((LINE_NUM % 1000)) -eq 0 ]; then
        debug_echo "Processing line $LINE_NUM"
    fi

    # Check if it's an INSERT statement
    if [[ "$line" =~ ^[[:space:]]*[Ii][Nn][Ss][Ee][Rr][Tt][[:space:]][Ii][Nn][Tt][Oo] ]]; then
        debug_echo "Found INSERT at line $LINE_NUM: ${line:0:50}..."

        # Process INSERT statement
        if [ "$REPLACE_MODE" = true ]; then
            # Convert INSERT to REPLACE
            line=$(echo "$line" | sed 's/[Ii][Nn][Ss][Ee][Rr][Tt][[:space:]][Ii][Nn][Tt][Oo]/REPLACE INTO/g')
            debug_echo "Converted to REPLACE: ${line:0:50}..."
        fi

        # Write to current chunk
        echo "$line" >> "$CURRENT_CHUNK_FILE"

        # Increment counter
        INSERT_COUNT=$((INSERT_COUNT + 1))

        # Display progress periodically
        if [ $((INSERT_COUNT % 50)) -eq 0 ]; then
            PROGRESS_PERCENT=$((INSERT_COUNT * 100 / TOTAL_INSERTS))
            printf "\rProgress: %d%% (%d/%d inserts)" $PROGRESS_PERCENT $INSERT_COUNT $TOTAL_INSERTS
            debug_echo "Progress update: $PROGRESS_PERCENT% ($INSERT_COUNT/$TOTAL_INSERTS inserts)"
        fi

        # Check if we need to start a new chunk
        if [ $((INSERT_COUNT % CHUNK_SIZE)) -eq 0 ]; then
            # Add footer to current chunk
            echo -e "$SQL_FOOTER" >> "$CURRENT_CHUNK_FILE"
            debug_echo "Completed chunk $CHUNK_NUM with $CHUNK_SIZE inserts"

            # Start a new chunk
            CHUNK_NUM=$((CHUNK_NUM + 1))
            CURRENT_CHUNK_FILE="${CHUNKS_DIR}/chunk_$(printf "%02d" $CHUNK_NUM).sql"
            debug_echo "Starting new chunk: $CURRENT_CHUNK_FILE"

            # Add header to new chunk
            echo -e "$SQL_HEADER" > "$CURRENT_CHUNK_FILE"
        fi
    # Check for LOCK/UNLOCK TABLES statements
    elif [[ "$line" =~ ^[[:space:]]*[Ll][Oo][Cc][Kk][[:space:]][Tt][Aa][Bb][Ll][Ee][Ss] ]]; then
        debug_echo "Found LOCK TABLES at line $LINE_NUM: $line"
        echo "$line" >> "$CURRENT_CHUNK_FILE"
    elif [[ "$line" =~ ^[[:space:]]*[Uu][Nn][Ll][Oo][Cc][Kk][[:space:]][Tt][Aa][Bb][Ll][Ee][Ss] ]]; then
        debug_echo "Found UNLOCK TABLES at line $LINE_NUM: $line"
        echo "$line" >> "$CURRENT_CHUNK_FILE"
    # Include CREATE, ALTER, DROP and other important SQL statements
    elif [[ "$line" =~ ^[[:space:]]*([Cc][Rr][Ee][Aa][Tt][Ee]|[Dd][Rr][Oo][Pp]|[Aa][Ll][Tt][Ee][Rr])[[:space:]] ]]; then
        debug_echo "Found schema statement at line $LINE_NUM: ${line:0:50}..."
        echo "$line" >> "$CURRENT_CHUNK_FILE"
    fi
done < "$INPUT_FILE"

# Additional check - if no inserts were actually processed
if [ "$INSERT_COUNT" -eq 0 ]; then
  echo "No INSERT statements were processed. Removing empty chunks and exiting."
  rm -f "${CHUNKS_DIR}/chunk_"*.sql
  exit 1
fi

# Add footer to the last chunk
echo -e "$SQL_FOOTER" >> "$CURRENT_CHUNK_FILE"
debug_echo "Added footer to final chunk $CHUNK_NUM"

echo -e "\nFinished processing $INSERT_COUNT INSERT statements into $CHUNK_NUM chunks"
debug_echo "Final statistics: $INSERT_COUNT inserts, $CHUNK_NUM chunks, $LINE_NUM total lines processed"
echo "Done! Chunks are available in $CHUNKS_DIR/"