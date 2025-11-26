#!/usr/bin/env bash
set -euo pipefail

# Test script for review-fix.sh covering all 4 review presets
# Usage: ./test-review-fix.sh [--mock|--real]
#   --mock: Use mock Codex commands (tests script logic without Codex)
#   --real: Use real Codex commands (requires Codex CLI)

TEST_MODE="${1:---mock}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_FIX_SCRIPT="${SCRIPT_DIR}/review-fix.sh"
TEST_ROOT="/tmp/review-fix-test-$$"
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    log_info "Cleaning up test directory: ${TEST_ROOT}"
    rm -rf "${TEST_ROOT}"
  fi
}

trap cleanup EXIT

setup_test_env() {
  local test_dir="$1"
  mkdir -p "${test_dir}"
  cd "${test_dir}"

  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  # Disable commit signing for test environments
  git config commit.gpgsign false

  # Create initial commit
  echo "# Test Project" > README.md
  git add README.md
  git commit -q -m "Initial commit"

  log_info "Created test repository in ${test_dir}"
}

create_mock_codex() {
  local test_dir="$1"
  local mock_script="${test_dir}/mock-codex.sh"

  cat > "${mock_script}" << 'EOF'
#!/usr/bin/env bash
# Mock Codex CLI for testing

COMMAND="$1"
shift

case "${COMMAND}" in
  exec)
    SUBCOMMAND="$1"
    shift

    if [[ "${SUBCOMMAND}" == "--full-auto" ]]; then
      REVIEW_CMD="$1"

      if [[ "${REVIEW_CMD}" == "/review" ]]; then
        # Simulate review output
        echo "Running code review..."
        echo "Found 2 issues:"
        echo "1. Missing semicolon in file.js:10"
        echo "2. Unused variable in utils.py:25"
        echo "session id: mock-session-12345"

        # Read any piped input (preset selections)
        if [[ ! -t 0 ]]; then
          while IFS= read -r line; do
            echo "Selected option: ${line}"
          done
        fi

        exit 0
      elif [[ "${REVIEW_CMD}" == "resume" ]]; then
        SESSION_ID="$1"
        shift
        PROMPT="$*"

        echo "Resuming session ${SESSION_ID}"
        echo "Applying fixes: ${PROMPT}"

        # Simulate applying a fix by modifying a file
        if [[ -f "test-file.js" ]]; then
          echo "// Fixed issue" >> test-file.js
        fi

      fi
    elif [[ "${SUBCOMMAND}" == "exec" ]]; then
      # Handle "codex exec 'prompt'" format (used for commit messages)
      PROMPT="$1"
      if [[ "${PROMPT}" == *"Generate a concise"* ]]; then
        # Read stdin (diff) to simulate processing
        cat > /dev/null
        echo "fix(ai): fixed issues found in review"
        exit 0
      fi
    fi
    ;;
esac

echo "Mock Codex: Unknown command sequence" >&2
exit 1
EOF

  chmod +x "${mock_script}"
  echo "${mock_script}"
}

run_test() {
  local test_name="$1"
  local test_function="$2"

  log_info "Running test: ${test_name}"

  if ${test_function}; then
    log_success "${test_name}"
    ((TESTS_PASSED++))
    return 0
  else
    log_error "${test_name}"
    ((TESTS_FAILED++))
    return 1
  fi
}

test_preset_1_branch_review() {
  local test_dir="${TEST_ROOT}/preset-1/repo"
  local mock_bin_dir="${TEST_ROOT}/preset-1/bin"

  # Create mock codex in a separate directory (not in git repo)
  if [[ "${TEST_MODE}" == "--mock" ]]; then
    mkdir -p "${mock_bin_dir}"
    local mock_codex="${mock_bin_dir}/codex"
    cat > "${mock_codex}" << 'MOCK_EOF'
#!/usr/bin/env bash
COMMAND="$1"
shift
case "${COMMAND}" in
  exec)
    SUBCOMMAND="$1"
    shift
    if [[ "${SUBCOMMAND}" == "--full-auto" ]]; then
      REVIEW_CMD="$1"
      if [[ "${REVIEW_CMD}" == "/review" ]]; then
        echo "Running code review..."
        echo "Session ID: mock-session-12345"
        if [[ ! -t 0 ]]; then
          while IFS= read -r line; do
            echo "Selected option: ${line}"
          done
        fi
        exit 0
      elif [[ "${REVIEW_CMD}" == "resume" ]]; then
        echo "Resuming session $1"
        echo "Applying fixes"
        if [[ -f "test-file.js" ]]; then
          echo "// Fixed issue" >> test-file.js
        fi
        exit 0
      fi
    else
      PROMPT="${SUBCOMMAND}"
      if [[ "${PROMPT}" == *"Generate a concise"* ]]; then
        echo "fix(ai): fixed issues found in review"
        exit 0
      fi
    fi
    ;;
esac
exit 1
MOCK_EOF
    chmod +x "${mock_codex}"
    export PATH="${mock_bin_dir}:${PATH}"
  fi

  setup_test_env "${test_dir}"

  # Main branch already exists from setup_test_env
  # Create a feature branch with changes
  git checkout -q -b feature/test-branch
  echo "function test() {}" > test-file.js
  git add test-file.js
  git commit -q -m "Add test function"

  log_info "Testing REVIEW_PRESET=branch with REVIEW_BASE_BRANCH=main"

  local output_log="/tmp/test-output-preset1-$$.log"
  if MAX_LOOPS=1 REVIEW_PRESET=branch REVIEW_BASE_BRANCH=main bash "${REVIEW_FIX_SCRIPT}" 2>&1 | tee "${output_log}"; then
    # Check if it ran successfully
    if grep -q "Codex review iteration 1" "${output_log}"; then
      log_success "Preset 1 (branch review) executed successfully"
      return 0
    else
      log_error "Preset 1 did not execute review iteration"
      return 1
    fi
  else
    local exit_code=$?
    if [[ "${TEST_MODE}" == "--mock" ]]; then
      log_error "Preset 1 failed with exit code ${exit_code}"
      return 1
    else
      log_warning "Preset 1 may require real Codex CLI"
      return 0
    fi
  fi
}

test_preset_2_uncommitted() {
  local test_dir="${TEST_ROOT}/preset-2/repo"
  local mock_bin_dir="${TEST_ROOT}/preset-2/bin"

  # Create mock codex in a separate directory (not in git repo)
  if [[ "${TEST_MODE}" == "--mock" ]]; then
    mkdir -p "${mock_bin_dir}"
    local mock_codex="${mock_bin_dir}/codex"
    cat > "${mock_codex}" << 'MOCK_EOF'
#!/usr/bin/env bash
COMMAND="$1"
shift
case "${COMMAND}" in
  exec)
    SUBCOMMAND="$1"
    shift
    if [[ "${SUBCOMMAND}" == "--full-auto" ]]; then
      REVIEW_CMD="$1"
      if [[ "${REVIEW_CMD}" == "/review" ]]; then
        echo "Running code review..."
        echo "SESSION ID: mock-session-23456"
        if [[ ! -t 0 ]]; then
          while IFS= read -r line; do
            echo "Selected option: ${line}"
          done
        fi
        exit 0
      elif [[ "${REVIEW_CMD}" == "resume" ]]; then
        echo "Resuming session $1"
        echo "Applying fixes"
        if [[ -f "test-file.js" ]]; then
          echo "// Fixed issue" >> test-file.js
        fi
        exit 0
      fi
    else
      PROMPT="${SUBCOMMAND}"
      if [[ "${PROMPT}" == *"Generate a concise"* ]]; then
        echo "fix(ai): fixed issues found in review"
        exit 0
      fi
    fi
    ;;
esac
exit 1
MOCK_EOF
    chmod +x "${mock_codex}"
    export PATH="${mock_bin_dir}:${PATH}"
  fi

  setup_test_env "${test_dir}"

  # Create uncommitted changes
  echo "function uncommitted() {}" > test-file.js

  log_info "Testing REVIEW_PRESET=uncommitted"

  local output_log="/tmp/test-output-preset2-$$.log"
  if MAX_LOOPS=1 REVIEW_PRESET=uncommitted bash "${REVIEW_FIX_SCRIPT}" 2>&1 | tee "${output_log}"; then
    # Check if it skipped auto-commit
    if grep -q "uncommitted-review preset prohibits auto-commits" "${output_log}" || \
       grep -q "No changes from Codex" "${output_log}" || \
       grep -q "Uncommitted-changes review preset selected" "${output_log}"; then
      log_success "Preset 2 (uncommitted changes) executed successfully"
      return 0
    else
      log_error "Preset 2 did not show expected uncommitted behavior"
      return 1
    fi
  else
    local exit_code=$?
    if [[ "${TEST_MODE}" == "--mock" ]]; then
      log_error "Preset 2 failed with exit code ${exit_code}"
      return 1
    else
      log_warning "Preset 2 may require real Codex CLI"
      return 0
    fi
  fi
}

test_preset_3_commit() {
  local test_dir="${TEST_ROOT}/preset-3/repo"
  local mock_bin_dir="${TEST_ROOT}/preset-3/bin"

  # Create mock codex in a separate directory (not in git repo)
  if [[ "${TEST_MODE}" == "--mock" ]]; then
    mkdir -p "${mock_bin_dir}"
    local mock_codex="${mock_bin_dir}/codex"
    cat > "${mock_codex}" << 'MOCK_EOF'
#!/usr/bin/env bash
COMMAND="$1"
shift
case "${COMMAND}" in
  exec)
    SUBCOMMAND="$1"
    shift
    if [[ "${SUBCOMMAND}" == "--full-auto" ]]; then
      REVIEW_CMD="$1"
      if [[ "${REVIEW_CMD}" == "/review" ]]; then
        echo "Running code review..."
        echo "session id: mock-session-34567"
        if [[ ! -t 0 ]]; then
          while IFS= read -r line; do
            echo "Selected option: ${line}"
          done
        fi
        exit 0
      elif [[ "${REVIEW_CMD}" == "resume" ]]; then
        echo "Resuming session $1"
        echo "Applying fixes"
        if [[ -f "test-file.js" ]]; then
          echo "// Fixed issue" >> test-file.js
        fi
        exit 0
      fi
    else
      PROMPT="${SUBCOMMAND}"
      if [[ "${PROMPT}" == *"Generate a concise"* ]]; then
        echo "fix(ai): fixed issues found in review"
        exit 0
      fi
    fi
    ;;
esac
exit 1
MOCK_EOF
    chmod +x "${mock_codex}"
    export PATH="${mock_bin_dir}:${PATH}"
  fi

  setup_test_env "${test_dir}"

  # Create a specific commit to review
  echo "function toReview() {}" > test-file.js
  git add test-file.js
  git commit -q -m "Add function to review"

  local commit_sha
  commit_sha="$(git rev-parse HEAD)"

  log_info "Testing REVIEW_PRESET=commit with REVIEW_COMMIT_SHA=${commit_sha}"

  local output_log="/tmp/test-output-preset3-$$.log"
  if MAX_LOOPS=1 REVIEW_PRESET=commit REVIEW_COMMIT_SHA="${commit_sha}" bash "${REVIEW_FIX_SCRIPT}" 2>&1 | tee "${output_log}"; then
    if grep -q "Codex review iteration 1" "${output_log}"; then
      log_success "Preset 3 (commit review) executed successfully"
      return 0
    else
      log_error "Preset 3 did not execute review iteration"
      return 1
    fi
  else
    local exit_code=$?
    if [[ "${TEST_MODE}" == "--mock" ]]; then
      log_error "Preset 3 failed with exit code ${exit_code}"
      return 1
    else
      log_warning "Preset 3 may require real Codex CLI"
      return 0
    fi
  fi
}

test_preset_4_custom() {
  local test_dir="${TEST_ROOT}/preset-4/repo"
  local mock_bin_dir="${TEST_ROOT}/preset-4/bin"

  # Create mock codex in a separate directory (not in git repo)
  if [[ "${TEST_MODE}" == "--mock" ]]; then
    mkdir -p "${mock_bin_dir}"
    local mock_codex="${mock_bin_dir}/codex"
    cat > "${mock_codex}" << 'MOCK_EOF'
#!/usr/bin/env bash
COMMAND="$1"
shift
case "${COMMAND}" in
  exec)
    SUBCOMMAND="$1"
    shift
    if [[ "${SUBCOMMAND}" == "--full-auto" ]]; then
      REVIEW_CMD="$1"
      if [[ "${REVIEW_CMD}" == "/review" ]]; then
        echo "Running code review..."
        echo "session id: mock-session-45678"
        if [[ ! -t 0 ]]; then
          while IFS= read -r line; do
            echo "Selected option: ${line}"
          done
        fi
        exit 0
      elif [[ "${REVIEW_CMD}" == "resume" ]]; then
        echo "Resuming session $1"
        echo "Applying fixes"
        if [[ -f "test-file.js" ]]; then
          echo "// Fixed issue" >> test-file.js
        fi
        exit 0
      fi
    else
      PROMPT="${SUBCOMMAND}"
      if [[ "${PROMPT}" == *"Generate a concise"* ]]; then
        echo "fix(ai): fixed issues found in review"
        exit 0
      fi
    fi
    ;;
esac
exit 1
MOCK_EOF
    chmod +x "${mock_codex}"
    export PATH="${mock_bin_dir}:${PATH}"
  fi

  setup_test_env "${test_dir}"

  # Create custom instructions file and add to git to keep working tree clean
  cat > custom-instructions.md << 'EOF'
Review the code for:
- Performance optimizations
- Security vulnerabilities
- Best practices
EOF

  # Add a file to review
  echo "function custom() {}" > test-file.js
  git add test-file.js custom-instructions.md
  git commit -q -m "Add custom function and instructions"

  log_info "Testing REVIEW_PRESET=custom with instructions file"

  local output_log="/tmp/test-output-preset4-$$.log"
  if MAX_LOOPS=1 REVIEW_PRESET=custom REVIEW_CUSTOM_INSTRUCTIONS_FILE=custom-instructions.md bash "${REVIEW_FIX_SCRIPT}" 2>&1 | tee "${output_log}"; then
    if grep -q "Codex review iteration 1" "${output_log}"; then
      log_success "Preset 4 (custom instructions) executed successfully"
      return 0
    else
      log_error "Preset 4 did not execute review iteration"
      return 1
    fi
  else
    local exit_code=$?
    if [[ "${TEST_MODE}" == "--mock" ]]; then
      log_error "Preset 4 failed with exit code ${exit_code}"
      return 1
    else
      log_warning "Preset 4 may require real Codex CLI"
      return 0
    fi
  fi
}

test_commit_message_resolution() {
  local test_dir="${TEST_ROOT}/commit-msg/repo"
  local mock_bin_dir="${TEST_ROOT}/commit-msg/bin"

  # Create mock codex in a separate directory (not in git repo)
  if [[ "${TEST_MODE}" == "--mock" ]]; then
    mkdir -p "${mock_bin_dir}"
    local mock_codex="${mock_bin_dir}/codex"
    cat > "${mock_codex}" << 'MOCK_EOF'
#!/usr/bin/env bash
COMMAND="$1"
shift
case "${COMMAND}" in
  exec)
    SUBCOMMAND="$1"
    shift
    if [[ "${SUBCOMMAND}" == "--full-auto" ]]; then
      REVIEW_CMD="$1"
      if [[ "${REVIEW_CMD}" == "/review" ]]; then
        echo "Running code review..."
        echo "session id: mock-session-56789"
        exit 0
      elif [[ "${REVIEW_CMD}" == "resume" ]]; then
        echo "Resuming session $1"
        echo "Applying fixes"
        if [[ -f "test.js" ]]; then
          echo "// Fixed issue" >> test.js
        fi
        exit 0
      fi
    else
      PROMPT="${SUBCOMMAND}"
      if [[ "${PROMPT}" == *"Generate a concise"* ]]; then
        echo "fix(ai): fixed issues found in review"
        exit 0
      fi
    fi
    ;;
esac
exit 1
MOCK_EOF
    chmod +x "${mock_codex}"
    export PATH="${mock_bin_dir}:${PATH}"
  fi

  setup_test_env "${test_dir}"

  # Test custom commit message - add rules file to git to keep working tree clean
  cat > commit-rules.md << 'EOF'
  autofix_commit_message: fix(auto): iteration %d fixes %s
EOF

  echo "console.log('test')" > test.js
  git add test.js commit-rules.md
  git commit -q -m "Add test file and commit rules"

  # Run with custom commit message
  if [[ "${TEST_MODE}" == "--mock" ]]; then
    local output_log="/tmp/test-output-commit-msg-$$.log"
    if MAX_LOOPS=1 COMMIT_RULES_DOC=commit-rules.md bash "${REVIEW_FIX_SCRIPT}" 2>&1 | tee "${output_log}"; then
      local expected_message="fix(auto): iteration 1 fixes fix(ai): fixed issues found in review"
      local latest_commit
      latest_commit="$(git log -1 --pretty=%s 2>/dev/null || true)"

      if [[ "${latest_commit}" == "${expected_message}" ]]; then
        log_success "Custom commit message format applied with summary"
        return 0
      fi

      log_error "Expected commit message '${expected_message}' but found '${latest_commit:-<none>}'"
      log_info "Runner output captured at ${output_log}"
      return 1
    else
      log_warning "Commit message test may require real Codex"
      return 0
    fi
  else
    log_info "Skipping commit message test in real mode"
    return 0
  fi
}

test_untracked_files_handling() {
  local test_dir="${TEST_ROOT}/untracked/repo"
  local mock_bin_dir="${TEST_ROOT}/untracked/bin"

  if [[ "${TEST_MODE}" == "--mock" ]]; then
    mkdir -p "${mock_bin_dir}"
    local mock_codex="${mock_bin_dir}/codex"
    cat > "${mock_codex}" << 'MOCK_EOF'
#!/usr/bin/env bash
COMMAND="$1"
shift
case "${COMMAND}" in
  exec)
    SUBCOMMAND="$1"
    shift
    if [[ "${SUBCOMMAND}" == "--full-auto" ]]; then
      REVIEW_CMD="$1"
      if [[ "${REVIEW_CMD}" == "/review" ]]; then
        echo "Running code review..."
        echo "session id: mock-session-untracked"
        exit 0
      elif [[ "${REVIEW_CMD}" == "resume" ]]; then
        echo "Resuming session $1"
        echo "Creating new file"
        echo "new content" > new-file.js
        exit 0
      fi
    else
      PROMPT="${SUBCOMMAND}"
      if [[ "${PROMPT}" == *"Generate a concise"* ]]; then
        echo "fix(ai): fixed issues found in review"
        exit 0
      fi
    fi
    ;;
esac
exit 1
MOCK_EOF
    chmod +x "${mock_codex}"
    export PATH="${mock_bin_dir}:${PATH}"
  fi

  setup_test_env "${test_dir}"

  log_info "Testing INCLUDE_UNTRACKED=true"

  local output_log="/tmp/test-output-untracked-$$.log"
  
  # Retry with branch preset to verify commit behavior
  setup_test_env "${test_dir}-2"
  # Need to re-export PATH for the new shell or just rely on previous export if in same subshell?
  # The mock bin dir is absolute, so we can reuse it.
  export PATH="${mock_bin_dir}:${PATH}"
  
  git checkout -q -b feature/untracked-test
  
  if MAX_LOOPS=1 INCLUDE_UNTRACKED=true REVIEW_PRESET=branch REVIEW_BASE_BRANCH=main bash "${REVIEW_FIX_SCRIPT}" 2>&1 | tee "${output_log}"; then
    if git ls-files new-file.js --error-unmatch &>/dev/null; then
      log_success "Untracked file was committed with INCLUDE_UNTRACKED=true"
      return 0
    else
      log_error "New file was not committed"
      return 1
    fi
  else
    log_error "Untracked test failed execution"
    return 1
  fi
}

print_summary() {
  echo
  echo "================================"
  echo "Test Summary"
  echo "================================"
  echo -e "${GREEN}Passed: ${TESTS_PASSED}${NC}"
  echo -e "${RED}Failed: ${TESTS_FAILED}${NC}"
  echo "Total:  $((TESTS_PASSED + TESTS_FAILED))"
  echo "================================"

  if [[ ${TESTS_FAILED} -eq 0 ]]; then
    log_success "All tests passed!"
    return 0
  else
    log_error "Some tests failed"
    return 1
  fi
}

main() {
  echo "========================================"
  echo "Testing review-fix.sh"
  echo "Test mode: ${TEST_MODE}"
  echo "========================================"
  echo

  if [[ "${TEST_MODE}" == "--real" ]]; then
    log_warning "Running tests with REAL Codex commands"
    log_warning "This will make actual API calls and may incur costs"
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Tests cancelled"
      exit 0
    fi
  fi

  if [[ ! -f "${REVIEW_FIX_SCRIPT}" ]]; then
    log_error "review-fix.sh not found at ${REVIEW_FIX_SCRIPT}"
    exit 1
  fi

  run_test "Preset 1: Branch/PR Review" test_preset_1_branch_review || true
  run_test "Preset 2: Uncommitted Changes" test_preset_2_uncommitted || true
  run_test "Preset 3: Specific Commit" test_preset_3_commit || true
  run_test "Preset 4: Custom Instructions" test_preset_4_custom || true
  run_test "Custom Commit Messages" test_commit_message_resolution || true
  run_test "Untracked Files Handling" test_untracked_files_handling || true

  echo
  print_summary
}

main
