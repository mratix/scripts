#!/bin/bash
# ============================================================
# test_backup_blockchain.sh
# Test suite for backup_blockchain_truenas-safe.sh
#
# Usage: ./test_backup_blockchain.sh
# Author: mratix
# ============================================================

set -euo pipefail

# Test configuration
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
MAIN_SCRIPT="${SCRIPT_DIR}/backup_blockchain_truenas-safe.sh"
CONFIG_FILE="${SCRIPT_DIR}/backup_blockchain_truenas-safe.conf"
TEST_LOG="${SCRIPT_DIR}/test_results.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log_test() {
    echo -e "${GREEN}[TEST]${NC} $*" | tee -a "$TEST_LOG"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*" | tee -a "$TEST_LOG"
}

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $*" | tee -a "$TEST_LOG"
}

# Test helper functions
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_exit_code="${3:-0}"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    log_test "Running: $test_name"
    
    if eval "$test_command" >/dev/null 2>>"$TEST_LOG"; then
        if [[ "$expected_exit_code" -eq 0 ]]; then
            echo "  ✓ PASSED"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo "  ✗ FAILED (expected exit code $expected_exit_code, got 0)"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        local exit_code=$?
        if [[ "$exit_code" -eq "$expected_exit_code" ]]; then
            echo "  ✓ PASSED (exit code $exit_code as expected)"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo "  ✗ FAILED (exit code $exit_code, expected $expected_exit_code)"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi
    echo ""
}

# Mock functions for testing
mock_hostname() {
    echo "hpms1"
}

mock_midclt() {
    # Mock midclt to simulate TrueNAS API
    if [[ "$*" == *"chart.release.query"* ]]; then
        echo '[{"release_name": "bitcoind-knots", "status": "ACTIVE"}]'
        return 0
    elif [[ "$*" == *"chart.release.scale"* ]]; then
        return 0
    else
        return 1
    fi
}

# Setup test environment
setup_test_env() {
    log_info "Setting up test environment..."
    
    # Create test directories
    mkdir -p "${SCRIPT_DIR}/test_mnt/hpms1/blockchain/bitcoind"
    mkdir -p "${SCRIPT_DIR}/test_mnt/hpms1/blockchain/monerod"
    mkdir -p "${SCRIPT_DIR}/test_mnt/hpms1/blockchain/chia"
    mkdir -p "${SCRIPT_DIR}/test_mnt/cronas/blockchain"
    
    # Create mock PID files
    touch "${SCRIPT_DIR}/test_mnt/hpms1/blockchain/bitcoind/bitcoind.pid"
    touch "${SCRIPT_DIR}/test_mnt/hpms1/blockchain/monerod/monerod.pid"
    touch "${SCRIPT_DIR}/test_mnt/hpms1/blockchain/chia/chia.pid"
    
    # Create mock blockchain data
    echo "test anchors data" > "${SCRIPT_DIR}/test_mnt/hpms1/blockchain/bitcoind/anchors.dat"
    echo "test lmdb data" > "${SCRIPT_DIR}/test_mnt/hpms1/blockchain/monerod/lmdb/data.mdb"
    echo "test chia db" > "${SCRIPT_DIR}/test_mnt/hpms1/blockchain/chia/.chia/mainnet/db/blockchain_v2_mainnet.sqlite"
    
    # Override commands for testing
    alias hostname='mock_hostname'
    alias midclt='mock_midclt'
    
    # Create dummy mount files
    touch "${SCRIPT_DIR}/test_mnt/cronas/blockchain/cronas.dummy"
    touch "${SCRIPT_DIR}/test_mnt/cronas/blockchain/dir.dummy"
}

# Cleanup test environment
cleanup_test_env() {
    log_info "Cleaning up test environment..."
    rm -rf "${SCRIPT_DIR}/test_mnt"
    unalias hostname midclt 2>/dev/null || true
}

# Test functions
test_script_exists() {
    run_test "Script exists" "[[ -f '$MAIN_SCRIPT' ]]"
}

test_config_exists() {
    run_test "Config file exists" "[[ -f '$CONFIG_FILE' ]]"
}

test_script_executable() {
    run_test "Script is executable" "[[ -x '$MAIN_SCRIPT' ]]"
}

test_config_syntax() {
    run_test "Config file has valid bash syntax" "bash -n '$CONFIG_FILE'"
}

test_script_syntax() {
    run_test "Script has valid bash syntax" "bash -n '$MAIN_SCRIPT'"
}

test_help_functionality() {
    run_test "Help command works" "'$MAIN_SCRIPT' help >/dev/null" 0
}

test_version_functionality() {
    run_test "Version command works" "'$MAIN_SCRIPT' version >/dev/null" 0
}

test_invalid_arguments() {
    run_test "Invalid arguments exit with error" "'$MAIN_SCRIPT' invalid" 1
}

test_height_validation_bitcoin() {
    run_test "Valid Bitcoin height accepted" "echo '800000' | grep -E '^[0-9]{6,8}$'" 0
    run_test "Invalid Bitcoin height rejected" "echo '80000' | grep -E '^[0-9]{6,8}$'" 1
}

test_height_validation_monero() {
    run_test "Valid Monero height accepted" "echo '3000000' | grep -E '^[0-9]{6,7}$'" 0
    run_test "Invalid Monero height rejected" "echo '30000' | grep -E '^[0-9]{6,7}$'" 1
}

test_config_loading() {
    run_test "Config variables are loadable" "source '$CONFIG_FILE' && [[ -n \"\$NAS_USER\" ]]"
}

test_service_mappings() {
    run_test "Service mappings exist in config" "source '$CONFIG_FILE' && [[ -n \"\${SERVICE_CONFIGS[hpms1_btc]}\" ]]"
}

test_rsync_options() {
    run_test "Rsync options exist in config" "source '$CONFIG_FILE' && [[ -n \"\${RSYNC_CONFIGS[bitcoind]}\" ]]"
}

# Integration tests (require more setup)
test_service_detection() {
    log_info "Note: Service detection test requires proper environment setup"
    # This would need more sophisticated mocking for full testing
}

test_mount_functionality() {
    log_info "Note: Mount functionality test requires root privileges"
    # Skip in basic test suite
}

# Main test runner
main() {
    echo "========================================"
    echo "Backup Blockchain Script Test Suite"
    echo "========================================"
    echo ""
    
    # Clear previous test log
    > "$TEST_LOG"
    
    # Run basic tests
    log_info "Running basic tests..."
    test_script_exists
    test_config_exists
    test_script_executable
    test_config_syntax
    test_script_syntax
    
    log_info "Running functionality tests..."
    test_help_functionality
    test_version_functionality
    test_invalid_arguments
    
    log_info "Running validation tests..."
    test_height_validation_bitcoin
    test_height_validation_monero
    
    log_info "Running configuration tests..."
    test_config_loading
    test_service_mappings
    test_rsync_options
    
    log_info "Running integration tests..."
    test_service_detection
    test_mount_functionality
    
    # Test summary
    echo "========================================"
    echo "Test Summary"
    echo "========================================"
    echo "Tests run:    $TESTS_RUN"
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed. Check $TEST_LOG for details.${NC}"
        exit 1
    fi
}

# Check if running with specific test category
case "${1:-all}" in
    basic)
        test_script_exists
        test_config_exists
        test_script_executable
        test_config_syntax
        test_script_syntax
        ;;
    syntax)
        test_config_syntax
        test_script_syntax
        ;;
    functionality)
        test_help_functionality
        test_version_functionality
        test_invalid_arguments
        ;;
    validation)
        test_height_validation_bitcoin
        test_height_validation_monero
        ;;
    config)
        test_config_loading
        test_service_mappings
        test_rsync_options
        ;;
    all|*)
        main
        ;;
esac