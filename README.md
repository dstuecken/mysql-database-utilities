# MySQL Database Utilities

A collection of bash scripts for efficiently exporting, chunking, and importing MySQL databases, especially useful for handling large databases where standard imports and exports might fail.

## Overview
This toolkit provides three main utilities:
1. **export-database.sh** - Export MySQL databases with optimized settings, now with additional MySQL configuration options
2. **chunk-large-export.sh** - Split large SQL dump files into manageable chunks
3. **import-chunks.sh** - Import chunked SQL files with memory-efficient settings.
4. **remove-super-statements-from-chunks.sh** - Process SQL chunk files to remove statements requiring SUPER privileges

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
The `export-database.sh` script allows you to export one or more MySQL databases with optimized settings for performance and reliability.

```bash
./export-database.sh -u username -w password -d database1,database2 -f export_file.sql
```

#### Options:
- `-u, --user USERNAME` - Database username (default: root)
- `-w, --password PASS` - Database password (default: empty)
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
- `-q, --quiet` - Disable progress reporting
- `--skip-add-locks` - Skip adding locks in SQL output
- `--no-create-info` - Skip table creation information
- `--skip-lock-tables` - Skip locking tables during export (use if you get error: 1109)
- `--no-tablespaces` - Skip tablespace information
- `--column-statistics=0` - Disable column statistics (helps with MySQL 8+ exports)
- `--skip-triggers` - Exclude triggers from the export
- `--no-data` - Export only structure, no data
- `--routines` - Include stored routines (procedures and functions)
- `--events` - Include events
- `--help` - Display help message

#### Examples:
```bash
# Export a production database with compression
./export-database.sh -u dbadmin -w secure123 -h db.example.com -d production_db -z -f prod_backup.sql

# Export multiple databases excluding certain tables
./export-database.sh -u dbadmin -w secure123 -d db1,db2 -x "db1.logs,db2.temp_data"

# Export database without locks for read-only databases
./export-database.sh -u dbadmin -w secure123 -d readonly_db --skip-add-locks --skip-lock-tables

# Export only structure (no data) including stored routines
./export-database.sh -u dbadmin -w secure123 -d database --no-data --routines
```

### Import Database
The `import-database.sh` script allows you to import a single SQL file into a MySQL database with optimized settings for performance and reliability.

```bash
./import-database.sh -u username -w password -n database_name -i import_file.sql
```

#### Options:
- `-u, --user USERNAME` - Database username (default: root)
- `-w, --password PASS` - Database password (default: empty)
- `-h, --host HOST` - Database host (default: local socket)
- `-n, --database NAME` - Database to import into (required)
- `-i, --input FILE` - SQL file to import (required)
- `-m, --max-packet SIZE` - Max allowed packet size (default: 1G)
- `-b, --net-buffer SIZE` - Network buffer length (default: 16384)
- `-k, --keep-keys` - Don't disable keys during import (default: disable)
- `-f, --force` - Force import even if database exists (default: false)
- `-q, --quiet` - Disable progress reporting
- `--help` - Display help message

#### Examples:
```bash
# Import a SQL file into a new database
./import-database.sh -u dbadmin -w secure123 -n new_database -i backup.sql

# Import a compressed SQL file with increased packet size
./import-database.sh -u dbadmin -w secure123 -n database -i backup.sql.gz -m 2G

# Force import into an existing database
./import-database.sh -u dbadmin -w secure123 -n existing_db -i backup.sql -f

# Import to a remote database server
./import-database.sh -u dbadmin -w secure123 -h db.example.com -n database -i backup.sql
```

### Chunk Large Export
The `chunk-large-export.sh` script splits a large SQL dump file into smaller manageable chunks to facilitate easier importing, especially for very large databases. It can also now extract CREATE TABLE statements to a separate structure file.

```bash
./chunk-large-export.sh -i large_dump.sql -c 500 -o ./chunks -s structure.sql
```

#### Options:
- `-r, --replace-into` - Convert INSERT INTO statements to REPLACE INTO
- `-c, --chunk-size SIZE` - Number of INSERT statements per chunk (default: 200)
- `-i, --input FILE` - Input SQL file to process (default: dump.sql)
- `-o, --output DIR` - Output directory for chunks (default: ./chunks)
- `-s, --structure FILE` - Extract CREATE TABLE statements to specified file
- `-d, --debug` - Enable debug mode with verbose output
- `--help` - Display help message

#### Examples:
```bash
# Split a 10GB dump file into chunks of 500 INSERT statements with debug mode
./chunk-large-export.sh -i huge_database_dump.sql -c 500 -o ./database_chunks -d

# Split a dump file and extract table structure to a separate file
./chunk-large-export.sh -i database_dump.sql -o ./chunks -s ./structure.sql

# Extract only structure without chunking (set very large chunk size)
./chunk-large-export.sh -i database_dump.sql -c 9999999 -s ./structure_only.sql
```

### Import Chunks
The `import-chunks.sh` script allows you to import chunked SQL files with memory-efficient settings, providing control over the import process.

```bash
./import-chunks.sh -n database_name -u username -w password
```

#### Options:
- `-f, --from NUMBER` - Start importing from chunk number (default: 1)
- `-t, --to NUMBER` - Stop importing at chunk number (default: all chunks)
- `-d, --dry-run` - Show what would be imported without actually importing
- `-p, --path DIRECTORY` - Directory containing chunk files (default: ./chunks)
- `-u, --user USERNAME` - Database username (default: root)
- `-w, --password PASS` - Database password
- `-n, --database NAME` - Database name
- `-h, --host HOST` - Database host (default: local socket)
- `-m, --max-packet SIZE` - Max allowed packet size in bytes (default: 2147483648)
- `-s, --sleep SECONDS` - Sleep time between chunks in seconds (default: 3)
- `--help` - Display help message

#### Examples:
```bash
# Import all chunks with dry run
./import-chunks.sh -u dbadmin -w secret -n mydb -d

# Import specific range of chunks
./import-chunks.sh -f 3 -t 7 -u dbadmin -w secret -n mydb -h dbserver

# Import with custom max packet size and sleep time
./import-chunks.sh -u dbadmin -w secret -n mydb -m 2147483648 -s 5
```

### Remove SUPER Privilege Statements from Chunks
The `remove-super-statements-from-chunks.sh` script processes SQL chunks to remove statements that require SUPER privileges, which often cause import failures on shared hosting environments.
``` bash
./remove-super-statements-from-chunks.sh --path ./chunks --output ./filtered_chunks
```
#### Options:
- `-p, --path DIRECTORY` - Directory containing chunk files (default: ./chunks)
- `-o, --output DIRECTORY` - Directory for processed files (default: ./chunks_nosuperprivs)
- `-d, --dry-run` - Show what would be changed without actually writing files
- `-v, --verbose` - Show detailed information about what is being processed
- `--help` - Display help message

#### What This Script Does:
This script addresses a common issue where SQL import processes fail with errors like:
``` 
ERROR 1227 (42000) at line XX: Access denied; you need (at least one of) the SUPER privilege(s) for this operation
```
It identifies and removes statements requiring SUPER privileges, including:
- `SET GLOBAL` statements
- `SET @@GLOBAL` variable assignments
- Plugin installation/uninstallation statements
- User creation with special authentication methods

The script preserves your original SQL chunk files by creating modified copies in the output directory, replacing removed statements with comments so you can see what was removed.
#### Example Workflow:
1. First remove SUPER privilege statements:
``` bash
   ./remove-super-statements-from-chunks.sh --path ./chunks --output ./filtered_chunks
```
1. Then import the filtered chunks:
``` bash
   ./import-chunks.sh --path ./filtered_chunks --database mydb --user dbuser --password dbpass
```

## Advanced Usage
For very large databases, you can use these tools in combination. First export the database, then chunk it if needed, and finally import the chunks with memory-optimized settings.

## Requirements
- Bash shell environment
- MySQL/MariaDB client tools installed
- Sufficient permissions on the MySQL server
- Read/write access to the filesystem for the scripts


## Troubleshooting
- If you encounter "Lock wait timeout" errors during export, try using `--skip-lock-tables`
- For "Out of memory" errors during import, reduce chunk size and increase sleep time between chunks
- When dealing with InnoDB tables, using the default transaction mode is recommended for data consistency
