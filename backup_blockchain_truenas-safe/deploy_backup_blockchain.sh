#!/bin/bash
# ============================================================
 deploy_backup_blockchain.sh
# Deployment script for backup_blockchain_truenas-safe.sh
#
# Usage: ./deploy_backup_blockchain.sh [target_directory]
# Author: mratix
# ============================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default target directory
DEFAULT_TARGET="/usr/local/bin"
TARGET_DIR="${1:-$DEFAULT_TARGET}"
SCRIPT_NAME="backup_blockchain_truenas-safe.sh"
CONFIG_NAME="backup_blockchain_truenas-safe.conf"
TEST_NAME="test_backup_blockchain.sh"

# Source directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SOURCE_SCRIPT="$SCRIPT_DIR/$SCRIPT_NAME"
SOURCE_CONFIG="$SCRIPT_DIR/$CONFIG_NAME"
SOURCE_TEST="$SCRIPT_DIR/$TEST_NAME"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking deployment prerequisites..."
    
    # Check if source files exist
    if [[ ! -f "$SOURCE_SCRIPT" ]]; then
        log_error "Source script not found: $SOURCE_SCRIPT"
        exit 1
    fi
    
    if [[ ! -f "$SOURCE_CONFIG" ]]; then
        log_error "Source config not found: $SOURCE_CONFIG"
        exit 1
    fi
    
    # Check if source script is executable
    if [[ ! -x "$SOURCE_SCRIPT" ]]; then
        log_warning "Source script is not executable, fixing permissions..."
        chmod +x "$SOURCE_SCRIPT"
    fi
    
    # Check if target directory exists or can be created
    if [[ ! -d "$TARGET_DIR" ]]; then
        if mkdir -p "$TARGET_DIR" 2>/dev/null; then
            log_success "Created target directory: $TARGET_DIR"
        else
            log_error "Cannot create target directory: $TARGET_DIR"
            log_error "Try running with sudo or specify a different directory"
            exit 1
        fi
    fi
    
    # Check write permissions
    if [[ ! -w "$TARGET_DIR" ]]; then
        log_error "No write permission to target directory: $TARGET_DIR"
        log_error "Try running with sudo: sudo $0 $TARGET_DIR"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Backup existing files
backup_existing() {
    local backup_needed=false
    
    log_info "Checking for existing installations..."
    
    if [[ -f "$TARGET_DIR/$SCRIPT_NAME" ]]; then
        backup_needed=true
        local backup_file="$TARGET_DIR/$SCRIPT_NAME.backup.$(date +%Y%m%d%H%M%S)"
        cp "$TARGET_DIR/$SCRIPT_NAME" "$backup_file"
        log_success "Backed up existing script to: $backup_file"
    fi
    
    if [[ -f "$TARGET_DIR/$CONFIG_NAME" ]]; then
        backup_needed=true
        local backup_file="$TARGET_DIR/$CONFIG_NAME.backup.$(date +%Y%m%d%H%M%S)"
        cp "$TARGET_DIR/$CONFIG_NAME" "$backup_file"
        log_success "Backed up existing config to: $backup_file"
    fi
    
    if [[ "$backup_needed" == false ]]; then
        log_info "No existing files to backup"
    fi
}

# Deploy files
deploy_files() {
    log_info "Deploying files to $TARGET_DIR..."
    
    # Deploy main script
    cp "$SOURCE_SCRIPT" "$TARGET_DIR/"
    chmod 755 "$TARGET_DIR/$SCRIPT_NAME"
    log_success "Deployed: $TARGET_DIR/$SCRIPT_NAME"
    
    # Deploy config file
    cp "$SOURCE_CONFIG" "$TARGET_DIR/"
    chmod 644 "$TARGET_DIR/$CONFIG_NAME"
    log_success "Deployed: $TARGET_DIR/$CONFIG_NAME"
    
    # Deploy test script (optional)
    if [[ -f "$SOURCE_TEST" ]]; then
        cp "$SOURCE_TEST" "$TARGET_DIR/"
        chmod 755 "$TARGET_DIR/$TEST_NAME"
        log_success "Deployed: $TARGET_DIR/$TEST_NAME"
    fi
}

# Verify deployment
verify_deployment() {
    log_info "Verifying deployment..."
    
    local deployed_script="$TARGET_DIR/$SCRIPT_NAME"
    local deployed_config="$TARGET_DIR/$CONFIG_NAME"
    
    # Check script syntax
    if bash -n "$deployed_script"; then
        log_success "Script syntax is valid"
    else
        log_error "Script syntax check failed"
        return 1
    fi
    
    # Check config syntax
    if bash -n "$deployed_config"; then
        log_success "Config syntax is valid"
    else
        log_error "Config syntax check failed"
        return 1
    fi
    
    # Test script functionality
    if "$deployed_script" version >/dev/null 2>&1; then
        log_success "Script functionality test passed"
    else
        log_error "Script functionality test failed"
        return 1
    fi
    
    log_success "Deployment verification completed"
}

# Create symbolic links (optional)
create_symlinks() {
    log_info "Creating symbolic links..."
    
    local link_name="backup-blockchain"
    local target="$TARGET_DIR/$SCRIPT_NAME"
    local link_path="/usr/local/bin/$link_name"
    
    # Create shorter name symlink if in /usr/local/bin
    if [[ "$TARGET_DIR" == "/usr/local/bin" ]]; then
        if [[ -L "$link_path" ]]; then
            log_warning "Symlink already exists: $link_path"
            rm "$link_path"
        fi
        
        if ln -s "$target" "$link_path"; then
            log_success "Created symlink: $link_path -> $target"
        else
            log_warning "Failed to create symlink: $link_path"
        fi
    fi
}

# Set up cron examples
setup_cron_examples() {
    log_info "Creating cron example file..."
    
    local cron_example="$TARGET_DIR/cron_example_backup_blockchain.txt"
    
    cat > "$cron_example" << 'EOF'
# Blockchain Backup Cron Examples
# Add these lines to your crontab with: crontab -e

# Daily Bitcoin backup at 2 AM
0 2 * * * /usr/local/bin/backup_blockchain_truenas-safe.sh btc verbose

# Weekly Monero backup on Sunday at 3 AM
0 3 * * 0 /usr/local/bin/backup_blockchain_truenas-safe.sh xmr verbose

# Monthly Chia backup on 1st at 4 AM
0 4 1 * * /usr/local/bin/backup_blockchain_truenas-safe.sh xch verbose

# Bitcoin backup with USB fallback on weekdays
0 5 * * 1-5 /usr/local/bin/backup_blockchain_truenas-safe.sh btc usb verbose

# Example with custom height (use with caution)
# 0 6 * * * /usr/local/bin/backup_blockchain_truenas-safe.sh btc 800000 verbose

# Full backup of all services (if implemented)
# 0 7 * * 0 /usr/local/bin/backup_blockchain_truenas-safe.sh all verbose
EOF
    
    log_success "Created cron example: $cron_example"
}

# Display post-deployment information
display_info() {
    echo ""
    echo "========================================"
    echo "Deployment completed successfully!"
    echo "========================================"
    echo ""
    echo "Installed files:"
    echo "  Script:   $TARGET_DIR/$SCRIPT_NAME"
    echo "  Config:   $TARGET_DIR/$CONFIG_NAME"
    if [[ -f "$TARGET_DIR/$TEST_NAME" ]]; then
        echo "  Test:     $TARGET_DIR/$TEST_NAME"
    fi
    echo ""
    echo "Quick usage:"
    echo "  $TARGET_DIR/$SCRIPT_NAME help"
    echo "  $TARGET_DIR/$SCRIPT_NAME version"
    echo "  $TARGET_DIR/$SCRIPT_NAME btc 800000"
    echo ""
    if [[ -f "$TARGET_DIR/cron_example_backup_blockchain.txt" ]]; then
        echo "Cron examples available at:"
        echo "  $TARGET_DIR/cron_example_backup_blockchain.txt"
        echo ""
    fi
    echo "Configuration:"
    echo "  Edit: $TARGET_DIR/$CONFIG_NAME"
    echo "  Review: network settings, USB device, service mappings"
    echo ""
    echo "Testing:"
    echo "  Run: $TARGET_DIR/$TEST_NAME all"
    echo ""
    echo "Important notes:"
    echo "  1. Review and update $TARGET_DIR/$CONFIG_NAME for your environment"
    echo "  2. Ensure TrueNAS API access is configured for automatic service management"
    echo "  3. Test with verbose flag first: $TARGET_DIR/$SCRIPT_NAME btc verbose"
    echo "  4. Verify mount points and permissions before production use"
    echo ""
}

# Main deployment function
main() {
    echo "========================================"
    echo "Blockchain Backup Script Deployment"
    echo "========================================"
    echo "Target directory: $TARGET_DIR"
    echo ""
    
    check_prerequisites
    backup_existing
    deploy_files
    verify_deployment
    create_symlinks
    setup_cron_examples
    display_info
    
    log_success "Deployment completed successfully!"
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [target_directory]"
        echo ""
        echo "Deploy the blockchain backup script to the specified directory."
        echo "Default target: /usr/local/bin"
        echo ""
        echo "Examples:"
        echo "  $0                    # Deploy to /usr/local/bin"
        echo "  $0 /opt/backup       # Deploy to /opt/backup"
        echo "  sudo $0 /usr/local/bin # Deploy with sudo privileges"
        echo ""
        exit 0
        ;;
    --version|-v)
        echo "Blockchain Backup Deployment Script v1.0"
        echo "Compatible with backup_blockchain_truenas-safe.sh v260210-safe"
        exit 0
        ;;
esac

# Run main function
main "$@"