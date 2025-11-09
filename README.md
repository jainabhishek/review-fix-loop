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
| `AUTOFIX_COMMIT_MESSAGE` | `chore(review): codex /review autofix iteration %d` | Commit message template (`%d` = iteration number) |
| `COMMIT_RULES_DOC` | - | Path to doc defining `autofix_commit_message:` |

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
