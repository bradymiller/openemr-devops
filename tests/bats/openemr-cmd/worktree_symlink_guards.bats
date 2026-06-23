# BATS: cmd_worktree_add symlink-attack guards.
#
# openemr-cmd refuses to add a worktree (or carries an additional refusal
# inside wt_write_override) when the base commit being checked out contains
# symlinks that could escape the worktree root — docker/, docker/<env>/,
# docker/library/. These guards exist because a malicious branch could
# commit one of those as a symlink to a host path, and once docker compose
# resolves the override file's bind-mount sources via that symlink the
# container would mount arbitrary host content.
#
# Each test below commits the malicious shape onto the fixture repo's
# master commit, then verifies that:
#   - the add invocation fails with an explicit "Refusing" message,
#   - the cleanup behavior matches the script's contract (early-stage
#     guards in cmd_worktree_add force-remove the partial worktree;
#     guards inside wt_write_override leave the worktree on disk for
#     manual inspection).

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
    # Symlinks should be committed and recreated on checkout (the default
    # on Unix, but pin it so the test is robust to inherited config).
    git -C "${TMP_ROOT}" config core.symlinks true
    STUB_DIR=$(oc_make_docker_stub_dir)
    export TMP_PARENT TMP_ROOT STUB_DIR
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

run_oc() {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        "${SCRIPT}" "$@"
}

# Commit a malicious shape onto a side branch (not master): <target_path>
# (relative to TMP_ROOT) becomes a symlink to <symlink_dest> on <side_branch>.
# Primary's master is left untouched so the pre-checkout existence checks in
# cmd_worktree_add (which look at OPENEMR_ROOT/<compose_subdir>) still pass.
# Tests then base off <side_branch> so the new worktree's checkout contains
# the symlink, which is what triggers the in-checkout symlink guards.
commit_path_as_symlink_on_branch() {
    local side_branch=$1 target=$2 dest=$3
    git -C "${TMP_ROOT}" checkout --quiet -b "${side_branch}"
    git -C "${TMP_ROOT}" rm -rf "${target}" > /dev/null
    ln -s "${dest}" "${TMP_ROOT}/${target}"
    git -C "${TMP_ROOT}" add "${target}"
    git -C "${TMP_ROOT}" commit --quiet -m "fixture (${side_branch}): ${target} -> ${dest} symlink"
    git -C "${TMP_ROOT}" checkout --quiet master
}

# --- early-stage guards in cmd_worktree_add (force-remove on detection) ----

@test "add: refuses + force-removes the worktree when docker/ is a symlink in the checkout" {
    commit_path_as_symlink_on_branch evil-docker-src docker /tmp/elsewhere-docker
    run_oc worktree add evil-docker -b --base evil-docker-src
    assert_failure
    assert_output --partial "Refusing"
    assert_output --partial "docker"
    assert_output --partial "is a symlink in the checked-out branch"
    [[ ! -d "${TMP_PARENT}/openemr-wt-evil-docker" ]] \
        || fail "early-stage guard should have force-removed the worktree dir"
    ! jq -e '."evil-docker"' "${TMP_ROOT}/.worktrees.json" >/dev/null 2>&1 \
        || fail "state entry should not have been written"
}

@test "add: refuses + force-removes when docker/development-easy/ is a symlink in the checkout" {
    commit_path_as_symlink_on_branch evil-easy-src docker/development-easy /tmp/elsewhere-easy
    run_oc worktree add evil-easy -b --base evil-easy-src
    assert_failure
    assert_output --partial "Refusing"
    assert_output --partial "docker/development-easy"
    assert_output --partial "is a symlink in the checked-out branch"
    [[ ! -d "${TMP_PARENT}/openemr-wt-evil-easy" ]] \
        || fail "early-stage guard should have force-removed the worktree dir"
    ! jq -e '."evil-easy"' "${TMP_ROOT}/.worktrees.json" >/dev/null 2>&1 \
        || fail "state entry should not have been written"
}

# --- defense-in-depth guard inside wt_write_override ------------------------

@test "add: refuses (no auto-cleanup) when docker/library/ is a symlink in the checkout" {
    # Replace docker/library (a real dir in the fixture) with a symlink on
    # a side branch. wt_write_override's check fires AFTER mkdir + the
    # early-stage guards, so per the script's contract the partial worktree
    # is left in place for the user to inspect / remove manually.
    commit_path_as_symlink_on_branch evil-lib-src docker/library /tmp/elsewhere-lib
    run_oc worktree add evil-lib -b --base evil-lib-src
    assert_failure
    assert_output --partial "Refusing"
    assert_output --partial "docker/library"
    assert_output --partial "is a symlink"
    # State entry NOT written (wt_state_set comes after wt_write_override).
    ! jq -e '."evil-lib"' "${TMP_ROOT}/.worktrees.json" >/dev/null 2>&1 \
        || fail "state entry should not exist (wt_state_set runs after wt_write_override)"
    # Worktree dir is intentionally LEFT on disk — wt_write_override has
    # no force-remove. This asserts on that contract so a future refactor
    # that adds cleanup here would update this test deliberately.
    [[ -d "${TMP_PARENT}/openemr-wt-evil-lib" ]] \
        || fail "wt_write_override symlink guard should NOT auto-remove the worktree dir"
}
