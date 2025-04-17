# MySQL Database Utilities

A collection of bash scripts for efficiently exporting, chunking, and importing MySQL databases, especially useful for handling large databases where standard imports and exports might fail.

## Overview
This toolkit provides three main utilities:
1. **export-database.sh** - Export MySQL databases with optimized settings, now with built-in chunking capability
2. **chunk-large-export.sh** - Split large SQL dump files into manageable chunks
3. **import-chunks.sh** - Import chunked SQL files with memory-efficient settings

These scripts are particularly valuable when working with large databases that may cause memory issues or timeouts during standard import/export operations.

## Installation
```bash
# Clone the repository
git clone https://github.com/dstuecken/mysql-database-utilities.git
cd mysql-database-utilities

# Make scripts executable
chmod +x export-database.sh
chmod +x chunk-large-export.sh
chmod +x import-chunks.sh
```

## Usage
### Export Database
The `export-database.sh` script allows you to export one or more MySQL databases with optimized settings for performance and reliability. The script now supports direct chunking of the export, eliminating the need for a separate chunking step in many workflows.

```bash
# Export to a single file
./export-database.sh -u username -w password -d database1,database2 -f export_file.sql --no-chunk

# Export with automatic chunking (new feature)
./export-database.sh -u username -w password -d database1,database2 -f export_file.sql -c 500
```

#### Options:
- `-u, --user USERNAME` - Database username (default: root)
- `-w, --password PASS` - Database password
- `-h, --host HOST` - Database host (default: local socket)
- `-d, --databases DB[,DB]` - Databases to export (comma-separated, required)
- `-f, --file FILENAME` - Output file name (default: database_export.sql)
- `-o, --output DIR` - Output directory (default: ./exports)
- `-z, --compress` - Compress output file(s) with gzip
- `-m, --max-packet SIZE` - Max allowed packet size (default: 1G)
- `-n, --net-buffer SIZE` - Network buffer length (default: 16384)
- `-t, --lock-tables` - Lock all tables during export (default: false)
- `-s, --skip-transaction` - Skip using single transaction (default: use transaction)
- `-x, --exclude TABLES` - Tables to exclude (comma-separated, format: db.table)
- `-c, --chunk-size SIZE` - Number of INSERT statements per chunk (default: 500)
- `--no-chunk` - Disable chunking and export to a single file

#### Examples:
```bash
# Export a production database with compression (single file)
./export-database.sh -u dbadmin -w secure123 -h db.example.com -d production_db -z -f prod_backup.sql --no-chunk

# Export a production database with automatic chunking (500 inserts per chunk)
./export-database.sh -u dbadmin -w secure123 -h db.example.com -d production_db -z -f prod_backup.sql -c 500

# Export multiple databases with custom chunk size
./export-database.sh -u dbadmin -w secure123 -d db1,db2,db3 -c 1000 -o ./multi_db_export
```

### Chunk Large Export
The `chunk-large-export.sh` script splits a large SQL dump file into smaller manageable chunks to facilitate easier importing, especially for very large databases.

```bash
./chunk-large-export.sh -i large_dump.sql -c 500 -o ./chunks
```

#### Options:
- `-r, --replace-into` - Convert INSERT INTO statements to REPLACE INTO
- `-u, --user USERNAME` - Database username (default: root)
- `-w, --password PASS` - Database password
- `-n, --database NAME` - Database name
- `-h, --host HOST` - Database host (default: local socket)
- `-c, --chunk-size SIZE` - Number of INSERT statements per chunk (default: 200)
- `-i, --input FILE` - Input SQL file to process (default: dump.sql)
- `-o, --output DIR` - Output directory for chunks (default: ./chunks)

#### Example:
```bash
# Split a 10GB dump file into chunks of 500 INSERT statements
./chunk-large-export.sh -i huge_database_dump.sql -c 500 -o ./database_chunks
```

### Import Chunks
The `import-chunks.sh` script imports chunked SQL files with optimized memory settings, allowing for successful imports of large databases that might otherwise fail.

```bash
./import-chunks.sh -u username -w password -n database_name -p ./chunks
```

#### Options:
- `-f, --from NUMBER` - Start importing from chunk number (default: 1)
- `-t, --to NUMBER` - Stop importing at chunk number (default: all chunks)
- `-d, --dry-run` - Show what would be imported without actually importing
- `-p, --path DIRECTORY` - Directory containing chunk files (default: ./import_chunks)
- `-u, --user USERNAME` - Database username (default: root)
- `-w, --password PASS` - Database password
- `-n, --database NAME` - Database name
- `-h, --host HOST` - Database host (default: local socket)
- `-m, --max-packet SIZE` - Max allowed packet size in bytes (default: 1073741824)

## Workflow Examples

### Complete export-to-import workflow with built-in chunking:
```bash
# Export a database directly to chunks
./export-database.sh -u dbuser -w dbpass -d large_database -c 500 -f large_db_export

# Import the chunks
./import-chunks.sh -u dbuser -w dbpass -n new_database -p ./exports/large_db_export_chunks
```

### Using separate chunking for existing dumps:
```bash
# Export a database to a single file
./export-database.sh -u dbuser -w dbpass -d large_database -f large_dump.sql --no-chunk

# Chunk the dump file
./chunk-large-export.sh -i ./exports/large_dump.sql -c 500 -o ./chunked_dump

# Import the chunks
./import-chunks.sh -u dbuser -w dbpass -n new_database -p ./chunked_dump
```