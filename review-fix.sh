#!/usr/bin/env bash
set -euo pipefail

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

LAST_REVIEW_SESSION_ID=""

ensure_clean_worktree() {
  local status_output
  status_output="$(git status --porcelain --untracked-files=all)"
  if [[ -n "${status_output}" ]]; then
    echo "Working tree has uncommitted or untracked changes. Please commit or stash them before running this script." >&2
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

  printf "%s" "$(printf "${template}" "${iteration}")"
}

capture_session_id() {
  local log_file="$1"
  awk '/session id:/ {print $3}' "${log_file}" | tail -n 1
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
          echo "REVIEW_BASE_BRANCH must be set when REVIEW_PRESET='${preset}'." >&2
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
          echo "REVIEW_COMMIT_SHA must be set when REVIEW_PRESET='${preset}'." >&2
          exit 1
        fi
        extra_inputs+=("${REVIEW_COMMIT_SHA}")
        ;;
      4|"custom"|"instructions")
        selection="4"
        local custom_text
        custom_text="$(read_custom_review_instructions)"
        if [[ -z "${custom_text}" ]]; then
          echo "Custom review preset selected but no REVIEW_CUSTOM_INSTRUCTIONS/FILE provided." >&2
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
  rm -f "${tmp_output}"

  if [[ -z "${LAST_REVIEW_SESSION_ID}" ]]; then
    echo "Failed to capture Codex session id from /review output." >&2
    exit 1
  fi
}

apply_codex_fixes() {
  if [[ -z "${LAST_REVIEW_SESSION_ID}" ]]; then
    echo "No Codex session id available for resume." >&2
    exit 1
  fi

  codex exec --full-auto resume "${LAST_REVIEW_SESSION_ID}" "Apply the fixes suggested above" 2>&1
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

  git add -A

  # Double-check we actually staged something (paranoid but safe)
  if git diff --cached --quiet; then
    echo "No staged changes found after add -A; stopping."
    exit 0
  fi

  git commit -m "$(resolve_commit_message "${i}")"
  echo "Committed Codex fixes for iteration ${i}."
done


echo
echo "Reached MAX_LOOPS=${MAX_LOOPS} with Codex still making changes or suggestions."
echo "Review the repo manually to ensure everything looks good."
