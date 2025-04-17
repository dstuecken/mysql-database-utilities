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

# Function to process a complete insert statement
process_complete_insert() {
    # Increment counter
    INSERT_COUNT=$((INSERT_COUNT + 1))

    # Display progress periodically
    if [ $((INSERT_COUNT % 10)) -eq 0 ]; then
        PROGRESS_PERCENT=$((INSERT_COUNT * 100 / TOTAL_INSERTS))
        printf "\rProcessed %d lines | Progress: %d%% (%d/%d inserts)" "$LINE_NUM" $PROGRESS_PERCENT $INSERT_COUNT $TOTAL_INSERTS
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

# Count total inserts for progress reporting
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

# Process the file to properly handle multi-line INSERT statements
echo "Creating chunks..."
IN_INSERT=false
CURRENT_INSERT=""
LINE_NUM=0

while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))

    # Debug every Nth line to avoid excessive output
    if [ "$DEBUG_MODE" = true ] && [ $((LINE_NUM % 1000)) -eq 0 ]; then
        debug_echo "Processing line $LINE_NUM"
    fi

    # Display combined progress every 5000 lines if we haven't shown progress from an INSERT recently
    if [ $((LINE_NUM % 5000)) -eq 0 ]; then
        PROGRESS_PERCENT=$((INSERT_COUNT * 100 / TOTAL_INSERTS))
        printf "\rProcessed %d lines | Progress: %d%% (%d/%d inserts)" "$LINE_NUM" $PROGRESS_PERCENT $INSERT_COUNT $TOTAL_INSERTS
    fi

    # Skip empty lines and comments when not in an INSERT
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*-- ]] && [ "$IN_INSERT" = false ]; then
        continue
    fi

    # Check if this line starts a new INSERT statement
    if [[ "$line" =~ ^[[:space:]]*[Ii][Nn][Ss][Ee][Rr][Tt][[:space:]][Ii][Nn][Tt][Oo] ]] && [ "$IN_INSERT" = false ]; then
        debug_echo "Found INSERT start at line $LINE_NUM: ${line:0:50}..."
        IN_INSERT=true
        CURRENT_INSERT="$line"

        # If this line also ends the INSERT statement
        if [[ "$line" =~ \;[[:space:]]*$ ]]; then
            debug_echo "Complete INSERT on single line: ${line:0:50}..."
            IN_INSERT=false

            # Process the INSERT statement
            if [ "$REPLACE_MODE" = true ]; then
                # Convert INSERT to REPLACE
                CURRENT_INSERT=$(echo "$CURRENT_INSERT" | sed 's/[Ii][Nn][Ss][Ee][Rr][Tt][[:space:]][Ii][Nn][Tt][Oo]/REPLACE INTO/g')
                debug_echo "Converted to REPLACE: ${CURRENT_INSERT:0:50}..."
            fi

            # Write to current chunk
            echo "$CURRENT_INSERT" >> "$CURRENT_CHUNK_FILE"

            # Increment counter and handle chunking
            process_complete_insert
        fi
    # Continue collecting the current INSERT statement
    elif [ "$IN_INSERT" = true ]; then
        CURRENT_INSERT="$CURRENT_INSERT"$'\n'"$line"

        # Check if this line ends the INSERT statement
        if [[ "$line" =~ \;[[:space:]]*$ ]]; then
            debug_echo "Found INSERT end at line $LINE_NUM"
            IN_INSERT=false

            # Process the INSERT statement
            if [ "$REPLACE_MODE" = true ]; then
                # Convert INSERT to REPLACE
                CURRENT_INSERT=$(echo "$CURRENT_INSERT" | sed 's/[Ii][Nn][Ss][Ee][Rr][Tt][[:space:]][Ii][Nn][Tt][Oo]/REPLACE INTO/g')
                debug_echo "Converted to REPLACE: ${CURRENT_INSERT:0:50}..."
            fi

            # Write to current chunk
            echo "$CURRENT_INSERT" >> "$CURRENT_CHUNK_FILE"

            # Increment counter and handle chunking
            process_complete_insert
        fi
    # Handle LOCK/UNLOCK TABLES statements only (skip DROP, CREATE, ALTER)
    elif [[ "$line" =~ ^[[:space:]]*[Ll][Oo][Cc][Kk][[:space:]][Tt][Aa][Bb][Ll][Ee][Ss] ]]; then
        debug_echo "Found LOCK TABLES at line $LINE_NUM: $line"
        echo "$line" >> "$CURRENT_CHUNK_FILE"
    elif [[ "$line" =~ ^[[:space:]]*[Uu][Nn][Ll][Oo][Cc][Kk][[:space:]][Tt][Aa][Bb][Ll][Ee][Ss] ]]; then
        debug_echo "Found UNLOCK TABLES at line $LINE_NUM: $line"
        echo "$line" >> "$CURRENT_CHUNK_FILE"
    fi
done < "$INPUT_FILE"

# Clear the progress line
printf "\r%-100s\r" " "

# Check if we're still inside an INSERT at the end of the file
if [ "$IN_INSERT" = true ]; then
    echo "Warning: File ended while processing an INSERT statement. The last INSERT might be incomplete."
fi

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