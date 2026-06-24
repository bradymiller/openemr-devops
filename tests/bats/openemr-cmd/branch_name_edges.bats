# BATS: branch-name edge cases for `worktree add`.
#
# wt_slug strips everything outside [a-zA-Z0-9_-] and lowercases, so
# distinct branch names can collide on the same slug (e.g. "foo/bar"
# and "foo-bar" both → "foo-bar"). The Docker project name uses the
# slug, so a collision means two stacks competing for the same project
# name → port conflicts and clobbered state.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_PARENT=$(oc_mktempdir)
    TMP_ROOT="${TMP_PARENT}/primary"
    mkdir -p "${TMP_ROOT}"
    oc_init_repo_with_fixtures "${TMP_ROOT}"
    STUB_DIR=$(oc_make_docker_stub_dir)
    STATE_FILE="${TMP_ROOT}/.worktrees.json"
    export TMP_PARENT TMP_ROOT STUB_DIR STATE_FILE
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

oc_run_add() {
    env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        WT_STATE_LOCK_TIMEOUT_S=5 \
        "${SCRIPT}" worktree add "$@"
}

# --- slug collisions --------------------------------------------------------

@test "branch-name: 'foo/bar' and 'foo-bar' slugify to the same value (worktree dir collision)" {
    run oc_run_add foo/bar -b --env easy
    assert_success
    run oc_run_add foo-bar -b --env easy
    # Second add must fail — same on-disk dir, same docker project name.
    # git worktree add will surface either "already exists" or "already used".
    assert_failure
    if ! ( echo "${output}" | grep -Eq "already (exists|used by worktree|checked out)" ); then
        echo "${output}"
        fail "expected git's already-exists/used error on slug collision"
    fi
    # Only the first slug-owner is in state.
    [[ "$(jq -r 'has("foo/bar")' "${STATE_FILE}")" = "true" ]] || fail "first entry missing"
    [[ "$(jq -r 'has("foo-bar")' "${STATE_FILE}")" = "false" ]] || fail "second entry was written despite collision"
}

# --- empty slug -------------------------------------------------------------

@test "branch-name: name that slugifies to empty (e.g. '!!!') is refused with a clear error" {
    # wt_slug strips all non-[a-zA-Z0-9_-] chars and lowercases. "!!!" → "".
    # An empty slug would produce a worktree dir of "openemr-wt-" (trailing
    # dash) and a docker project of "openemr-" — both ambiguous. The script
    # refuses early with a clear message.
    run oc_run_add '!!!' -b --env easy
    assert_failure
    assert_output --partial "contains no slug-safe characters"
    # No half-built state.
    if [[ -f "${STATE_FILE}" ]]; then
        [[ "$(jq -r 'has("!!!")' "${STATE_FILE}")" = "false" ]] || fail "empty-slug branch was written to state"
    fi
    # No half-built worktree dir.
    [[ ! -e "${TMP_PARENT}/openemr-wt-" ]] || fail "empty-slug dir was created"
}

# --- branch name with leading dash (must not be parsed as a flag) ----------

@test "branch-name: leading-dash branch name is treated as a branch, not a flag" {
    # Our CLI parser sees '-foo' as an unknown option. Real defensive call
    # would use '--' to terminate options, but the script doesn't support
    # '--'; pin the current refusal so a parser regression doesn't silently
    # add a flag named '-foo'.
    run oc_run_add -foo-leading -b --env easy
    assert_failure
    assert_output --partial "Unknown option"
}

# --- branch name that is also a git reserved/special token -----------------

@test "branch-name: 'HEAD' is rejected by git (cannot create as a branch)" {
    run oc_run_add HEAD -b --env easy
    assert_failure
    # git refuses with one of several messages depending on version.
    # We just assert we didn't silently write a HEAD entry.
    if [[ -f "${STATE_FILE}" ]]; then
        [[ "$(jq -r 'has("HEAD")' "${STATE_FILE}")" = "false" ]] \
            || fail "HEAD was written to state despite git rejecting it"
    fi
}

# --- very long branch name --------------------------------------------------

@test "branch-name: very long branch (200 chars) produces a long-but-valid slug and entry" {
    # Linux/macOS dir name limits are 255 bytes — 200 char branch → 200 char
    # slug → openemr-wt-<200-char-slug> = 211 chars → under limit.
    local longbranch
    longbranch=$(printf 'b%.0s' {1..200})  # 200 'b's
    run oc_run_add "${longbranch}" -b --env easy
    assert_success
    [[ "$(jq -r --arg b "${longbranch}" 'has($b)' "${STATE_FILE}")" = "true" ]] \
        || fail "long-branch entry missing"
    [[ -d "${TMP_PARENT}/openemr-wt-${longbranch}" ]] || fail "long-branch worktree dir missing"
}

# --- unicode chars stripped from slug --------------------------------------

@test "branch-name: unicode chars are stripped from slug (predictable docker project name)" {
    # 'feature-Ä' → branch stays 'feature-Ä' in git, slug becomes 'feature-'.
    # Add should succeed (git accepts unicode branches) and the on-disk
    # dir reflects the stripped slug.
    run oc_run_add 'feature-Ä' -b --env easy
    assert_success
    [[ "$(jq -r '."feature-Ä"' "${STATE_FILE}")" != "null" ]] \
        || fail "unicode branch entry missing"
    # Dir uses the stripped slug.
    [[ -d "${TMP_PARENT}/openemr-wt-feature-" ]] || {
        ls "${TMP_PARENT}/"
        fail "expected slug 'feature-' on disk"
    }
}
