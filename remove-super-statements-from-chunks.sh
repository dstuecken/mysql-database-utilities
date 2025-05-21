#!/bin/bash
set -euo pipefail

# Default values
CHUNKS_DIR="./chunks"
OUTPUT_DIR="./chunks_nosuperprivs"
DRY_RUN=false
VERBOSE=false

# Display usage instructions
usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -p, --path DIRECTORY     Directory containing chunk files (default: ./chunks)"
  echo "  -o, --output DIRECTORY   Directory for processed files (default: ./chunks_nosuperprivs)"
  echo "  -d, --dry-run            Show what would be changed without actually writing files"
  echo "  -v, --verbose            Show detailed information about what is being processed"
  echo "  --help                   Display this help message"
  echo ""
  echo "Example: $0 --path /path/to/chunks --output /path/to/output --verbose"
  exit 1
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -p|--path) CHUNKS_DIR="$2"; shift ;;
    -o|--output) OUTPUT_DIR="$2"; shift ;;
    -d|--dry-run) DRY_RUN=true ;;
    -v|--verbose) VERBOSE=true ;;
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

# Create output directory if it doesn't exist
if [ "$DRY_RUN" = false ] && [ ! -d "$OUTPUT_DIR" ]; then
  echo "Creating output directory: $OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"
fi

# Find all chunk files and sort them
CHUNK_FILES=$(find "$CHUNKS_DIR" -name "chunk_*.sql" | sort)
TOTAL_CHUNKS=$(echo "$CHUNK_FILES" | wc -l)

if [ "$TOTAL_CHUNKS" -eq 0 ]; then
  echo "Error: No chunk files found in '$CHUNKS_DIR'"
  exit 1
fi

echo "Found $TOTAL_CHUNKS chunk files in $CHUNKS_DIR"

# Function to process a single chunk file
process_chunk() {
  local chunk_file="$1"
  local output_file="$2"
  local lines_removed=0
  local lines_total=0

  # Create a temporary file for processing
  local temp_file=$(mktemp)

  if [ "$VERBOSE" = true ]; then
    echo "Processing file: $chunk_file"
  fi

  # Process the file line by line to properly handle multi-line statements
  local in_super_statement=false
  local skip_reason=""

  while IFS= read -r line || [ -n "$line" ]; do
    lines_total=$((lines_total + 1))

    # Skip empty lines or comments but include them in output
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*-- ]]; then
      echo "$line" >> "$temp_file"
      continue
    fi

    # Check if this line starts a statement requiring SUPER privileges
    if [[ "$in_super_statement" = false ]]; then
      # Check for various types of statements requiring SUPER privileges
      if [[ "$line" =~ (SET[[:space:]]+GLOBAL|SET[[:space:]]+@@GLOBAL) ]]; then
        in_super_statement=true
        skip_reason="SET GLOBAL"
      elif [[ "$line" =~ ^[[:space:]]*(INSTALL|UNINSTALL)[[:space:]]+(PLUGIN|SONAME) ]]; then
        in_super_statement=true
        skip_reason="PLUGIN management"
      elif [[ "$line" =~ CREATE[[:space:]]+USER.+IDENTIFIED[[:space:]]+WITH[[:space:]]+'auth_socket' ]]; then
        in_super_statement=true
        skip_reason="CREATE USER with auth_socket"
      elif [[ "$line" =~ SET[[:space:]]+sql_log_bin[[:space:]]*=[[:space:]]*0 ]]; then
        in_super_statement=true
        skip_reason="SET sql_log_bin"
      fi
    fi

    # If we're in a statement that requires SUPER, skip it but add a comment
    if [ "$in_super_statement" = true ]; then
      if [ "$VERBOSE" = true ]; then
        echo "  - Removing line ($skip_reason): $line"
      fi

      # First line of SUPER statement - add a comment about the removal
      if [[ "$lines_removed" -eq 0 ]]; then
        echo "-- The following statement requiring SUPER privileges was removed:" >> "$temp_file"
        echo "-- $line" >> "$temp_file"
      fi

      lines_removed=$((lines_removed + 1))

      # Check if this line ends the statement
      if [[ "$line" =~ \;[[:space:]]*$ ]]; then
        in_super_statement=false
        echo "-- End of removed statement" >> "$temp_file"
      fi

      continue
    fi

    # This line doesn't require SUPER privileges, add it to the output
    echo "$line" >> "$temp_file"
  done < "$chunk_file"

  # If in dry run mode, just report what would happen
  if [ "$DRY_RUN" = true ]; then
    echo "Would write processed file to $output_file (removed $lines_removed of $lines_total lines)"
    rm "$temp_file"
  else
    # Move the temp file to the final destination
    mv "$temp_file" "$output_file"
    if [ "$VERBOSE" = true ]; then
      echo "Wrote processed file to $output_file (removed $lines_removed of $lines_total lines)"
    fi
  fi
}

# Process each chunk file
PROCESSED=0
for chunk_file in $CHUNK_FILES; do
  # Get the base filename without path
  base_file=$(basename "$chunk_file")
  # Create output path
  output_file="$OUTPUT_DIR/$base_file"

  # Process the chunk
  process_chunk "$chunk_file" "$output_file"

  PROCESSED=$((PROCESSED + 1))
  if [ "$VERBOSE" = false ] && [ "$((PROCESSED % 10))" -eq 0 ]; then
    echo "Processed $PROCESSED of $TOTAL_CHUNKS files..."
  fi
done

echo "Completed processing $PROCESSED chunk files"
if [ "$DRY_RUN" = true ]; then
  echo "This was a dry run - no files were actually modified"
else
  echo "Processed files are available in $OUTPUT_DIR"
fi

exit 0