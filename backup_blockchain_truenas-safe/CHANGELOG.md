# Changelog - backup_blockchain_truenas-safe.sh

All notable changes to the backup_blockchain_truenas-safe.sh script and related files will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2026-02-13] - Refactoring Release

### Fixed
- **vlog() with set -e**: Added `|| true` to prevent script exit when VERBOSE=false
- **Double execution**: Removed duplicate code block that caused script to run twice
- **RSYNC_OPTS verbose handling**: When VERBOSE=false, removes `--stats`, `--info=progress2`, `-P` from rsync options for cleaner output
- **Snapshot creation**: Added `|| true` to ignore "dataset already exists" errors
- **postbackup**: Removed TrueNAS API restart logic for safe version (manual start/stop)

### Refactored
- **Variable Naming**: All global variables now UPPERCASE (e.g., `NASMOUNT`, `SERVICE`, `POOL`, `DATASET`, `SRCDIR`, `DESTDIR`, `HEIGHT`, `RESTORE`, `FORCE`, `VERBOSE`, `USE_USB`, `IS_ZFS`, `IS_MOUNTED`, `USBDEV`, `RSYNC_OPTS`)
- **Local variables**: remain lowercase for distinction
- **ZFS Configuration**: Uses `ZFS_POOL` and `ZFS_DATASET` from config (required)
- **Service Mapping**: Removed `SERVICE_CONFIGS` (moved to gold/enterprise version)
- **Logging**: Unified logging functions: `show()`, `log()`, `vlog()`, `warn()`, `error()`
- **Argument Parsing**: Fixed syntax errors, simplified execution flow
- **Config**: Added `ZFS_POOL` and `ZFS_DATASET` to safe.conf.example

### Fixed
- Config key parsing: `service:is_zfs:pool` now correctly reads 3 values
- Missing `ZFS_POOL` now shows clear error message

## [2026-02-12] - Production Release

### Added
- **Security Enhancements**
  - Network connectivity validation before mounting NAS shares
  - USB device existence and mounting validation
  - Mount integrity verification with read/write tests
  - Comprehensive path sanitization using `realpath`
  - Dangerous path detection and prevention system
  - Input validation for all user-provided paths
  - Automatic cleanup on mount failures
  - Read-only mount options for network shares

- **Code Structure Improvements**
  - Robust `getopts`-based argument parsing system
  - Standardized logging with consistent timestamp format (`YYYY-MM-DD HH:MM:SS`)
  - External configuration file (`backup_blockchain_truenas-safe.conf`)
  - Centralized service configuration mappings
  - Configuration fallback system for missing config files
  - Comprehensive usage documentation with examples
  - Function definitions organized before usage

- **Configuration Management**
  - External configuration file separating hardcoded values
  - Service-specific rsync options and configurations
  - Centralized security settings and timeout values
  - Backup retention and integrity check settings
  - File extension monitoring for security

### Fixed
- **Critical Issues**
  - Initialized undefined argument variables (`arg1`, `arg2`, `arg3`, `arg4`) before use
  - Added missing variable initialization for `verbose`
  - Fixed undefined `srcsynctime` and `destsynctime` variables in backup function
  - Added proper file time calculation before backup comparisons
  - Fixed undefined variable usage in machine-dependent configuration checks

### Changed
- **Argument Parsing**
  - Replaced fragile positional argument parsing with enhanced argument handling
  - Added support for both short and long options:
    - `--height, -bh N` for blockchain height
    - `--help, -h` for help documentation
    - `--force, -f` for force operations
    - `--service, -s S` for service selection
    - `--verbose, -v` for verbose output

    - `--restore, -r` for restore mode
    - `--usb` for USB device usage
  - Implemented numeric validation for blockchain height parameter
  - Maintained backward compatibility with existing usage patterns
  - Added comprehensive help system with examples

- **Logging System**
  - Standardized timestamp format: `YYYY-MM-DD HH:MM:SS [LEVEL] message`
  - Implemented proper log levels: DEBUG, VERBOSE, INFO, WARN, ERROR
  - Redirected error output to stderr for proper stream handling
  - Added log level filtering with verbose mode control
  - Maintained backward compatibility with existing `log()` function

- **Error Handling**
  - Consistent error message format and logging
  - Better error recovery with automatic cleanup
  - More descriptive error messages with specific failure reasons
  - Proper exit codes for different error conditions
  - Network timeout handling for NAS connectivity

### Security
- **Mount Security**
  - Network reachability verification before NAS mounting
  - USB device validation and conflict detection
  - Mount point integrity testing with read/write verification
  - Read-only mount options for network shares when appropriate
  - Proper mount failure cleanup and error reporting

- **Path Security**
  - Absolute path conversion and normalization
  - Directory restriction enforcement (/mnt/, /home/, /var/ only)
  - Dangerous path blocking (/bin, /sbin, /usr, /etc, /boot, /sys, /proc, /dev, /media)
  - Input sanitization for all user-provided paths
  - Prevention of directory traversal attacks

- **Runtime Security**
  - Executable file detection in restore sources
  - User warnings for suspicious operations
  - Improved validation of service configurations
  - Safe temporary file creation for integrity testing

### Refactored
- **Code Organization**
  - Reduced global variable dependencies
  - Improved function modularity and reusability
  - Better separation of concerns between security, mounting, and backup logic
  - Consistent code style and formatting
  - Function definitions organized before usage

- **Configuration Architecture**
  - Externalized all hardcoded values to configuration file
  - Created service configuration mappings for easier maintenance
  - Centralized timeout and security settings
  - Implemented configuration loading with fallback mechanism
  - Added configuration validation and error handling

## [Previous] - Initial Version

### Added
- **Core Functionality**
  - Multi-host service detection (deop9020m, hpms1)
  - Support for Bitcoin (bitcoind), Monero (monerod), and Chia (chia) blockchains
  - Network (CIFS/SMB) and USB backup destinations
  - ZFS snapshot integration with automatic naming
  - Service-specific rsync configurations and optimizations

- **Backup Features**
  - Blockchain height tracking and file rotation
  - Automatic backup comparison based on file modification times
  - Prevents overwriting newer backups without force flag
  - Service stop verification before backup operations
  - Comprehensive logging with timestamps

- **Configuration System**
  - Host-specific service and pool configurations
  - Flexible mount point and destination handling
  - Backup and restore mode support
  - Force and verbose operation modes

---

## Version Information

### Current Version
- **backup_blockchain_truenas-safe.sh**: `260211-safe`

### Related Files
- `backup_blockchain_truenas-safe.conf` - External configuration file
- `CHANGELOG.md` - This changelog file

### File Statistics
- Script: 442 lines (before improvements)
- Configuration: 70+ lines with comprehensive settings
- Changelog: Detailed change documentation

### Testing Status
- ✅ Syntax validation passed
- ✅ Configuration file validation passed
- ✅ Backward compatibility maintained
- ✅ Security features tested
- ✅ Error handling verified
- ✅ Mount integrity verification tested

---

## Migration Guide

### For Users

#### Existing Usage (Still Supported)
```bash
./backup_blockchain_truenas-safe.sh btc 800000 force
./backup_blockchain_truenas-safe.sh xmr verbose
```

#### New Enhanced Usage
```bash
# New getopts-based usage
./backup_blockchain_truenas-safe.sh -f btc -h 800000 --force
./backup_blockchain_truenas-safe.sh -f xmr --verbose --usb

# Show help
./backup_blockchain_truenas-safe.sh -h

# Restore operations (requires --force)
./backup_blockchain_truenas-safe.sh -f btc -r --force
```

#### Configuration
- Ensure `backup_blockchain_truenas-safe.conf` is in the same directory as the script
- Modify the config file for your environment (NAS settings, paths, etc.)
- The script will fall back to internal defaults if config file is missing

### For System Administrators

#### Configuration Management
- Use `backup_blockchain_truenas-safe.conf` for environment-specific settings
- Share configuration across multiple deployment environments
- Version control the configuration file for change tracking

#### Monitoring and Logging
- Enhanced logging format for better log parsing and monitoring
- Structured error messages for automated alerting
- Consistent timestamps for log analysis tools

---

## Security Notes

### Mount Security
- All mount points are validated before use
- Network connectivity is verified before NAS operations
- USB devices are checked for conflicts and proper mounting
- Automatic cleanup occurs on mount failures

### Path Security
- All user inputs are sanitized and validated as absolute paths
- Dangerous system paths are automatically rejected
- Directory traversal attacks are prevented
- Only allowed directories (/mnt/, /home/, /var/) are accepted

### Runtime Security
- Network operations have timeout protection
- File operations include integrity verification
- Executable files in restore sources trigger security warnings
- Configuration files are validated before loading

---

## Performance Improvements

### Argument Processing
- Faster argument parsing with `getopts` vs manual parsing
- Reduced overhead from better variable initialization
- Early argument validation prevents unnecessary operations

### Mount Operations
- Network connectivity checks prevent hanging mount attempts
- Integrity verification ensures reliable backup destinations
- Proper timeout handling prevents indefinite blocking

### Configuration Loading
- Optimized configuration parsing and validation
- Fallback mechanism ensures script always runs
- Centralized settings reduce code duplication

---

## Future Development

### Planned Features
- [ ] Automated backup scheduling integration
- [ ] Backup verification with checksum validation
- [ ] Multi-destination simultaneous backup
- [ ] Web-based configuration interface
- [ ] Integration with monitoring systems
- [ ] Backup compression and encryption options

### API Stability
- External configuration interface is stable
- Command-line arguments are backward compatible
- Log format is consistent for tooling integration
- Exit codes are standardized for automation