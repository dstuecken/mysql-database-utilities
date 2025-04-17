# MySQL Database Utilities

A collection of bash scripts for efficiently exporting, chunking, and importing MySQL databases, especially useful for handling large databases where standard imports and exports might fail.

## Overview
This toolkit provides three main utilities:
1. **export-database.sh** - Export MySQL databases with optimized settings
2. **chunk-large-export.sh** - Split large SQL dump files into manageable chunks
3. **import-chunks.sh** - Import chunked SQL files with memory-efficient settings

These scripts are particularly valuable when working with large databases that may cause memory issues or timeouts during standard import/export operations.
## Installation
``` bash
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
``` bash
./export-database.sh -u username -w password -d database1,database2 -f export_file.sql
```
#### Options:
- `-u, --user USERNAME` - Database username (default: root)
- `-w, --password PASS` - Database password
- `-h, --host HOST` - Database host (default: local socket)
- `-d, --databases DB[,DB]` - Databases to export (comma-separated, required)
- `-f, --file FILENAME` - Output file name (default: database_export.sql)
- `-o, --output DIR` - Output directory (default: ./exports)
- `-z, --compress` - Compress output file with gzip
- `-m, --max-packet SIZE` - Max allowed packet size (default: 1G)
- `-n, --net-buffer SIZE` - Network buffer length (default: 16384)
- `-t, --lock-tables` - Lock all tables during export (default: false)
- `-s, --skip-transaction` - Skip using single transaction (default: use transaction)
- `-x, --exclude TABLES` - Tables to exclude (comma-separated, format: db.table)

#### Example:
``` bash
# Export a production database with compression
./export-database.sh -u dbadmin -w secure123 -h db.example.com -d production_db -z -f prod_backup.sql
```
### Chunk Large Export
The `chunk-large-export.sh` script splits a large SQL dump file into smaller manageable chunks to facilitate easier importing, especially for very large databases.
``` bash
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
``` bash
# Split a 10GB dump file into chunks of 500 INSERT statements
./chunk-large-export.sh -i huge_database_dump.sql -c 500 -o ./database_chunks
```
### Import Chunks
The `import-chunks.sh` script imports chunked SQL files with optimized memory settings, allowing for successful imports of large databases that might otherwise fail.
``` bash
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
- `-s, --sleep SECONDS` - Sleep time between chunks in seconds (default: 3)

#### Example:
``` bash
# Import chunks 5 through 20 into a specific database
./import-chunks.sh -f 5 -t 20 -u dbadmin -w secure123 -n restored_database -p ./database_chunks
```
## Common Workflows
### Full Database Migration
``` bash
# 1. Export the source database
./export-database.sh -u source_user -w source_pass -h source_host -d source_db -f full_export.sql

# 2. Split the export into manageable chunks
./chunk-large-export.sh -i full_export.sql -c 300 -o ./migration_chunks

# 3. Import the chunks into the destination database
./import-chunks.sh -u dest_user -w dest_pass -h dest_host -n dest_db -p ./migration_chunks
```
### Partial Import with REPLACE
Sometimes you need to update specific data without affecting the entire database:
``` bash
# 1. Export only the needed tables
./export-database.sh -u admin -w pass123 -d mydb -f updated_tables.sql -x mydb.logs,mydb.sessions

# 2. Chunk the export and convert INSERTs to REPLACEs
./chunk-large-export.sh -i updated_tables.sql -r -o ./update_chunks

# 3. Import only the updated data
./import-chunks.sh -u admin -w pass123 -n mydb -p ./update_chunks
```
## When to Use These Scripts
- **Large Databases**: When standard mysqldump/mysql imports fail due to size or timeout issues
- **Memory Limitations**: When dealing with servers that have memory constraints
- **Production Migrations**: For safer, more controlled database migrations with the ability to pause/resume
- **Selective Updates**: When you need to selectively update portions of a database
- **Cross-Server Migrations**: When moving data between database servers with different configurations

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
## Contributing
Contributions are welcome! Please feel free to submit a Pull Request.
