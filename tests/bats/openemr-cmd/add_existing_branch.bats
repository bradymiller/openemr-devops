# BATS: cmd_worktree_add <branch> (without -b) — check out an existing
# local branch in a new worktree dir.
#
# Without -b, the script calls `git worktree add <dir> <branch>` directly.
# Edge cases driven by git's behavior:
#   - Branch doesn't exist → git fails with a clear "not a valid object name"
#   - Branch is the currently-checked-out HEAD in the PRIMARY repo → git
#     refuses ("already checked out").
#   - Branch is checked out in ANOTHER existing worktree → git refuses
#     ("already used by worktree").
#
# We don't re-validate git's own messages exhaustively; we just pin that
# add fails cleanly with no half-built state.

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

# Create an existing local branch in the primary repo (separate from master).
make_local_branch() {
    local branch=$1
    git -C "${TMP_ROOT}" checkout --quiet -b "${branch}" master
    echo "content-on-${branch}" > "${TMP_ROOT}/${branch}.txt"
    git -C "${TMP_ROOT}" add "${branch}.txt"
    git -C "${TMP_ROOT}" -c user.email=bats@e.com -c user.name=bats \
        -c commit.gpgsign=false \
        commit --quiet -m "init ${branch}"
    git -C "${TMP_ROOT}" checkout --quiet master
}

oc_add() {
    env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        WT_STATE_LOCK_TIMEOUT_S=5 \
        "${SCRIPT}" worktree add "$@"
}

# --- happy path ------------------------------------------------------------

@test "add <existing-branch> (no -b): checks out the existing branch in a new worktree dir" {
    make_local_branch existing-feature
    # Capture the branch's tip SHA so we can verify the worktree HEAD.
    local expected
    expected=$(git -C "${TMP_ROOT}" rev-parse existing-feature)

    run oc_add existing-feature --env easy
    assert_success

    # Worktree dir exists at the expected slug.
    local wt_dir="${TMP_PARENT}/openemr-wt-existing-feature"
    [[ -d "${wt_dir}" ]] || fail "worktree dir missing"
    # HEAD matches the branch tip.
    local actual
    actual=$(git -C "${wt_dir}" rev-parse HEAD)
    [[ "${actual}" = "${expected}" ]] \
        || fail "HEAD is ${actual}, expected ${expected}"
    # State entry created.
    [[ "$(jq -r 'has("existing-feature")' "${STATE_FILE}")" = "true" ]] \
        || fail "state entry missing"
}

# --- error: branch doesn't exist -------------------------------------------

@test "add <nonexistent-branch> (no -b): git fails cleanly, no state" {
    run oc_add ghost-branch --env easy
    assert_failure
    # No state entry written.
    if [[ -f "${STATE_FILE}" ]]; then
        [[ "$(jq -r 'has("ghost-branch")' "${STATE_FILE}")" = "false" ]] \
            || fail "state entry written for nonexistent branch"
    fi
    [[ ! -d "${TMP_PARENT}/openemr-wt-ghost-branch" ]] \
        || fail "worktree dir created for nonexistent branch"
}

# --- error: branch already checked out in another worktree -----------------

@test "add <branch>: refuses when branch is already checked out in another worktree" {
    make_local_branch already-here
    # First add succeeds.
    oc_add already-here --env easy >/dev/null
    # Second add (different slug-target) should fail because git refuses
    # to check out the same branch in two worktrees.
    # We can't easily change the on-disk slug for the same branch (the slug
    # is deterministic from the branch name), but we can simulate by trying
    # to add the SAME branch after manually removing the state entry — that
    # way the script's own "already in state" check doesn't fire and we
    # exercise git's refusal directly.
    local tmp
    tmp=$(mktemp)
    jq 'del(."already-here")' "${STATE_FILE}" > "${tmp}"
    mv "${tmp}" "${STATE_FILE}"

    run oc_add already-here --env easy
    assert_failure
    if ! ( echo "${output}" | grep -Eq "already (exists|checked out|used by worktree)" ); then
        echo "${output}"
        fail "expected git's already-checked-out/used error"
    fi
}

# --- branch checked out in PRIMARY repo as HEAD -----------------------------

@test "add <master> (no -b): git refuses when branch is HEAD of the primary repo" {
    # master is HEAD in primary (the fixture's default). Adding it to a
    # worktree should be refused by git.
    run oc_add master --env easy
    assert_failure
    if ! ( echo "${output}" | grep -Eq "already (exists|checked out|used by worktree)" ); then
        echo "${output}"
        fail "expected git's already-checked-out error for master"
    fi
    # No state entry.
    if [[ -f "${STATE_FILE}" ]]; then
        [[ "$(jq -r 'has("master")' "${STATE_FILE}")" = "false" ]] \
            || fail "state entry written for primary HEAD"
    fi
}
