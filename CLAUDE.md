# CLAUDE.md - AI Assistant Guide

This document provides comprehensive guidance for AI assistants working with the `review-fix-loop` repository.

## Repository Overview

**Purpose**: An automated bash script system that iteratively runs Codex code reviews and applies fixes until no more issues are found, with integrated GitHub Actions workflows for Claude Code.

**Type**: Shell scripting project with GitHub Actions integration
**Language**: Bash (primary), YAML (workflows)
**Dependencies**: Git, Codex CLI (for production use)

## Repository Structure

```
review-fix-loop/
├── .github/
│   └── workflows/
│       ├── claude-code-review.yml  # PR review automation
│       └── claude.yml              # Interactive @claude assistant
├── README.md                       # User-facing documentation
├── review-fix.sh                   # Core automation script
├── test-review-fix.sh              # Comprehensive test suite
└── CLAUDE.md                       # This file
```

### Key Files

#### `review-fix.sh` (Core Script)
- **Purpose**: Automates the code review/fix cycle
- **Key Functions**:
  - `ensure_clean_worktree()` - Validates git state
  - `resolve_commit_message()` - Handles commit message templating
  - `run_codex_review()` - Executes Codex reviews with preset support
  - `apply_codex_fixes()` - Applies suggested fixes
  - `compute_diff_signature()` - Detects actual changes to prevent empty commits
- **Configuration**: Environment variables (see Configuration section)

#### `test-review-fix.sh` (Test Suite)
- **Purpose**: Validates all script functionality
- **Modes**:
  - `--mock`: Tests without Codex CLI (tests logic)
  - `--real`: Tests with actual Codex CLI (integration testing)
- **Coverage**: All 4 review presets + commit message resolution

#### `.github/workflows/claude-code-review.yml`
- **Trigger**: PR opened/synchronized
- **Purpose**: Automated PR code reviews
- **Action**: Uses `anthropics/claude-code-action@v1`
- **Key Feature**: References this CLAUDE.md for style guidance

#### `.github/workflows/claude.yml`
- **Trigger**: Issue/PR comments, reviews containing `@claude`
- **Purpose**: Interactive assistant for issues and PRs
- **Permissions**: Read-only access to contents, PRs, issues, CI results

## Development Workflows

### Working with the Review-Fix Script

1. **Making Changes**:
   - Always read the script before modifying
   - Preserve existing function signatures
   - Maintain bash strict mode (`set -euo pipefail`)
   - Keep functions focused and single-purpose

2. **Testing Changes**:
   ```bash
   # Test logic without Codex API calls
   ./test-review-fix.sh --mock

   # Full integration test (requires Codex CLI)
   ./test-review-fix.sh --real
   ```

3. **Adding Features**:
   - Update both `review-fix.sh` and `test-review-fix.sh`
   - Add test cases for new functionality
   - Update README.md with usage examples
   - Update this CLAUDE.md if it affects AI workflows

### GitHub Actions Development

1. **Modifying Workflows**:
   - Test locally when possible using `act` or similar tools
   - Use minimal permissions principle
   - Reference official action documentation
   - Validate YAML syntax before committing

2. **Secret Requirements**:
   - `CLAUDE_CODE_OAUTH_TOKEN` - Required for Claude Code Action
   - Set at repository level in GitHub Settings

## Key Conventions

### Bash Scripting Standards

1. **Error Handling**:
   - Always use `set -euo pipefail` at script start
   - Validate inputs before processing
   - Provide clear error messages to stderr
   - Exit with non-zero codes on errors

2. **Variable Naming**:
   - UPPERCASE for environment/configuration variables
   - lowercase for local variables
   - Use descriptive names (e.g., `commit_sha` not `cs`)

3. **Functions**:
   - Use verb_noun naming (e.g., `ensure_clean_worktree`)
   - Document complex logic with comments
   - Keep functions under 50 lines when possible
   - One responsibility per function

4. **Quoting**:
   - Always quote variables: `"${variable}"`
   - Use `$()` for command substitution, not backticks
   - Quote array expansions: `"${array[@]}"`

### Commit Message Conventions

Based on recent commits, this repository uses:

**Format**: `<type>: <description>` or `<type>(<scope>): <description>`

**Examples from History**:
- `"Claude Code Review workflow"`
- `"Claude PR Assistant workflow"`
- `Ensure tests run fully and enforce commit message template`
- `Add comprehensive test script for all review presets`
- `Initial commit: Add review-fix automation script and documentation`

**Types Used**:
- Direct descriptions (simple, clear)
- Conventional commits style when appropriate

**For Autofix Commits**:
- Default: `chore(review): codex /review autofix iteration %d`
- Customizable via `AUTOFIX_COMMIT_MESSAGE` or `COMMIT_RULES_DOC`

### Code Review Standards

When reviewing code in this repository:

1. **Script Safety**:
   - Verify proper error handling
   - Check for potential command injection
   - Validate input sanitization
   - Ensure quotes around variables

2. **Test Coverage**:
   - All new features need test cases
   - Both mock and real modes should work
   - Test error conditions, not just happy paths

3. **Documentation**:
   - Update README.md for user-facing changes
   - Update CLAUDE.md for AI workflow changes
   - Add inline comments for complex logic
   - Keep examples up-to-date

4. **GitHub Actions**:
   - Minimize permissions
   - Use pinned action versions (`@v1`, `@v4`)
   - Validate YAML structure
   - Test conditional logic

## Configuration Reference

### Environment Variables (review-fix.sh)

| Variable | Default | Purpose | Required |
|----------|---------|---------|----------|
| `MAX_LOOPS` | `10` | Maximum review iterations | No |
| `CODEX_MODEL` | `gpt-5-codex-high` | Model to use | No |
| `AUTOFIX_COMMIT_MESSAGE` | `chore(review): codex /review autofix iteration %d` | Commit template | No |
| `COMMIT_RULES_DOC` | - | Path to commit rules file | No |
| `REVIEW_PRESET` | - | Review type (1-4) | No |
| `REVIEW_BASE_BRANCH` | - | Base branch for PR reviews | Preset 1 |
| `REVIEW_COMMIT_SHA` | - | Commit SHA to review | Preset 3 |
| `REVIEW_CUSTOM_INSTRUCTIONS` | - | Custom review text | Preset 4 |
| `REVIEW_CUSTOM_INSTRUCTIONS_FILE` | - | Custom review file | Preset 4 |

### Review Presets

1. **PR/Branch Review** (`pr`, `branch`, `1`):
   - Reviews changes against base branch
   - Requires: `REVIEW_BASE_BRANCH`

2. **Uncommitted Changes** (`uncommitted`, `working`, `2`):
   - Reviews working tree changes
   - Skips auto-commits

3. **Specific Commit** (`commit`, `sha`, `3`):
   - Reviews single commit
   - Requires: `REVIEW_COMMIT_SHA`

4. **Custom Instructions** (`custom`, `instructions`, `4`):
   - Custom review criteria
   - Requires: `REVIEW_CUSTOM_INSTRUCTIONS` or `REVIEW_CUSTOM_INSTRUCTIONS_FILE`

## Testing Guidelines

### Running Tests

```bash
# Quick validation (recommended for PRs)
./test-review-fix.sh --mock

# Full integration (before releases)
./test-review-fix.sh --real
```

### Test Coverage

The test suite validates:
- ✅ Preset 1: Branch/PR reviews
- ✅ Preset 2: Uncommitted changes
- ✅ Preset 3: Specific commit
- ✅ Preset 4: Custom instructions
- ✅ Commit message resolution
- ✅ Error handling
- ✅ Git operations

### Writing New Tests

When adding tests to `test-review-fix.sh`:

1. **Structure**:
   ```bash
   test_feature_name() {
     local test_dir="${TEST_ROOT}/feature-name/repo"
     local mock_bin_dir="${TEST_ROOT}/feature-name/bin"

     # Setup mock if needed
     if [[ "${TEST_MODE}" == "--mock" ]]; then
       # Create mock codex
     fi

     # Setup test environment
     setup_test_env "${test_dir}"

     # Test logic
     # ...

     # Validate results
     if grep -q "expected output" "${output_log}"; then
       log_success "Test passed"
       return 0
     else
       log_error "Test failed"
       return 1
     fi
   }
   ```

2. **Best Practices**:
   - Use isolated test directories
   - Clean working tree for most tests
   - Capture output to log files
   - Provide clear pass/fail messages
   - Support both mock and real modes

## GitHub Actions Integration

### Claude Code Review Workflow

**File**: `.github/workflows/claude-code-review.yml`

**When to Modify**:
- Changing review criteria
- Adjusting trigger conditions
- Modifying allowed tools
- Updating permissions

**Key Configuration**:
```yaml
claude_args: '--allowed-tools "Bash(gh issue view:*),Bash(gh pr comment:*),..."'
```

**Prompt Customization**:
The workflow references this CLAUDE.md file for guidance. Update the prompt in the workflow to change review focus.

### Interactive Claude Workflow

**File**: `.github/workflows/claude.yml`

**Trigger**: Comments/reviews containing `@claude`

**Common Use Cases**:
- Answering questions about PRs
- Explaining implementation details
- Suggesting improvements
- Debugging issues

## Common Tasks for AI Assistants

### Task: Review a Pull Request

1. Check workflow files reference correct CLAUDE.md
2. Review changes against bash scripting standards
3. Verify test coverage for changes
4. Check commit message format
5. Validate documentation updates
6. Leave constructive feedback via `gh pr comment`

### Task: Add New Feature to review-fix.sh

1. Read current implementation
2. Plan changes (consider using TodoWrite tool)
3. Modify `review-fix.sh` with new functionality
4. Add corresponding test in `test-review-fix.sh`
5. Update README.md usage examples
6. Update CLAUDE.md if workflow changes
7. Test with `./test-review-fix.sh --mock`
8. Commit with clear message
9. Create PR if on feature branch

### Task: Debug Script Issues

1. Read error output carefully
2. Check recent changes with `git log`
3. Review relevant functions in script
4. Test in isolation if possible
5. Use mock mode for faster iteration
6. Verify fix with both mock and real tests

### Task: Update Documentation

1. Identify what changed (code, workflow, usage)
2. Update README.md for user-facing changes
3. Update CLAUDE.md for AI workflow changes
4. Update inline comments if logic changed
5. Verify examples are accurate
6. Test documented commands work

## Best Practices for AI Assistants

### When Working with This Repository

1. **Always Read Before Modifying**:
   - Use Read tool on relevant files
   - Understand current implementation
   - Check test coverage

2. **Maintain Consistency**:
   - Follow existing patterns
   - Use established naming conventions
   - Match commit message style

3. **Test Thoroughly**:
   - Run mock tests for quick validation
   - Verify changes don't break existing tests
   - Add new tests for new features

4. **Document Changes**:
   - Update relevant documentation
   - Add comments for complex logic
   - Keep examples current

5. **Respect Safety Features**:
   - Don't bypass error handling
   - Maintain clean working tree requirements
   - Preserve input validation

### Code Review Checklist

When reviewing changes:

- [ ] Bash strict mode preserved (`set -euo pipefail`)
- [ ] Variables properly quoted
- [ ] Error messages go to stderr
- [ ] Functions have single responsibility
- [ ] Tests updated/added
- [ ] Documentation updated
- [ ] Commit message follows conventions
- [ ] No hardcoded paths or credentials
- [ ] Input validation present
- [ ] Exit codes appropriate

## Troubleshooting Guide

### Common Issues

**Issue**: Tests fail in mock mode
- **Cause**: Mock codex script path issues
- **Solution**: Check PATH manipulation in test functions

**Issue**: Working tree not clean
- **Cause**: Uncommitted changes present
- **Solution**: Use `REVIEW_PRESET=uncommitted` or commit changes

**Issue**: Session ID not captured
- **Cause**: Codex output format changed or command failed
- **Solution**: Check `capture_session_id()` regex pattern

**Issue**: GitHub Action fails with permissions error
- **Cause**: Missing or incorrect permissions
- **Solution**: Verify `permissions` block in workflow YAML

## Reference Links

- [Codex CLI Documentation](https://codex.com) (when available)
- [Claude Code Action](https://github.com/anthropics/claude-code-action)
- [Bash Best Practices](https://google.github.io/styleguide/shellguide.html)
- [Conventional Commits](https://www.conventionalcommits.org/)

## Version History

- **2025-11-22**: Initial CLAUDE.md created with comprehensive repository documentation
- Previous commits focused on core functionality and testing infrastructure

---

**Note**: This document should be updated whenever significant changes are made to:
- Repository structure
- Development workflows
- Coding conventions
- GitHub Actions configuration
- Testing procedures

AI assistants should reference this document when working with the repository and suggest updates when they notice discrepancies.
