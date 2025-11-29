# Codex Review-Fix Loop

An automated bash script that iteratively runs Codex code reviews and applies fixes until no more issues are found.

## Overview

This script automates the code review and fix cycle by:
1. Running Codex `/review` to analyze your code
2. Automatically applying suggested fixes
3. Committing the changes
4. Repeating until no more issues are detected or max iterations reached

## Prerequisites

- [Codex CLI](https://codex.com) installed and configured
- Git repository
- Bash shell

## Installation

```bash
# Clone or download the script
curl -O https://raw.githubusercontent.com/YOUR_USERNAME/review-fix-loop/main/review-fix.sh
chmod +x review-fix.sh
```

## Basic Usage

```bash
# Run with default settings (10 iterations max)
./review-fix.sh

# Run with custom iteration limit
MAX_LOOPS=20 ./review-fix.sh
```

## Configuration

Configure the script using environment variables:

### Core Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_LOOPS` | `10` | Maximum review/fix iterations |
| `CODEX_MODEL` | `gpt-5-codex-high` | Codex model to use |
| `AUTOFIX_COMMIT_MESSAGE` | `chore(review): %s (iteration %d)` | Commit message template (`%d` = iteration number; `%s` = summary, optional) |
| `COMMIT_RULES_DOC` | - | Path to doc defining `autofix_commit_message:` |
| `APPLY_FIXES_PROMPT` | `Apply the fixes suggested above` | Prompt passed to Codex when resuming a session |
| `INCLUDE_UNTRACKED` | `false` | Include untracked files in auto-commits (`true` uses `git add -A` to capture deletions and new files) |
| `DISABLE_AI_COMMIT_MESSAGES` | `false` | Skip Codex API calls for commit messages (forces template-only commits) |
| `AI_COMMIT_MAX_DIFF_BYTES` | `50000` | Max diff size before falling back to a simple commit message |
| `AUTO_APPROVE_DELETIONS` | `false` | Automatically accept Codex deletions without prompting (useful for CI) |

### Review Presets

| Variable | Options | Description |
|----------|---------|-------------|
| `REVIEW_PRESET` | See below | Type of review to perform |
| `REVIEW_BASE_BRANCH` | - | Required for PR-style reviews (preset 1) |
| `REVIEW_COMMIT_SHA` | - | Required for commit reviews (preset 3) |
| `REVIEW_CUSTOM_INSTRUCTIONS` | - | Custom review instructions (preset 4) |
| `REVIEW_CUSTOM_INSTRUCTIONS_FILE` | - | File containing custom instructions |

#### Review Preset Options

1. **PR/Branch Review** (`1`, `pr`, `branch`, `base`)
   ```bash
   REVIEW_PRESET=pr REVIEW_BASE_BRANCH=main ./review-fix.sh
   ```

2. **Uncommitted Changes** (`2`, `uncommitted`, `working`, `changes`)
   ```bash
   REVIEW_PRESET=uncommitted ./review-fix.sh
   ```
   Note: Skips auto-commits; review and commit manually

3. **Specific Commit** (`3`, `commit`, `sha`)
   ```bash
   REVIEW_PRESET=commit REVIEW_COMMIT_SHA=abc123 ./review-fix.sh
   ```

4. **Custom Instructions** (`4`, `custom`, `instructions`)
   ```bash
   REVIEW_PRESET=custom REVIEW_CUSTOM_INSTRUCTIONS="Focus on performance" ./review-fix.sh
   # Or use a file:
   REVIEW_PRESET=custom REVIEW_CUSTOM_INSTRUCTIONS_FILE=./review-rules.md ./review-fix.sh
   ```

## Examples

### Review and fix uncommitted changes
```bash
REVIEW_PRESET=uncommitted ./review-fix.sh
```

### Review changes against main branch
```bash
REVIEW_PRESET=pr REVIEW_BASE_BRANCH=main ./review-fix.sh
```

### Custom commit messages
```bash
AUTOFIX_COMMIT_MESSAGE="fix: auto-fix iteration %d" ./review-fix.sh
```

### Use commit rules from a file
Create a `commit-rules.md` file:
```markdown
autofix_commit_message: fix(codex): iteration %d auto-fixes
```

Then run:
```bash
COMMIT_RULES_DOC=./commit-rules.md ./review-fix.sh
```

### Extended loop with custom model
```bash
MAX_LOOPS=25 CODEX_MODEL=gpt-5-codex-high ./review-fix.sh
```

## Behavior Notes

### Untracked Files Auto-Inclusion

- When `INCLUDE_UNTRACKED=true`, the script stages with `git add -A` so Codex-created deletions and new files are both captured.
- When `INCLUDE_UNTRACKED=false` and Codex creates new files, the script prompts to include them; if you accept, it flips `INCLUDE_UNTRACKED` to `true` for subsequent iterations. In non-interactive shells, new files are left untracked and must be staged manually.

### File Deletion Approval

The script asks for user confirmation before committing file deletions made by Codex, with these behaviors:

- **Interactive Mode** (default): Prompts user to approve deletions with `[y/N]`
- **CI Environments**: Auto-approves deletions with a warning (detects GitHub Actions, GitLab CI, CircleCI, Travis, Jenkins, Buildkite)
- **Non-Interactive stdin**: Defaults to restoring deletions for safety
- **Override**: Set `AUTO_APPROVE_DELETIONS=true` to auto-approve in any environment

To explicitly control behavior in CI:
```bash
# Auto-approve deletions (recommended for CI)
AUTO_APPROVE_DELETIONS=true ./review-fix.sh

# Force interactive prompts (will fail in CI)
AUTO_APPROVE_DELETIONS=false ./review-fix.sh
```

### AI-Generated Commit Messages

The script uses Codex API to generate commit messages when:

- No custom `AUTOFIX_COMMIT_MESSAGE` template is set, OR
- Template contains `%s` placeholder for AI-generated summary

**Limitations:**

- Requires authenticated Codex CLI access
- Skipped for diffs larger than ~50KB (uses fallback message)
- Falls back to `"chore(review): codex autofix [modified: files]"` on API errors

To avoid AI commit message generation:

```bash
# Use a fixed template without %s placeholder
AUTOFIX_COMMIT_MESSAGE="fix: auto-review iteration %d" ./review-fix.sh

# Or disable Codex commit generation entirely
DISABLE_AI_COMMIT_MESSAGES=true ./review-fix.sh

# For custom templates with summaries
AUTOFIX_COMMIT_MESSAGE="feat: codex fixes %d (%s)" ./review-fix.sh
```

To control API size limits for commit generation:

```bash
AI_COMMIT_MAX_DIFF_BYTES=75000 ./review-fix.sh
```

## How It Works

1. **Clean State Check**: Ensures working tree is clean (unless using uncommitted preset)
2. **Review Loop**:
   - Runs Codex `/review` on the specified scope
   - Captures the session ID
   - Resumes the session to apply fixes
   - Computes diff signature to detect changes
   - If changes detected, commits them
   - Repeats until no changes or max iterations reached
3. **Exit Conditions**:
   - No changes detected (all issues fixed)
   - Max iterations reached
   - Uncommitted preset completed one iteration

## Diff Signature

The script uses `git hash-object` on combined status and diff output to detect if Codex actually made changes. This prevents empty commits and unnecessary iterations.

## Safety Features

- Requires clean working tree before starting (configurable)
- Validates required environment variables
- Checks for staged changes before committing
- Prevents infinite loops with `MAX_LOOPS`
- Clear error messages and warnings
- Session ID format validation to prevent garbage capture
- Format string sanitization in commit messages

### Security Considerations

**Custom Review Instructions**: When using preset 4 with `REVIEW_CUSTOM_INSTRUCTIONS` or `REVIEW_CUSTOM_INSTRUCTIONS_FILE`, the content is passed directly to Codex stdin. While properly quoted, avoid using untrusted or dynamically generated instructions that could contain:

- Shell metacharacters in filenames or paths
- Malicious code snippets for Codex to evaluate
- Instructions that could manipulate Codex into dangerous actions

**Example safe usage:**

```bash
# Safe - controlled content
REVIEW_CUSTOM_INSTRUCTIONS="Focus on performance and security" ./review-fix.sh

# Safe - from trusted file
REVIEW_CUSTOM_INSTRUCTIONS_FILE=./company-review-standards.md ./review-fix.sh
```

**Best practices:**

- Only use trusted sources for custom instructions
- Validate file contents before using `REVIEW_CUSTOM_INSTRUCTIONS_FILE`
- Avoid interpolating user input directly into instructions
- Review Codex-generated changes before pushing to production

## Testing

A comprehensive test script is included to test all 4 review presets and features.

### Running Tests

```bash
# Run tests in mock mode (tests script logic without Codex)
./test-review-fix.sh --mock

# Run tests with real Codex commands (requires Codex CLI and may incur costs)
./test-review-fix.sh --real
```

### What's Tested

The test suite covers:

1. **Preset 1 - Branch/PR Review**: Tests reviewing changes against a base branch
2. **Preset 2 - Uncommitted Changes**: Tests reviewing uncommitted working tree changes
3. **Preset 3 - Specific Commit**: Tests reviewing a specific commit by SHA
4. **Preset 4 - Custom Instructions**: Tests using custom review instructions from a file
5. **Commit Message Resolution**: Tests custom commit message templates

### Mock Mode

Mock mode uses a simulated Codex CLI that:
- Returns fake review results with session IDs
- Simulates applying fixes by modifying files
- Allows testing the script logic without API calls or costs
- Validates all preset configurations and error handling

### Real Mode

Real mode runs actual Codex commands:
- Tests integration with the real Codex CLI
- Validates end-to-end functionality
- **Warning**: Makes real API calls and may incur costs

### Test Output

The test script provides colored output:
- Green: Tests passed
- Red: Tests failed
- Yellow: Warnings
- Blue: Info messages

Example output:
```
[INFO] Running test: Preset 1: Branch/PR Review
[PASS] Preset 1: Branch/PR Review
[INFO] Running test: Preset 2: Uncommitted Changes
[PASS] Preset 2: Uncommitted Changes
...
================================
Test Summary
================================
Passed: 5
Failed: 0
Total:  5
================================
```

## Troubleshooting

### "Working tree has uncommitted or untracked changes"
Either commit/stash your changes or use the uncommitted preset:
```bash
REVIEW_PRESET=uncommitted ./review-fix.sh
```

### "Failed to capture Codex session id"
Ensure Codex CLI is properly installed and the `/review` command works:
```bash
codex exec "/review"
```

### Script exits after first iteration
This usually means Codex found no issues or couldn't apply fixes. Check the Codex output for details.

## License

MIT

## Contributing

Contributions welcome! Please open an issue or pull request.
