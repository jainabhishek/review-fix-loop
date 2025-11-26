# Verification Plan for Review-Fix-Loop Test Failures

## Problem Statement
The test suite (`test-review-fix.sh --mock`) is failing with 4 out of 5 tests failing. The failures are blocking validation of the review-fix automation script.

## Identified Issues

### Issue 1: Git Commit Signing Failures in Test Environments
**Symptom:**
```
Error: signing failed: Signing failed: signing operation failed: signing server returned status 400: {"type":"error","error":{"type":"invalid_request_error","message":"source: Field required"}}
fatal: failed to write commit object
```

**Root Cause:** Test repositories inherit global git config including `commit.gpgsign=true`, but the signing server isn't configured for test environments.

**Expected Behavior:** Test repositories should successfully create commits without attempting to sign them.

**Verification Criteria:**
- [ ] Test repositories can create commits without signing errors
- [ ] `git commit` succeeds in test setup
- [ ] All preset tests can initialize their test repositories

### Issue 2: Mock Codex Binary Detected as Uncommitted Changes
**Symptom:**
```
Working tree has uncommitted or untracked changes. Please commit or stash them before running this script.
```

**Root Cause:** Although mock codex scripts are created in separate `bin` directories, they may still be within the git repository working tree, causing them to be detected as untracked files.

**Expected Behavior:** Mock codex binaries should not interfere with git status checks.

**Verification Criteria:**
- [ ] Mock codex binaries are created outside the test git repository
- [ ] `git status --porcelain` returns empty after test setup (for non-uncommitted presets)
- [ ] Tests pass the clean worktree check

### Issue 3: compute_diff_signature() Fails on Empty Repositories
**Symptom:**
```
fatal: ambiguous argument 'HEAD': unknown revision or path not in the working tree.
Use '--' to separate paths from revisions, like this:
'git <command> [<revision>...] -- [<file>...]'
```

**Root Cause:** The `compute_diff_signature()` function in `review-fix.sh:75-80` uses `git diff --binary HEAD` which fails when the repository has no commits yet (HEAD doesn't exist).

**Expected Behavior:** The diff signature computation should work in repositories at any stage, including empty repositories.

**Verification Criteria:**
- [ ] `compute_diff_signature()` succeeds in a newly initialized git repository with no commits
- [ ] `compute_diff_signature()` succeeds in a repository with one commit
- [ ] `compute_diff_signature()` correctly detects changes vs no changes

## Verification Strategy

### Phase 1: Create Targeted Unit Tests
Create `verify-fixes.sh` with focused tests for each issue:

1. **Test: Git commit creation in test environment**
   - Create test repo with commit signing disabled
   - Verify commits can be created
   - Verify git config is set correctly

2. **Test: Mock codex isolation**
   - Create test repo structure
   - Create mock codex in separate directory
   - Verify mock is not in git working tree
   - Verify PATH includes mock directory

3. **Test: Diff signature in edge cases**
   - Test on empty repo (no commits)
   - Test on repo with one commit and no changes
   - Test on repo with uncommitted changes
   - Verify signature changes when files change

### Phase 2: Implement Fixes Iteratively
For each issue:
1. Run verification test (should fail)
2. Implement minimal fix
3. Re-run verification test (should pass)
4. Run full test suite to ensure no regressions

### Phase 3: Final Validation
1. Run complete test suite with `./test-review-fix.sh --mock`
2. Verify all 5 tests pass
3. Verify no new errors introduced

## Success Criteria

All of the following must be true:
- [ ] `verify-fixes.sh` passes all targeted verification tests
- [ ] `test-review-fix.sh --mock` passes all 5 tests (5 passed, 0 failed)
- [ ] No git signing errors in test output
- [ ] No "uncommitted changes" errors in test output (except for preset 2 which expects them)
- [ ] No "ambiguous argument 'HEAD'" errors in test output

## Implementation Order

1. **First**: Fix git commit signing (Issue 1)
   - Most fundamental - blocks test setup
   - Changes: `test-review-fix.sh` setup function

2. **Second**: Fix compute_diff_signature (Issue 3)
   - Affects core functionality
   - Changes: `review-fix.sh` compute_diff_signature function

3. **Third**: Fix mock codex isolation (Issue 2)
   - Already partially implemented, needs verification
   - Changes: `test-review-fix.sh` mock creation (may not need changes)

## Rollback Plan

If fixes introduce regressions:
- Each fix is isolated to specific functions
- Git history allows reverting individual commits
- Verification tests can be run independently to identify which fix caused regression
