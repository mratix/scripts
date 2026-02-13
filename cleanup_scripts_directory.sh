#!/bin/bash
# ============================================================
# cleanup_scripts_directory.sh
# Cleanup utility for scripts workspace
# ============================================================

SCRIPTS_DIR="/home/mratix/workspaces/scripts"
CLEANUP_LOG="/tmp/cleanup_log_$(date +%Y%m%d_%H%M%S).txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_message() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [CLEANUP] $*" | tee -a "$CLEANUP_LOG"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$CLEANUP_LOG"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$CLEANUP_LOG"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$CLEANUP_LOG"
}

# Analysis Functions
analyze_garbage_files() {
    log_info "Analyzing garbage files in $SCRIPTS_DIR..."
    echo ""
    
    cd "$SCRIPTS_DIR"
    
    # 1. Loose configuration files
    log_info "=== Loose Configuration Files ==="
    find . -maxdepth 1 -type f -name "*.conf" ! -path "./backup_blockchain_truenas-safe/*" | sort
    echo ""
    
    # 2. Duplicate documentation files
    log_info "=== Duplicate Documentation ==="
    find . -maxdepth 1 -type f -name "*.md" ! -path "./.git/*" | sort
    echo ""
    
    # 3. Loose argument/temp files
    log_info "=== Loose Argument Files ==="
    find . -maxdepth 1 -type f \( -name "*ARGUMENT*" -o -name "*FINAL*" -o -name "*SUMMARY*" \) ! -path "./.git/*" | sort
    echo ""
    
    # 4. Temporary/test files
    log_info "=== Temporary and Test Files ==="
    find . -maxdepth 1 -type f \( -name "test_*.sh" -o -name "*test*.log" -o -name "*.broken" -o -name "*.backup" \) ! -path "./.git/*" | sort
    echo ""
}

# Cleanup Functions
cleanup_safe_files() {
    log_info "Cleaning up SAFE duplicate files..."
    
    # 1. Remove duplicate .conf file from root
    if [[ -f "backup_blockchain_truenas-safe.conf" ]]; then
        log_warn "Found duplicate config in root, keeping safe version"
        rm -f "backup_blockchain_truenas-safe.conf"
    fi
    
    # 2. Remove broken/backup files
    find . -maxdepth 1 -type f \( -name "*.broken" -o -name "*.backup" \) -exec rm -f {} \; 2>/dev/null
    log_info "Removed broken and backup files"
}

cleanup_duplicate_docs() {
    log_info "Cleaning up duplicate documentation files..."
    
    # Keep only the main README.md
    find . -maxdepth 1 -type f -name "README.md" -exec rm -f {} \; 2>/dev/null
    
    # Remove duplicated summary files from root
    find . -maxdepth 1 -type f \( -name "*ARGUMENT*" -o -name "*FINAL*" -o -name "*SUMMARY*" \) -exec rm -f {} \; 2>/dev/null
    log_info "Removed duplicate documentation files"
}

cleanup_temp_files() {
    log_info "Cleaning up temporary and test files..."
    
    # Remove test scripts
    find . -maxdepth 1 -type f -name "test_*.sh" -exec rm -f {} \; 2>/dev/null
    
    # Remove test logs
    find . -maxdepth 1 -type f -name "*test*.log" -exec rm -f {} \; 2>/dev/null
    
    # Remove other temporary files
    find . -maxdepth 1 -type f -name "parse.sh" -exec rm -f {} \; 2>/dev/null
    
    log_info "Removed temporary and test files"
}

cleanup_development_files() {
    log_info "Cleaning up development artifacts..."
    
    # Remove dev-only files
    find . -maxdepth 1 -type f -name "PRUNE_REMOVED.md" -exec rm -f {} \; 2>/dev/null
    find . -maxdepth 1 -type f -name "BLOCKCHAIN_ARGUMENTS_FINAL.md" -exec rm -f {} \; 2>/dev/null
    
    log_info "Removed development-only files"
}

organize_project_structure() {
    log_info "Organizing project structure..."
    
    # Create .backup directory for old files if it doesn't exist
    if [[ ! -d ".backup" ]]; then
        mkdir -p .backup
        log_info "Created .backup directory"
    fi
    
    # Move any important old files there before cleanup
    find . -maxdepth 1 -type f -name "*.old" -exec mv {} .backup/ \; 2>/dev/null
    
    log_info "Project structure organized"
}

show_cleanup_summary() {
    log_info "=== Cleanup Summary ==="
    
    echo "Project structure after cleanup:"
    echo ""
    echo "📁 Main Projects:"
    echo "  🏢 backup_blockchain_truenas/        (Enterprise - ZFS-first)"
    echo "  🛡️  backup_blockchain_truenas-safe/   (Safe - Enhanced CLI)"
    echo "  🎮 backup_blockchain_truenas-pacman/ (Gamified - Learning)"
    echo ""
    
    echo "📁 Root Files (Keep):"
    echo "  📄 README.md                         (Main documentation)"
    echo "  📄 CONTRIBUTING.md                    (Contribution guide)"
    echo "  📄 CODE_OF_CONDUCT.md                 (Community guidelines)"
    echo "  📄 LICENSE.md                         (License)"
    echo "  📄 SECURITY.md                        (Security policy)"
    echo "  📄 SUPPORT.md                         (Support info)"
    echo ""
    
    echo "🗑️ Files Cleaned:"
    echo "  🔧 Duplicate configs"
    echo "  📋 Duplicate documentation"
    echo "  🧪 Test and temporary files"
    echo "  📝 Development artifacts"
    echo ""
}

# Main Cleanup Function
main() {
    log_info "Starting scripts directory cleanup"
    log_info "Working directory: $SCRIPTS_DIR"
    echo ""
    
    # Safety check
    if [[ ! -d "$SCRIPTS_DIR" ]]; then
        log_error "Scripts directory not found: $SCRIPTS_DIR"
        exit 1
    fi
    
    # Show what we found before cleanup
    analyze_garbage_files
    
    # Ask for confirmation
    echo -e "${YELLOW}=== Cleanup Actions Required ===${NC}"
    echo ""
    echo "1. Remove duplicate config files"
    echo "2. Clean up duplicate documentation"  
    echo "3. Remove test and temporary files"
    echo "4. Remove development artifacts"
    echo "5. Organize project structure"
    echo ""
    read -p "Execute cleanup? [y/N]: " -t 30 confirm
    
    if [[ "$confirm" =~ ^[yY] ]]; then
        log_info "Executing cleanup actions..."
        echo ""
        
        cleanup_safe_files
        cleanup_duplicate_docs
        cleanup_temp_files
        cleanup_development_files
        organize_project_structure
        
        echo ""
        show_cleanup_summary
        
        log_info "Cleanup completed successfully!"
        log_info "Log saved to: $CLEANUP_LOG"
    else
        log_info "Cleanup cancelled by user"
    fi
}

# Run main function
main "$@"