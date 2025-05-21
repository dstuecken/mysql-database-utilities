#!/bin/bash
set -euo pipefail

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
        printf "\rProcessed %d lines | Progress: %d%% (%d/%d statements)" "$LINE_NUM" $PROGRESS_PERCENT $INSERT_COUNT $TOTAL_INSERTS
        debug_echo "Progress update: $PROGRESS_PERCENT% ($INSERT_COUNT/$TOTAL_INSERTS statements)"
    fi

    # Check if we need to start a new chunk
    if [ $((INSERT_COUNT % CHUNK_SIZE)) -eq 0 ]; then
        # Add footer to current chunk
        echo -e "$SQL_FOOTER" >> "$CURRENT_CHUNK_FILE"
        debug_echo "Completed chunk $CHUNK_NUM with $CHUNK_SIZE statements"

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

echo "Chunk size: $CHUNK_SIZE SQL statements per chunk"
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
SQL_HEADER+="SET foreign_key_checks=0;\nSET unique_checks=0;\nSET autocommit=0;\nBEGIN;\n"

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

# Count total SQL statements (both INSERT and REPLACE) for progress reporting
echo "Counting SQL statements (may take a moment for large files)..."
# Count beginning statements to get an approximate number
INSERT_COUNT=$(grep -c -E "^(INSERT INTO|REPLACE INTO)" "$INPUT_FILE")
echo "Found approximately $INSERT_COUNT SQL statements"

TOTAL_INSERTS=$INSERT_COUNT
# Exit if no statements found
if [ "$TOTAL_INSERTS" -eq 0 ]; then
  echo "No INSERT or REPLACE statements found in the file. Exiting."
  exit 1
fi

debug_echo "Total statements: $TOTAL_INSERTS"

# Variables for chunking
CHUNK_NUM=1
INSERT_COUNT=0
CURRENT_CHUNK_FILE="${CHUNKS_DIR}/chunk_$(printf "%02d" $CHUNK_NUM).sql"

debug_echo "Initial chunk file: $CURRENT_CHUNK_FILE"

# Start with header for first chunk
echo -e "$SQL_HEADER" > "$CURRENT_CHUNK_FILE"

# Process the file to extract SQL statements and apply chunking
LINE_NUM=0
COLLECTING_VALUES=false
CURRENT_INSERT_PREFIX=""
VALUES_ROWS=()
CURRENT_VALUES_LINE=""
IN_CREATE_TABLE=false

# Process the file line by line
while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))

    # Skip empty lines
    if [[ -z "$line" ]]; then
        continue
    fi

    # Skip comments
    if [[ "$line" == \#* ]] || [[ "$line" == --* ]]; then
        continue
    fi

    # Handle CREATE TABLE statements for structure extraction
    if [[ "$line" == "CREATE TABLE "* ]]; then
        IN_CREATE_TABLE=true
        if [ -n "$STRUCTURE_FILE" ]; then
            debug_echo "Skipping CREATE TABLE at line $LINE_NUM (already extracted)"
        fi
    fi

    if [ "$IN_CREATE_TABLE" = true ]; then
        if [[ "$line" == *";"* ]]; then
            IN_CREATE_TABLE=false
        fi
        continue
    fi

    # Check if this is the start of an INSERT or REPLACE statement with a VALUES clause
    if [[ "$line" == "INSERT INTO "* && "$line" == *" VALUES"* ]] || [[ "$line" == "REPLACE INTO "* && "$line" == *" VALUES"* ]]; then
        # If we were already collecting values, process all collected values
        if [ "$COLLECTING_VALUES" = true ]; then
            for value_row in "${VALUES_ROWS[@]}"; do
                echo "$CURRENT_INSERT_PREFIX VALUES $value_row;" >> "$CURRENT_CHUNK_FILE"
                process_complete_insert
            done
            VALUES_ROWS=()
        fi

        # Start collecting values for a new INSERT/REPLACE
        COLLECTING_VALUES=true

        # Replace INSERT INTO with REPLACE INTO if requested and not already REPLACE
        if [ "$REPLACE_MODE" = true ] && [[ "$line" == "INSERT INTO "* ]]; then
            line="${line/INSERT INTO/REPLACE INTO}"
            debug_echo "Converted INSERT to REPLACE at line $LINE_NUM"
        fi

        # Extract the prefix (everything before "VALUES")
        if [[ "$line" == *" VALUES ("* ]]; then
            # If VALUES and first value are on the same line
            CURRENT_INSERT_PREFIX="${line% VALUES*} VALUES"
            CURRENT_VALUES_LINE="${line#* VALUES }"
        else
            # If VALUES is at the end of the line
            CURRENT_INSERT_PREFIX="${line}"
            CURRENT_VALUES_LINE=""
        fi

        # If the line already includes a complete statement with a semicolon
        if [[ "$line" == *";"* ]]; then
            echo "$line" >> "$CURRENT_CHUNK_FILE"
            process_complete_insert
            COLLECTING_VALUES=false
        fi
    elif [ "$COLLECTING_VALUES" = true ]; then
        # Continue collecting values

        # Append the current line to the values collection
        if [ -z "$CURRENT_VALUES_LINE" ]; then
            CURRENT_VALUES_LINE="$line"
        else
            CURRENT_VALUES_LINE="$CURRENT_VALUES_LINE $line"
        fi

        # Check if we have a complete row (ending with a comma or semicolon)
        if [[ "$line" == *"),"* ]]; then
            # Found a row ending with a comma - store it
            row="${CURRENT_VALUES_LINE}"
            # Remove the trailing comma
            row="${row%,}"
            VALUES_ROWS+=("$row")
            CURRENT_VALUES_LINE=""
        elif [[ "$line" == *");"* ]]; then
            # Found the final row ending with a semicolon
            row="${CURRENT_VALUES_LINE}"
            # Remove the trailing semicolon
            row="${row%\;}"
            VALUES_ROWS+=("$row")

            # Process all collected values
            for value_row in "${VALUES_ROWS[@]}"; do
                echo "$CURRENT_INSERT_PREFIX VALUES $value_row;" >> "$CURRENT_CHUNK_FILE"
                process_complete_insert
            done

            # Reset for next collection
            COLLECTING_VALUES=false
            VALUES_ROWS=()
            CURRENT_VALUES_LINE=""
        fi
    else
        # This is some other kind of SQL statement, just echo it as-is
        echo "$line" >> "$CURRENT_CHUNK_FILE"

        # If this line completes a statement, count it
        if [[ "$line" == *";"* ]]; then
            process_complete_insert
        fi
    fi

    # Display progress periodically
    if [ $((LINE_NUM % 10000)) -eq 0 ]; then
        debug_echo "Processed $LINE_NUM lines"
    fi
done < "$INPUT_FILE"

# Process any remaining values
if [ "$COLLECTING_VALUES" = true ] && [ ${#VALUES_ROWS[@]} -gt 0 ]; then
    for value_row in "${VALUES_ROWS[@]}"; do
        echo "$CURRENT_INSERT_PREFIX VALUES $value_row;" >> "$CURRENT_CHUNK_FILE"
        process_complete_insert
    done
fi

# Add footer to final chunk
echo -e "$SQL_FOOTER" >> "$CURRENT_CHUNK_FILE"

echo ""  # New line after progress indicator
echo "Processing complete!"
echo "Created $CHUNK_NUM chunks in $CHUNKS_DIR"
if [ -n "$STRUCTURE_FILE" ]; then
    echo "Structure definitions saved to $STRUCTURE_FILE"
fi
echo "Total SQL statements processed: $INSERT_COUNT"