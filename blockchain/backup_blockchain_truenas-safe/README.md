# Blockchain Backup Script for TrueNAS Scale

A robust, production-ready backup and restore script for blockchain data on TrueNAS Scale systems.

## Features

- 🚀 **Multi-chain support**: Bitcoin, Monero, Chia, Electrum
- 🔧 **TrueNAS integration**: Automatic service management via API
- 💾 **ZFS snapshots**: Data consistency with ZFS snapshot integration
- 🔒 **Safe operations**: Multiple safety checks to prevent data loss
- 📁 **Flexible storage**: Network shares and USB device support
- ⚙️ **Configurable**: External configuration file for easy customization
- 🧪 **Tested**: Comprehensive test suite included
- 📊 **Detailed logging**: Full operation logging with timestamps

## Quick Start

### Installation

```bash
# Deploy to /usr/local/bin (default)
./deploy_backup_blockchain.sh

# Deploy to custom directory
sudo ./deploy_backup_blockchain.sh /opt/backup

# Deploy with help
./deploy_backup_blockchain.sh --help
```

### Basic Usage

```bash
# Show help
backup_blockchain_truenas-safe.sh help

# Backup Bitcoin with verbose output
backup_blockchain_truenas-safe.sh btc verbose

# Backup Monero with specific height
backup_blockchain_truenas-safe.sh xmr 3000000

# Restore Bitcoin (force required)
backup_blockchain_truenas-safe.sh restore btc force

# Test script functionality
test_backup_blockchain.sh all
```

## Configuration

Edit `/usr/local/bin/backup_blockchain_truenas-safe.conf` after deployment:

Copy the example configuration and customize:

```bash
# Copy example to active config
sudo cp backup_blockchain_truenas-safe.conf.example backup_blockchain_truenas-safe.conf

# Edit for your environment
sudo nano backup_blockchain_truenas-safe.conf

# Important settings to customize:
# - NAS_USER: Your username for NAS access
# - NAS_HOST: Your NAS IP address
# - USB_DEVICE: Your USB device path
```

## Supported Services

| Blockchain    | Service | TrueNAS App Names | Data Paths |
|---------------|---------|-------------------|------------|
| Bitcoin (btc) | `bitcoind`| bitcoin, bitcoin-knots | `blocks/`, `chainstate/`, `indexes/` |
| Monero (xmr) | `monerod` | monero | `lmdb/` |
| Chia (xch) | `chia` | chia, chia-mainnet | `.chia/`, `.chia/keys/`, `plots/` |

## Safety Features

### Data Protection
- **Timestamp comparison**: Prevents overwriting newer backups
- **Force flag required**: Prevents accidental data loss
- **Service verification**: Ensures services are stopped before backup
- **Path validation**: Prevents operations on invalid paths

### Error Handling
- **Strict mode**: `set -euo pipefail` for early error detection
- **Input validation**: Height validation with service-specific rules
- **Comprehensive logging**: All operations logged with timestamps
- **Graceful degradation**: Falls back to manual intervention if API fails

### Operational Safety
- **Mount validation**: Checks storage accessibility before operations
- **PID file monitoring**: Verifies service shutdown
- **Ownership management**: Maintains proper file permissions
- **Rollback support**: Backups created before deployment

## Advanced Usage

### USB Backup
```bash
# Backup to USB device
backup_blockchain_truenas-safe.sh btc usb verbose

# Mount only USB for manual inspection
backup_blockchain_truenas-safe.sh mount usb
```

### Scheduled Backups (Cron)
```bash
# Edit crontab
crontab -e

# Daily Bitcoin backup at 2 AM
0 2 * * * /usr/local/bin/backup_blockchain_truenas-safe.sh btc verbose

# Weekly Monero backup on Sunday
0 3 * * 0 /usr/local/bin/backup_blockchain_truenas-safe.sh xmr verbose
```

### Manual Operations
```bash
# Mount network share
backup_blockchain_truenas-safe.sh mount

# Unmount when done
backup_blockchain_truenas-safe.sh umount

# Force backup (override newer destination)
backup_blockchain_truenas-safe.sh btc force

# Debug mode with shell tracing
backup_blockchain_truenas-safe.sh btc --debug
```

## Testing

### Run Test Suite
```bash
# Run all tests
./test_backup_blockchain.sh all

# Run specific test categories
./test_backup_blockchain.sh syntax      # Syntax validation
./test_backup_blockchain.sh functionality # Command tests
./test_backup_blockchain.sh validation   # Input validation
./test_backup_blockchain.sh config      # Configuration tests
```

### Test Categories
- **Basic tests**: File existence, permissions, syntax
- **Functionality tests**: Help, version, error handling
- **Validation tests**: Height format validation
- **Configuration tests**: Config loading and mappings
- **Integration tests**: Service detection, mount functionality

## File Structure

```
backup_blockchain_truenas-safe/
├── backup_blockchain_truenas-safe.sh    # Main script
├── backup_blockchain_truenas-safe.conf  # Configuration file
├── test_backup_blockchain.sh           # Test suite
├── deploy_backup_blockchain.sh         # Deployment script
└── README.md                           # This documentation
```

## Troubleshooting

### Common Issues

**Service not found via API:**
```bash
# Check available releases
midclt call chart.release.query

# Manually stop service
sudo k3s kubectl scale deployment <service-name> --replicas=0
```

**Mount permission denied:**
```bash
# Check network-share permissions
ls -la /mnt/cronas/blockchain/

# Test mount manually (using your actual credentials)
sudo mount -t cifs -o user=<your_user_here> //<NAS_IP>/blockchain /mnt/cronas/blockchain
```

**USB device not recognized:**
```bash
# List available USB devices
lsblk
ls -la /dev/sd*

# Create filesystem if needed
sudo mkfs.ext4 /dev/sdf1
```

### Debug Mode
```bash
# Enable debug output
backup_blockchain_truenas-safe.sh btc --debug

# Verbose mode for detailed information
backup_blockchain_truenas-safe.sh btc verbose --debug
```

### Log Analysis
```bash
# Check system logs
grep "backup_blockchain" /var/log/syslog

# Check TrueNAS logs
midclt call core.get_logs | grep -i backup
```

## Security Considerations

- **Security**: Store sensitive data in TrueNAS credential manager
- **Permissions**: Run with appropriate user privileges
- **Network**: Use encrypted SMB/NFS shares where possible
- **Access**: Limit script access to authorized users
- **Audit**: Enable logging and monitor backup operations

## Performance Optimization

### ZFS Settings
```bash
# Optimize for backup workloads
zfs set compression=lz4 tank/blockchain
zfs set recordsize=1M tank/blockchain
zfs set atime=off tank/blockchain
```

### Rsync Optimization
```bash
# Network optimization
RSYNC_CONFIGS[bitcoind]="-avihH -P --fsync --mkpath --stats --delete --bwlimit=10M"

# USB optimization
RSYNC_CONFIGS[usb_backup]="-avh -P --stats --delete --no-compress"
```

## Version Information

- **Script version**: 260210-safe
- **Compatible with**: TrueNAS Scale 22.12+
- **Test suite version**: 1.0
- **Deployment script**: 1.0

## Contributing

1. Fork the repository
2. Create feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit pull request

## License

Non-Commercial Use Only - see LICENSE file for details

## Support

For issues and questions:
1. Check the troubleshooting section
2. Run the test suite to identify problems
3. Check TrueNAS logs for API-related issues
4. Verify configuration settings

---

**⚠️ Important**: Always test backup procedures in a non-production environment first. Ensure you have recovery procedures in place before automated deployment.
