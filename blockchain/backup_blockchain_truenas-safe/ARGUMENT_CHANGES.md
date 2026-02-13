# Argument Usage Changes Summary

## ✅ Updated Argument Structure

### New Arguments (as requested)
| Option | Short | Long | Description | Example |
|--------|--------|-------|-------------|---------|
| Height | `-bh` | `--height` | Blockchain height (numeric) | `--height 800000` |
| Help | `-h` | `--help` | Show help message | `--help` |
| Force | `-f` | `--force` | Force restore operation | `--force` |
| Service | `-s` | `--service` | Service type | `--service btc` |

### Previous Arguments → New Arguments
| Old | New | Description |
|-----|-----|-------------|
| `-h` | `-bh` or `--height` | Height parameter |
| `-f` | `-s` or `--service` | Service parameter |
| `-h` | `-h` or `--help` | Help (redefined) |
| `-f` | `-f` or `--force` | Force (redefined) |

### Usage Examples

#### New Recommended Usage
```bash
# Using long options (recommended)
./backup_blockchain_truenas-safe.sh --service btc --height 800000 --force

# Using short options
./backup_blockchain_truenas-safe.sh -s btc -bh 800000 -f

# Mixed usage
./backup_blockchain_truenas-safe.sh --service xmr -bh 750000 --verbose

# Restore (force required)
./backup_blockchain_truenas-safe.sh --restore --force
```

#### Backward Compatible Usage (Still Supported)
```bash
# Old style still works
./backup_blockchain_truenas-safe.sh btc 800000 force
./backup_blockchain_truenas-safe.sh xmr 750000 verbose
```

### Help System
```bash
./backup_blockchain_truenas-safe.sh --help
./backup_blockchain_truenas-safe.sh -h
```

### Validation Features
- ✅ Height must be numeric
- ✅ Service must be valid (btc, xmr, xch)
- ✅ Proper error messages for invalid arguments
- ✅ Backward compatibility maintained
- ✅ Comprehensive help documentation

### Migration Guide
1. **Immediate**: Old syntax still works
2. **Recommended**: Use new argument format for clarity
3. **Scripts**: Update automation scripts to use new long options
4. **Documentation**: Update any existing documentation

The changes improve clarity while maintaining full backward compatibility.