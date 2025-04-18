#!/bin/bash

# Default values
CHUNK_SIZE=200  # Number of INSERT statements per chunk
INPUT_FILE="dump.sql"  # Default input file
REPLACE_MODE=false
CHUNKS_DIR="./chunks"  # Default output directory
DEBUG_MODE=false
STRUCTURE_FILE=""  # File to store structure (CREATE TABLE statements)

# Display usage instructions
usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -r, --replace-into    Convert INSERT INTO statements to REPLACE INTO"
  echo "  -c, --chunk-size SIZE Number of INSERT statements per chunk (default: 200)"
  echo "  -i, --input FILE      Input SQL file to process (default: dump.sql)"
  echo "  -o, --output DIR      Output directory for chunks (default: ./chunks)"
  echo "  -s, --structure FILE  Extract CREATE TABLE statements to specified file"
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
    -s|--structure) STRUCTURE_FILE="$2"; shift ;;
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
if [ -n "$STRUCTURE_FILE" ]; then
  echo "Structure output file: $STRUCTURE_FILE"
fi
if [ "$DEBUG_MODE" = true ]; then
  echo "Debug mode: ENABLED"
fi

# Create output directory if it doesn't exist
mkdir -p "$CHUNKS_DIR"

# Get file size for reporting
FILE_SIZE=$(du -h "$INPUT_FILE" | cut -f1)
echo "File size: $FILE_SIZE"

# Create SQL header with settings
SQL_HEADER="-- Created with https://github.com/dstuecken/mysql-database-utilities - $(date)\n"

# Create SQL footer with commit
SQL_FOOTER="\nCOMMIT;\nSET foreign_key_checks=1;\nSET unique_checks=1;\nSET autocommit=1;"

debug_echo "SQL Header: $SQL_HEADER"
debug_echo "SQL Footer: $SQL_FOOTER"

# Extract CREATE TABLE statements if structure file is specified
if [ -n "$STRUCTURE_FILE" ]; then
  echo "Extracting structure to $STRUCTURE_FILE..."

  # Create structure file with header
  echo -e "$SQL_HEADER" > "$STRUCTURE_FILE"

  # Extract CREATE TABLE statements and append to structure file
  grep -n "^CREATE TABLE" "$INPUT_FILE" | while IFS=':' read -r line_num line_content; do
    debug_echo "Found CREATE TABLE at line $line_num"

    # Initialize variables for multi-line capture
    create_statement="$line_content"
    current_line=$((line_num + 1))

    # Continue reading until we find the closing semicolon
    while true; do
      next_line=$(sed -n "${current_line}p" "$INPUT_FILE")
      create_statement="$create_statement"$'\n'"$next_line"

      # If this line has a semicolon, we're done with this CREATE TABLE
      if [[ "$next_line" == *";"* ]]; then
        break
      fi

      current_line=$((current_line + 1))
    done

    # Add the complete CREATE TABLE statement to the structure file
    echo "$create_statement" >> "$STRUCTURE_FILE"
    echo "" >> "$STRUCTURE_FILE"  # Add a newline for readability
  done

  # Add footer to structure file
  echo -e "$SQL_FOOTER" >> "$STRUCTURE_FILE"

  echo "Structure extraction completed."
fi

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

# Process the file to extract INSERT statements and apply chunking
LINE_NUM=0
IN_INSERT=false
CURRENT_INSERT=""

# Process the file line by line
while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))

    # Skip structure lines if they're part of a CREATE TABLE statement (already extracted)
    if [[ "$line" == "CREATE TABLE "* ]] && [ -n "$STRUCTURE_FILE" ]; then
        debug_echo "Skipping CREATE TABLE at line $LINE_NUM (already extracted)"
        # Skip until we find a line ending with semicolon
        while IFS= read -r create_line; do
            LINE_NUM=$((LINE_NUM + 1))
            if [[ "$create_line" == *";"* ]]; then
                break
            fi
        done
        continue
    fi

    # Check if this is the start of an INSERT statement
    if [[ "$line" == "INSERT INTO "* ]] || [ "$REPLACE_MODE" = true ] && [[ "$line" == "REPLACE INTO "* ]]; then
        # If we were already processing an INSERT statement, process the completed one
        if [ "$IN_INSERT" = true ]; then
            # Add the complete INSERT to the current chunk
            echo "$CURRENT_INSERT" >> "$CURRENT_CHUNK_FILE"
            process_complete_insert
        fi

        # Start a new INSERT
        IN_INSERT=true

        # Replace INSERT INTO with REPLACE INTO if requested
        if [ "$REPLACE_MODE" = true ] && [[ "$line" == "INSERT INTO "* ]]; then
            line="${line/INSERT INTO/REPLACE INTO}"
            debug_echo "Converted INSERT to REPLACE at line $LINE_NUM"
        fi

        CURRENT_INSERT="$line"

        # If INSERT is complete (ends with semicolon), process it immediately
        if [[ "$line" == *";"* ]]; then
            # Add the complete INSERT to the current chunk
            echo "$CURRENT_INSERT" >> "$CURRENT_CHUNK_FILE"
            process_complete_insert
            IN_INSERT=false
            CURRENT_INSERT=""
        fi
    elif [ "$IN_INSERT" = true ]; then
        # Continue building the current INSERT statement
        CURRENT_INSERT="$CURRENT_INSERT"$'\n'"$line"

        # If we've reached the end of the INSERT (semicolon), process it
        if [[ "$line" == *";"* ]]; then
            # Add the complete INSERT to the current chunk
            echo "$CURRENT_INSERT" >> "$CURRENT_CHUNK_FILE"
            process_complete_insert
            IN_INSERT=false
            CURRENT_INSERT=""
        fi
    fi

    # Display progress periodically based on line count
    if [ $((LINE_NUM % 10000)) -eq 0 ]; then
        debug_echo "Processed $LINE_NUM lines"
    fi

done < "$INPUT_FILE"

# Process any remaining INSERT statement
if [ "$IN_INSERT" = true ]; then
    echo "$CURRENT_INSERT" >> "$CURRENT_CHUNK_FILE"
    process_complete_insert
fi

# Add footer to final chunk
echo -e "$SQL_FOOTER" >> "$CURRENT_CHUNK_FILE"

echo ""  # New line after progress indicator
echo "Processing complete!"
echo "Created $CHUNK_NUM chunks in $CHUNKS_DIR"
if [ -n "$STRUCTURE_FILE" ]; then
    echo "Structure definitions saved to $STRUCTURE_FILE"
fi
echo "Total INSERT statements processed: $INSERT_COUNT"