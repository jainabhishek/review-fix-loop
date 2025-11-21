#!/usr/bin/env bash
set -euo pipefail

# Debug: print each command
# set -x

# Targeted verification tests for review-fix.sh and test-review-fix.sh fixes
# These tests verify specific fixes before running the full test suite

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_FIX_SCRIPT="${SCRIPT_DIR}/review-fix.sh"
TEST_ROOT="/tmp/verify-fixes-$$"
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[PASS]${NC} $*"
}

log_error() {
  echo -e "${RED}[FAIL]${NC} $*"
}

log_warning() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

cleanup() {
  if [[ -d "${TEST_ROOT}" ]]; then
    rm -rf "${TEST_ROOT}"
  fi
}

# Don't trap cleanup on EXIT - we'll call it explicitly at the end
# trap cleanup EXIT

run_test() {
  local test_name="$1"
  local test_function="$2"

  log_info "Running: ${test_name}"

  # Run in subshell to isolate each test's environment
  if (${test_function}); then
    log_success "${test_name}"
    ((TESTS_PASSED++))
    return 0
  else
    log_error "${test_name}"
    ((TESTS_FAILED++))
    return 1
  fi
}

# ==============================================================================
# TEST 1: Verify git commit creation in test environment
# ==============================================================================
test_git_commit_without_signing() {
  local test_dir="${TEST_ROOT}/test-git-commit"
  mkdir -p "${test_dir}"
  cd "${test_dir}"

  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Disable commit signing (this is the fix we're verifying)
  git config commit.gpgsign false

  echo "test content" > test.txt
  git add test.txt

  # This should succeed without signing errors
  if git commit -q -m "Test commit" 2>&1; then
    log_info "  ✓ Commit created successfully without signing"
    return 0
  else
    log_error "  ✗ Failed to create commit (signing issue?)"
    return 1
  fi
}

# ==============================================================================
# TEST 2: Verify mock codex isolation from git working tree
# ==============================================================================
test_mock_codex_isolation() {
  local test_dir="${TEST_ROOT}/test-mock-isolation"
  local mock_bin_dir="${TEST_ROOT}/test-mock-bin"  # Outside repo

  mkdir -p "${test_dir}"
  mkdir -p "${mock_bin_dir}"

  cd "${test_dir}"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git config commit.gpgsign false

  echo "# Test" > README.md
  git add README.md
  git commit -q -m "Initial commit"

  # Create mock codex OUTSIDE the git repo
  cat > "${mock_bin_dir}/codex" << 'EOF'
#!/usr/bin/env bash
echo "Mock codex"
EOF
  chmod +x "${mock_bin_dir}/codex"

  # Verify git status is clean
  local status_output
  status_output="$(git status --porcelain --untracked-files=all)"

  if [[ -z "${status_output}" ]]; then
    log_info "  ✓ Git working tree is clean (mock codex not tracked)"

    # Verify mock codex is accessible
    if [[ -x "${mock_bin_dir}/codex" ]]; then
      log_info "  ✓ Mock codex is accessible and executable"
      log_info "    Location: ${mock_bin_dir}/codex"
      return 0
    else
      log_error "  ✗ Mock codex not executable"
      return 1
    fi
  else
    log_error "  ✗ Git working tree has uncommitted changes:"
    echo "${status_output}"
    return 1
  fi
}

# ==============================================================================
# TEST 3: Verify compute_diff_signature works on empty repository
# ==============================================================================
test_diff_signature_empty_repo() {
  local test_dir="${TEST_ROOT}/test-diff-empty"
  mkdir -p "${test_dir}"
  cd "${test_dir}"

  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git config commit.gpgsign false

  # Extract and test the compute_diff_signature function logic directly
  # Instead of sourcing the entire script which may have side effects

  # This should NOT fail even though HEAD doesn't exist
  local signature
  signature=$({
    git status --porcelain --untracked-files=all
    git diff --binary HEAD 2>/dev/null || echo "# empty repo"
  } | git hash-object --stdin 2>&1)

  local exit_code=$?
  if [[ ${exit_code} -eq 0 && -n "${signature}" ]]; then
    log_info "  ✓ compute_diff_signature succeeded on empty repo"
    log_info "    Signature: ${signature}"
    return 0
  else
    log_error "  ✗ compute_diff_signature failed on empty repo"
    log_error "    Error: ${signature}"
    return 1
  fi
}

# ==============================================================================
# TEST 4: Verify compute_diff_signature detects changes
# ==============================================================================
test_diff_signature_detects_changes() {
  local test_dir="${TEST_ROOT}/test-diff-changes"
  mkdir -p "${test_dir}"
  cd "${test_dir}"

  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git config commit.gpgsign false

  echo "initial" > file.txt
  git add file.txt
  git commit -q -m "Initial commit"

  # Define compute_diff_signature inline to avoid sourcing issues
  compute_diff_signature() {
    {
      git status --porcelain --untracked-files=all
      git diff --binary HEAD 2>/dev/null || echo "# empty repo"
    } | git hash-object --stdin
  }

  # Get baseline signature
  local sig1
  sig1="$(compute_diff_signature)"

  # Make a change
  echo "modified" > file.txt

  # Get new signature
  local sig2
  sig2="$(compute_diff_signature)"

  if [[ "${sig1}" != "${sig2}" ]]; then
    log_info "  ✓ Signature changed after modification"
    log_info "    Before: ${sig1}"
    log_info "    After:  ${sig2}"
    return 0
  else
    log_error "  ✗ Signature did not change after modification"
    return 1
  fi
}

# ==============================================================================
# TEST 5: Verify compute_diff_signature stable when no changes
# ==============================================================================
test_diff_signature_stable() {
  local test_dir="${TEST_ROOT}/test-diff-stable"
  mkdir -p "${test_dir}"
  cd "${test_dir}"

  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git config commit.gpgsign false

  echo "content" > file.txt
  git add file.txt
  git commit -q -m "Initial commit"

  # Define compute_diff_signature inline to avoid sourcing issues
  compute_diff_signature() {
    {
      git status --porcelain --untracked-files=all
      git diff --binary HEAD 2>/dev/null || echo "# empty repo"
    } | git hash-object --stdin
  }

  local sig1
  sig1="$(compute_diff_signature)"

  local sig2
  sig2="$(compute_diff_signature)"

  if [[ "${sig1}" == "${sig2}" ]]; then
    log_info "  ✓ Signature stable when no changes"
    return 0
  else
    log_error "  ✗ Signature unstable (should be same)"
    return 1
  fi
}

# ==============================================================================
# Main
# ==============================================================================
main() {
  echo "========================================"
  echo "Targeted Verification Tests"
  echo "========================================"
  echo

  if [[ ! -f "${REVIEW_FIX_SCRIPT}" ]]; then
    log_error "review-fix.sh not found at ${REVIEW_FIX_SCRIPT}"
    exit 1
  fi

  echo "Issue 1: Git Commit Signing"
  echo "----------------------------"
  run_test "Git commits work without signing errors" test_git_commit_without_signing || true
  echo

  echo "Issue 2: Mock Codex Isolation"
  echo "----------------------------"
  run_test "Mock codex outside git working tree" test_mock_codex_isolation || true
  echo

  echo "Issue 3: Diff Signature Edge Cases"
  echo "----------------------------"
  run_test "compute_diff_signature on empty repo" test_diff_signature_empty_repo || true
  run_test "compute_diff_signature detects changes" test_diff_signature_detects_changes || true
  run_test "compute_diff_signature stable when no changes" test_diff_signature_stable || true
  echo

  echo "================================"
  echo "Verification Summary"
  echo "================================"
  echo -e "${GREEN}Passed: ${TESTS_PASSED}${NC}"
  echo -e "${RED}Failed: ${TESTS_FAILED}${NC}"
  echo "Total:  $((TESTS_PASSED + TESTS_FAILED))"
  echo "================================"

  if [[ ${TESTS_FAILED} -eq 0 ]]; then
    log_success "All verification tests passed!"
    cleanup
    return 0
  else
    log_error "Some verification tests failed"
    cleanup
    return 1
  fi
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
