# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an automated bash script that iteratively runs Codex code reviews and applies fixes until no more issues are found. The main script (`review-fix.sh`) integrates with the Codex CLI to create a review-fix-commit loop.

## Key Scripts

- `review-fix.sh` - Main automation script that runs the review-fix loop
- `test-review-fix.sh` - Comprehensive test suite with mock and real modes

## Running Tests

```bash
# Run tests in mock mode (tests logic without Codex API calls)
./test-review-fix.sh --mock

# Run tests with real Codex commands (requires Codex CLI, makes API calls)
./test-review-fix.sh --real
```

The test suite validates all 4 review presets and commit message resolution. Mock mode uses simulated Codex responses to test script logic without API costs.

## Script Architecture

### Core Loop (review-fix.sh)

The script follows this execution flow:

1. **Validation Phase**: Ensures clean working tree (unless using uncommitted preset)
2. **Review Loop** (max iterations controlled by `MAX_LOOPS`):
   - Runs `codex exec --full-auto "/review"` with preset configuration
   - Captures session ID from output using `capture_session_id()`
   - Resumes session to apply fixes: `codex exec --full-auto resume <session-id>`
   - Computes diff signature using `git hash-object` on combined status + diff
   - If changes detected: stages all files and commits with resolved message
   - If no changes detected: exits successfully
3. **Exit Conditions**: No changes detected, max iterations reached, or uncommitted preset completes

### Diff Detection Mechanism

The script uses `compute_diff_signature()` to hash the combined output of `git status --porcelain` and `git diff --binary HEAD`. This prevents empty commits and detects when Codex has stopped making changes.

### Review Presets

The script supports 4 review modes (configured via `REVIEW_PRESET`):

1. **Branch/PR Review** (`1`, `pr`, `branch`, `base`) - Requires `REVIEW_BASE_BRANCH`
2. **Uncommitted Changes** (`2`, `uncommitted`, `working`, `changes`) - Reviews working tree, skips auto-commits
3. **Specific Commit** (`3`, `commit`, `sha`) - Requires `REVIEW_COMMIT_SHA`
4. **Custom Instructions** (`4`, `custom`, `instructions`) - Requires `REVIEW_CUSTOM_INSTRUCTIONS` or `REVIEW_CUSTOM_INSTRUCTIONS_FILE`

Preset selection uses case-insensitive matching via `to_lowercase()` function. Inputs are piped to Codex using process substitution to automate preset selection.

### Commit Message Resolution

The `resolve_commit_message()` function has a 3-tier precedence:

1. `AUTOFIX_COMMIT_MESSAGE` environment variable (highest priority)
2. `autofix_commit_message:` field extracted from `COMMIT_RULES_DOC` file using awk
3. Default: `"chore(review): codex /review autofix iteration %d"`

Template uses printf-style `%d` placeholder for iteration number.

## Environment Variables

Core configuration:
- `MAX_LOOPS` - Maximum iterations (default: 10)
- `CODEX_MODEL` - Codex model to use (default: gpt-5-codex-high)
- `AUTOFIX_COMMIT_MESSAGE` - Custom commit message template with `%d` for iteration; `%s` (changes summary) is optional and will be appended if missing
- `COMMIT_RULES_DOC` - Path to file defining `autofix_commit_message:`
- `APPLY_FIXES_PROMPT` - Prompt text passed when resuming Codex sessions
- `INCLUDE_UNTRACKED` - Include untracked files (`true` uses `git add -A`)
- `AUTO_APPROVE_DELETIONS` - Accept Codex deletions without prompting (helpful in CI)

Preset configuration:
- `REVIEW_PRESET` - Review mode (1-4 or named preset)
- `REVIEW_BASE_BRANCH` - Required for preset 1
- `REVIEW_COMMIT_SHA` - Required for preset 3
- `REVIEW_CUSTOM_INSTRUCTIONS` - Inline instructions for preset 4
- `REVIEW_CUSTOM_INSTRUCTIONS_FILE` - File path for preset 4 instructions

## Testing Architecture

The test script (`test-review-fix.sh`) creates isolated test repositories in `/tmp/review-fix-test-$$`. Each test:

1. Creates a fresh git repository with proper user config
2. Sets up the specific scenario (branches, commits, uncommitted files)
3. Injects mock Codex binary into PATH (in mock mode)
4. Runs review-fix.sh with appropriate environment variables
5. Validates expected behavior from output logs

Mock Codex simulation:
- Returns fake session IDs (e.g., `mock-session-12345`)
- Simulates file modifications by appending `// Fixed issue` to test files
- Reads piped preset selections to validate input handling

## Important Implementation Details

- Script uses `set -euo pipefail` for strict error handling
- Session ID captured via awk pattern matching: `/session id:/ {print $3}`
- Uncommitted preset detected via `is_uncommitted_review_preset()` helper
- Custom instructions can be combined from both inline and file sources
- The script validates required variables per preset and exits early if missing
- Git operations use `--porcelain` and `--binary` flags for reliable parsing
