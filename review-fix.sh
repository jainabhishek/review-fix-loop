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

LAST_REVIEW_SESSION_ID=""

# Validate MAX_LOOPS is a positive integer
if ! [[ "${MAX_LOOPS}" =~ ^[0-9]+$ ]] || [[ "${MAX_LOOPS}" -lt 1 ]]; then
  echo "Error: MAX_LOOPS must be a positive integer, got '${MAX_LOOPS}'." >&2
  exit 1
fi

# Check if Codex CLI is installed
if ! command -v codex &> /dev/null; then
  echo "Error: 'codex' command not found. Please install Codex CLI." >&2
  echo "Visit https://codex.com for installation instructions." >&2
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

resolve_commit_message() {
  local iteration="$1"
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
    template="chore(review): codex /review autofix iteration %d"
  fi

  printf "${template}" "${iteration}"
}

capture_session_id() {
  local log_file="$1"
  local session_id
  session_id="$(awk '/session id:/ {print $3}' "${log_file}" | tail -n 1)"

  if [[ -z "${session_id}" ]]; then
    echo "Error: Could not parse session ID from Codex output." >&2
    echo "Codex output was:" >&2
    cat "${log_file}" >&2
    return 1
  fi

  printf "%s" "${session_id}"
}

compute_diff_signature() {
  {
    git status --porcelain --untracked-files=all
    git diff --binary HEAD
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

  if [[ "${RUNNING_UNCOMMITTED_PRESET}" == "true" ]]; then
    echo "Codex produced changes in iteration ${i}, but uncommitted-review preset prohibits auto-commits."
    echo "Review the updated working tree and commit manually."
    exit 0
  fi

  echo "Changes detected from Codex; committing..."

  # Stage modified and deleted files
  git add -u

  # Check for new untracked files created by Codex
  untracked_files="$(git ls-files --others --exclude-standard)"
  if [[ -n "${untracked_files}" ]]; then
    echo "Warning: Codex created new files that will not be auto-committed:" >&2
    echo "${untracked_files}" >&2
    echo "Review these files and commit manually if needed." >&2
  fi

  # Double-check we actually staged something (paranoid but safe)
  if git diff --cached --quiet; then
    echo "No staged changes found after staging; stopping."
    exit 0
  fi

  git commit -m "$(resolve_commit_message "${i}")"
  echo "Committed Codex fixes for iteration ${i}."
done


echo
echo "Reached MAX_LOOPS=${MAX_LOOPS} with Codex still making changes or suggestions."
echo "Review the repo manually to ensure everything looks good."
