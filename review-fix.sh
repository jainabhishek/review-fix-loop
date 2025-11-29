#!/usr/bin/env bash
set -euo pipefail

# Show help message
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
  cat << 'EOF'
Codex Review-Fix Loop - Automated code review and fix automation

USAGE:
  ./review-fix.sh [--help]

DESCRIPTION:
  Automatically runs Codex code reviews and applies fixes in a loop until
  no more issues are found or max iterations are reached.

ENVIRONMENT VARIABLES:

  Core Settings:
    MAX_LOOPS=N                       Maximum review/fix iterations (default: 10)
    CODEX_MODEL=<model>               Codex model to use (default: gpt-5-codex-high)
    AUTOFIX_COMMIT_MESSAGE=<template> Custom commit message template with %d for iteration
    COMMIT_RULES_DOC=<path>           Path to file defining autofix_commit_message:
    INCLUDE_UNTRACKED=true|false      Whether to include untracked files in auto-commits (default: false)
    DISABLE_AI_COMMIT_MESSAGES=true   Skip Codex API calls for commit messages (default: false)
    AI_COMMIT_MAX_DIFF_BYTES=N        Max diff size before fallback commit message (default: 50000)

  Review Presets:
    REVIEW_PRESET=<preset>            Type of review (1-4, pr, uncommitted, commit, custom)
    REVIEW_BASE_BRANCH=<branch>       Required for preset 1 (PR/branch review)
    REVIEW_COMMIT_SHA=<sha>           Required for preset 3 (commit review)
    REVIEW_CUSTOM_INSTRUCTIONS=<text> Custom instructions for preset 4
    REVIEW_CUSTOM_INSTRUCTIONS_FILE=<path> File with custom instructions for preset 4

EXAMPLES:
  # Run with default settings
  ./review-fix.sh

  # Review uncommitted changes
  REVIEW_PRESET=uncommitted ./review-fix.sh

  # Review changes against main branch
  REVIEW_PRESET=pr REVIEW_BASE_BRANCH=main ./review-fix.sh

  # Custom commit messages
  AUTOFIX_COMMIT_MESSAGE="fix: iteration %d" ./review-fix.sh

  # Extended loop with custom model
  MAX_LOOPS=25 CODEX_MODEL=gpt-5-codex-high ./review-fix.sh

For more information, see README.md
EOF
  exit 0
fi

# Max review/fix iterations (override with: MAX_LOOPS=20 ./review-fix.sh)
MAX_LOOPS="${MAX_LOOPS:-10}"

# Optional path to a commit-guidelines doc that defines `autofix_commit_message:`.
COMMIT_RULES_DOC="${COMMIT_RULES_DOC:-}"

# Allow overriding via AUTOFIX_COMMIT_MESSAGE, e.g., 'chore(scope): fix iteration %d'.
AUTOFIX_COMMIT_MESSAGE="${AUTOFIX_COMMIT_MESSAGE:-}"

# Review preset configuration (mirrors Codex /review options).
REVIEW_PRESET="${REVIEW_PRESET:-}"
REVIEW_BASE_BRANCH="${REVIEW_BASE_BRANCH:-}"
REVIEW_COMMIT_SHA="${REVIEW_COMMIT_SHA:-}"
REVIEW_CUSTOM_INSTRUCTIONS="${REVIEW_CUSTOM_INSTRUCTIONS:-}"
REVIEW_CUSTOM_INSTRUCTIONS_FILE="${REVIEW_CUSTOM_INSTRUCTIONS_FILE:-}"

# Force Codex model (allow override via CODEX_MODEL env).
CODEX_MODEL="${CODEX_MODEL:-gpt-5-codex-high}"
export CODEX_MODEL

# Prompt for applying fixes (configurable).
APPLY_FIXES_PROMPT="${APPLY_FIXES_PROMPT:-Apply the fixes suggested above}"

# Include untracked files in commits (default: false)
INCLUDE_UNTRACKED="${INCLUDE_UNTRACKED:-false}"
# Skip Codex API calls for commit messages (default: false)
DISABLE_AI_COMMIT_MESSAGES="${DISABLE_AI_COMMIT_MESSAGES:-false}"
# Max diff size (in bytes) before using fallback commit message
AI_COMMIT_MAX_DIFF_BYTES="${AI_COMMIT_MAX_DIFF_BYTES:-50000}"
# Auto-approve Codex deletions without prompting (default: false)
AUTO_APPROVE_DELETIONS="${AUTO_APPROVE_DELETIONS:-false}"

LAST_REVIEW_SESSION_ID=""

# Validate MAX_LOOPS is a positive integer
if ! [[ "${MAX_LOOPS}" =~ ^[0-9]+$ ]] || [[ "${MAX_LOOPS}" -lt 1 ]]; then
  echo "Error: MAX_LOOPS must be a positive integer, got '${MAX_LOOPS}'." >&2
  exit 1
fi

# Check if Codex CLI is installed
if ! command -v codex &> /dev/null; then
  echo "Error: 'codex' command not found. Please install Codex CLI." >&2
  echo "Refer to Codex documentation for installation instructions." >&2
  exit 1
fi

ensure_clean_worktree() {
  local status_output
  status_output="$(git status --porcelain --untracked-files=all)"
  if [[ -n "${status_output}" ]]; then
    echo "Error: Working tree has uncommitted or untracked changes. Please commit or stash them before running this script." >&2
    exit 1
  fi
}

to_lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

sanitize_format_string() {
  # Escape % characters in user/AI-provided content to prevent format string issues
  # Example: "fix: resolved %s issue" -> "fix: resolved %%s issue"
  printf '%s' "$1" | sed 's/%/%%/g'
}

sanitize_commit_summary() {
  # Collapse newlines and excess whitespace to keep commit messages single-line and safe
  printf '%s' "$1" | tr '\r\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

get_autofix_commit_template() {
  local template=""
  if [[ -n "${AUTOFIX_COMMIT_MESSAGE}" ]]; then
    template="${AUTOFIX_COMMIT_MESSAGE}"
  elif [[ -n "${COMMIT_RULES_DOC}" ]]; then
    if [[ -f "${COMMIT_RULES_DOC}" ]]; then
      template=$(awk '
        tolower($0) ~ /^autofix_commit_message[[:space:]]*:/ {
          sub(/^[^:]+:[[:space:]]*/, "", $0);
          print;
          exit;
        }
      ' "${COMMIT_RULES_DOC}")

      if [[ -z "${template}" ]]; then
        echo "Warning: ${COMMIT_RULES_DOC} does not define an 'autofix_commit_message:' entry. Using default." >&2
      fi
    else
      echo "Warning: COMMIT_RULES_DOC='${COMMIT_RULES_DOC}' does not exist. Using default commit message." >&2
    fi
  fi

  if [[ -z "${template}" ]]; then
    template="chore(review): %s (iteration %d)"
  fi

  echo "${template}"
}

resolve_commit_message() {
  local iteration="$1"
  local changes_summary="${2:-}"
  local template="${3:-}"

  if [[ -z "${template}" ]]; then
    template="$(get_autofix_commit_template)"
  fi

  # Sanitize changes_summary to prevent format string injection
  if [[ -n "${changes_summary}" ]]; then
    changes_summary="$(sanitize_format_string "${changes_summary}")"
  fi

  # Use string substitution instead of printf to avoid format string vulnerabilities
  local msg="${template//%d/${iteration}}"
  if [[ "${msg}" == *"%s"* ]]; then
    msg="${msg//%s/${changes_summary}}"
  fi
  echo "${msg}"
}

generate_ai_commit_message() {
  local diff_content
  local diff_size
  local max_diff_size="${AI_COMMIT_MAX_DIFF_BYTES}"
  if ! [[ "${max_diff_size}" =~ ^[0-9]+$ ]]; then
    max_diff_size=50000
  fi

  # Get staged changes
  diff_content="$(git diff --cached)"

  if [[ -z "${diff_content}" ]]; then
    echo "chore(review): no changes detected"
    return
  fi

  # Check diff size to avoid overwhelming Codex
  diff_size="${#diff_content}"
  if [[ "${diff_size}" -gt "${max_diff_size}" ]]; then
    echo "Warning: Diff is very large (${diff_size} bytes > AI_COMMIT_MAX_DIFF_BYTES=${max_diff_size}). Using fallback commit message." >&2
    local files_changed
    files_changed="$(git diff --cached --name-only | tr '\n' ',' | sed 's/,/, /g' | sed 's/, $//')"
    echo "chore(review): codex autofix [modified: ${files_changed}]"
    return
  fi

  # Ask Codex to generate a commit message via stdin to avoid shell interpolation
  # Capture stderr to detect authentication or API errors
  local ai_msg
  local codex_stderr
  local codex_tmpfile
  codex_tmpfile="$(mktemp)"
  trap 'rm -f "${codex_tmpfile}"' EXIT INT TERM

  ai_msg="$(printf '%s' "${diff_content}" | codex exec "Generate a concise, one-line commit message for these changes. Follow conventional commits format (e.g. fix: ..., feat: ...). Output ONLY the message text, no quotes or markdown." 2>"${codex_tmpfile}")"

  codex_stderr="$(cat "${codex_tmpfile}")"
  rm -f "${codex_tmpfile}"
  trap - EXIT INT TERM

  # Check for Codex errors (authentication, API issues, etc.)
  if [[ -n "${codex_stderr}" ]]; then
    echo "Warning: Codex API errors during commit message generation:" >&2
    echo "${codex_stderr}" >&2
  fi

  # Fallback if Codex fails or returns empty
  if [[ -z "${ai_msg}" ]]; then
    echo "Warning: Codex did not generate a commit message. Using fallback." >&2
    local files_changed
    files_changed="$(git diff --cached --name-only | tr '\n' ',' | sed 's/,/, /g' | sed 's/, $//')"
    echo "chore(review): codex autofix [modified: ${files_changed}]"
  else
    echo "${ai_msg}"
  fi
}

validate_session_id_format() {
  local session_id="$1"
  # Session IDs should be alphanumeric with hyphens, underscores, or periods
  # Typical format: alphanumeric-alphanumeric or UUID-like; allow short 3-char IDs
  # Examples: "mock-session-12345", "abc123-def456", "550e8400-e29b-41d4-a716-446655440000"
  if [[ "${session_id}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{2,127}$ ]]; then
    return 0
  fi
  return 1
}

capture_session_id() {
  local log_file="$1"
  local session_id

  # More robust pattern matching that extracts the ID after "session id:" regardless of field position
  # Handles variations like "Session ID:", "SESSION ID:", "session id:", etc.
  session_id="$(awk '
    tolower($0) ~ /session id:/ {
      # Find the position of "id:" and extract everything after it
      match(tolower($0), /id:[[:space:]]*/)
      if (RSTART > 0) {
        # Extract from after "id:" to the end, trim whitespace
        remainder = substr($0, RSTART + RLENGTH)
        # Extract first word (session ID) by removing leading/trailing spaces and taking first field
        gsub(/^[[:space:]]+/, "", remainder)
        split(remainder, arr, /[[:space:]]+/)
        if (arr[1] != "") {
          print arr[1]
        }
      }
    }
  ' "${log_file}" | tail -n 1)"

  if [[ -z "${session_id}" ]]; then
    echo "Error: Could not parse session ID from Codex output." >&2
    echo "Codex output was:" >&2
    cat "${log_file}" >&2
    return 1
  fi

  # Validate session ID format to prevent capturing garbage
  if ! validate_session_id_format "${session_id}"; then
    echo "Error: Extracted session ID '${session_id}' does not match expected format." >&2
    echo "Expected format: alphanumeric with hyphens/underscores/periods, 3-128 characters." >&2
    echo "Codex output was:" >&2
    cat "${log_file}" >&2
    return 1
  fi

  printf "%s" "${session_id}"
}

compute_diff_signature() {
  {
    git status --porcelain --untracked-files=all
    # Handle empty repositories where HEAD doesn't exist yet
    git diff --binary HEAD 2>/dev/null || echo "# empty repository"
  } | git hash-object --stdin
}

is_uncommitted_review_preset() {
  local preset
  preset="$(to_lowercase "${REVIEW_PRESET}")"
  case "${preset}" in
    2|"uncommitted"|"working"|"changes"|"working-tree")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

read_custom_review_instructions() {
  local instructions="${REVIEW_CUSTOM_INSTRUCTIONS}"

  if [[ -n "${REVIEW_CUSTOM_INSTRUCTIONS_FILE}" ]]; then
    if [[ -f "${REVIEW_CUSTOM_INSTRUCTIONS_FILE}" ]]; then
      local file_contents
      file_contents="$(cat "${REVIEW_CUSTOM_INSTRUCTIONS_FILE}")"
      if [[ -n "${instructions}" && -n "${file_contents}" ]]; then
        instructions+=$'\n'
      fi
      instructions+="${file_contents}"
    else
      echo "Warning: REVIEW_CUSTOM_INSTRUCTIONS_FILE='${REVIEW_CUSTOM_INSTRUCTIONS_FILE}' does not exist." >&2
    fi
  fi

  printf "%s" "${instructions}"
}

run_codex_review() {
  local preset="${REVIEW_PRESET}"
  local tmp_output
  tmp_output="$(mktemp)"
  trap 'rm -f "${tmp_output}"' RETURN

  if [[ -z "${preset}" ]]; then
    codex exec --full-auto "/review" 2>&1 | tee "${tmp_output}"
  else
    local normalized
    normalized="$(to_lowercase "${preset}")"
    local selection=""
    local -a extra_inputs=()

    case "${normalized}" in
      1|"pr"|"pr-style"|"branch"|"base"|"baseline"|"review-against-branch")
        selection="1"
        if [[ -z "${REVIEW_BASE_BRANCH}" ]]; then
          echo "Error: REVIEW_BASE_BRANCH must be set when REVIEW_PRESET='${preset}'." >&2
          exit 1
        fi
        extra_inputs+=("${REVIEW_BASE_BRANCH}")
        ;;
      2|"uncommitted"|"working"|"changes"|"working-tree")
        selection="2"
        ;;
      3|"commit"|"sha")
        selection="3"
        if [[ -z "${REVIEW_COMMIT_SHA}" ]]; then
          echo "Error: REVIEW_COMMIT_SHA must be set when REVIEW_PRESET='${preset}'." >&2
          exit 1
        fi
        extra_inputs+=("${REVIEW_COMMIT_SHA}")
        ;;
      4|"custom"|"instructions")
        selection="4"
        local custom_text
        custom_text="$(read_custom_review_instructions)"
        if [[ -z "${custom_text}" ]]; then
          echo "Error: Custom review preset selected but no REVIEW_CUSTOM_INSTRUCTIONS/FILE provided." >&2
          exit 1
        fi
        extra_inputs+=("${custom_text}")
        ;;
      *)
        echo "Warning: unknown REVIEW_PRESET='${preset}'. Falling back to interactive selection." >&2
        codex exec --full-auto "/review" 2>&1 | tee "${tmp_output}"
        normalized=""
        ;;
    esac

    if [[ -n "${normalized}" ]]; then
      {
        printf "%s\n" "${selection}"
        if [[ ${#extra_inputs[@]} -gt 0 ]]; then
          local line
          for line in "${extra_inputs[@]}"; do
            printf "%s\n" "${line}"
          done
        fi
      } | codex exec --full-auto "/review" 2>&1 | tee "${tmp_output}"
    fi
  fi

  LAST_REVIEW_SESSION_ID="$(capture_session_id "${tmp_output}")"

  if [[ -z "${LAST_REVIEW_SESSION_ID}" ]]; then
    echo "Error: Failed to capture Codex session ID from /review output." >&2
    exit 1
  fi
}

apply_codex_fixes() {
  if [[ -z "${LAST_REVIEW_SESSION_ID}" ]]; then
    echo "Error: No Codex session ID available for resume." >&2
    exit 1
  fi

  codex exec --full-auto resume "${LAST_REVIEW_SESSION_ID}" "${APPLY_FIXES_PROMPT}" 2>&1
}

is_ci_environment() {
  # Detect common CI environment variables
  if [[ -n "${CI:-}" ]] || [[ -n "${CONTINUOUS_INTEGRATION:-}" ]] || \
     [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]] || \
     [[ -n "${CIRCLECI:-}" ]] || [[ -n "${TRAVIS:-}" ]] || \
     [[ -n "${JENKINS_URL:-}" ]] || [[ -n "${BUILDKITE:-}" ]]; then
    return 0
  fi
  return 1
}

confirm_codex_deletions() {
  local deleted_before="$1"
  local deleted_after="$2"

  # Identify files deleted during this iteration (present in "after" but not in "before").
  local newly_deleted
  newly_deleted="$(comm -13 \
    <(printf '%s\n' "${deleted_before}" | sed '/^$/d' | sort) \
    <(printf '%s\n' "${deleted_after}" | sed '/^$/d' | sort))"

  if [[ -z "${newly_deleted}" ]]; then
    return 0
  fi

  if [[ "$(to_lowercase "${AUTO_APPROVE_DELETIONS}")" == "true" ]]; then
    echo "AUTO_APPROVE_DELETIONS=true; accepting Codex deletions without prompting."
    return 0
  fi

  # Auto-approve in CI environments with a warning
  if is_ci_environment; then
    echo "Warning: Running in CI environment. Auto-approving Codex file deletions."
    echo "Set AUTO_APPROVE_DELETIONS=false to override this behavior and fail in CI instead."
    echo "Deleted files:"
    echo "${newly_deleted}"
    return 0
  fi

  echo "Codex removed the following tracked files while applying fixes:"
  echo "${newly_deleted}"
  echo "These deletions need your approval before continuing."

  local confirm=""
  local read_status=0
  set +e
  read -r -p "Approve deleting these files? [y/yes/N]: " confirm
  read_status=$?
  set -e
  confirm="$(to_lowercase "${confirm:-}")"

  if [[ "${read_status}" -ne 0 ]]; then
    echo "Warning: No input received (non-interactive stdin). Restoring deletions to be safe."
    echo "To auto-approve deletions in non-interactive mode, set AUTO_APPROVE_DELETIONS=true."
    confirm="n"
  fi

  if [[ "${confirm}" == "y" || "${confirm}" == "yes" ]]; then
    echo "Deletion confirmed by user."
    return 0
  fi

  echo "Restoring deleted files from HEAD and continuing without deleting them."
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    git restore --source=HEAD -- "${file}"
  done <<< "${newly_deleted}"
}

if [[ -n "${COMMIT_RULES_DOC}" ]]; then
  echo "Commit conventions sourced from: ${COMMIT_RULES_DOC}"
fi

RUNNING_UNCOMMITTED_PRESET="false"
if is_uncommitted_review_preset; then
  RUNNING_UNCOMMITTED_PRESET="true"
  echo "Uncommitted-changes review preset selected; skipping clean working tree check."
else
  ensure_clean_worktree
fi

echo "Starting Codex /review autofix loop (max ${MAX_LOOPS} iterations)..."

for ((i=1; i<=MAX_LOOPS; i++)); do
  echo
  echo "=== Codex review iteration ${i} ==="

  start_signature="$(compute_diff_signature)"
  deleted_before_iteration="$(git ls-files --deleted)"
  # 1) Ask Codex to review current changes
  run_codex_review

  # 2) Ask Codex to apply the suggested fixes from the last run
  apply_codex_fixes

  end_signature="$(compute_diff_signature)"

  # 3) Check if Codex actually changed anything
  if [[ "${start_signature}" == "${end_signature}" ]]; then
    echo "No changes from Codex in iteration ${i}."
    echo "Assuming no more issues to fix. Exiting."
    exit 0
  fi

  deleted_after_iteration="$(git ls-files --deleted)"
  confirm_codex_deletions "${deleted_before_iteration}" "${deleted_after_iteration}"

  if [[ "${RUNNING_UNCOMMITTED_PRESET}" == "true" ]]; then
    echo "Codex produced changes in iteration ${i}, but uncommitted-review preset prohibits auto-commits."
    echo "Review the updated working tree and commit manually."
    exit 0
  fi

  echo "Changes detected from Codex; committing..."

  # Check for new untracked files created by Codex before staging
  untracked_files="$(git ls-files --others --exclude-standard)"
  should_include_untracked="${INCLUDE_UNTRACKED}"

  if [[ -n "${untracked_files}" ]] && [[ "${INCLUDE_UNTRACKED}" != "true" ]]; then
    echo "Warning: Codex created new files, but INCLUDE_UNTRACKED=false:"
    echo "${untracked_files}"
    echo "Include these untracked files in the auto-commit?"

    include_untracked_choice=""
    if [[ -t 0 ]]; then
      set +e
      read -r -p "[y/yes/N]: " include_untracked_choice
      set -e
      include_untracked_choice="$(to_lowercase "${include_untracked_choice:-}")"
    else
      echo "Non-interactive shell detected; leaving INCLUDE_UNTRACKED=false. Stage new files manually or rerun with INCLUDE_UNTRACKED=true."
      include_untracked_choice="n"
    fi

    if [[ "${include_untracked_choice}" == "y" || "${include_untracked_choice}" == "yes" ]]; then
      echo "Including untracked files and persisting INCLUDE_UNTRACKED=true for subsequent iterations."
      INCLUDE_UNTRACKED="true"
      should_include_untracked="true"
    else
      echo "Skipping untracked files; set INCLUDE_UNTRACKED=true to auto-include in future runs."
    fi
  fi

  # Stage modified and deleted files (and optionally new files)
  if [[ "${should_include_untracked}" == "true" ]]; then
    git add -A
  else
    git add -u
  fi

  # Double-check we actually staged something (paranoid but safe)
  if git diff --cached --quiet; then
    echo "No staged changes found after staging; stopping."
    exit 0
  fi

  # Generate AI commit message only if needed (template contains %s)
  ai_commit_msg=""
  commit_template="$(get_autofix_commit_template)"
  disable_ai_commit_messages="$(to_lowercase "${DISABLE_AI_COMMIT_MESSAGES}")"
  if [[ "${commit_template}" == *"%s"* ]]; then
    if [[ "${disable_ai_commit_messages}" == "true" ]]; then
      echo "DISABLE_AI_COMMIT_MESSAGES=true; skipping Codex commit message API call."
      ai_commit_msg="summary unavailable (AI commit messages disabled)"
    else
      echo "Generating AI commit message (set DISABLE_AI_COMMIT_MESSAGES=true to skip Codex API calls)..."
      ai_commit_msg="$(generate_ai_commit_message)"
    fi
    ai_commit_msg="$(sanitize_commit_summary "${ai_commit_msg}")"
  else
    echo "Using commit message template without summary placeholder (skipping AI generation)."
  fi

  # Use resolve_commit_message to respect templates, passing AI msg as summary
  git commit -m "$(resolve_commit_message "${i}" "${ai_commit_msg}" "${commit_template}")"
  echo "Committed Codex fixes for iteration ${i}."
done


echo
echo "Reached MAX_LOOPS=${MAX_LOOPS} with Codex still making changes or suggestions."
echo "Review the repo manually to ensure everything looks good."
