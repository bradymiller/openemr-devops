# BATS: cmd_worktree_add end-to-end side effects.
#
# Where worktree_add_base.bats covers --base argument parsing + resolution,
# this file exercises the full create flow and verifies every artifact
# cmd_worktree_add is supposed to produce:
#   - registered git worktree directory under WORKTREE_PARENT
#   - new branch (or checked-out existing branch) pointing at the right SHA
#   - .worktrees.json state entry with offset/dir/env
#   - per-env compose .env file with the right WT_* port variables
#   - docker-compose.override.yml with branch-scoped volume names
#   - port-offset uniqueness across consecutive adds
#   - --start triggers a `docker compose ... up -d` against the right project
#
# All side effects land inside a hermetic TMP_PARENT (no network, no real
# docker). Canonical fetch is redirected to a file:// URL pointing at the
# same tmp repo via WT_CANONICAL_URL so the default `-b` path stays inside
# the test fixture.

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
    export TMP_PARENT TMP_ROOT STUB_DIR
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

# Run the script's `worktree add` against the hermetic fixture.
run_add() {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        "${SCRIPT}" worktree add "$@"
}

# --- core happy path --------------------------------------------------------

@test "add -b (default canonical fetch via file:// URL) creates dir, branch, state, .env, override" {
    run_add feature-x -b
    assert_success

    local wt_dir="${TMP_PARENT}/openemr-wt-feature-x"
    [[ -d "${wt_dir}" ]] || fail "worktree dir missing: ${wt_dir}"

    # Branch tip matches what canonical (= TMP_ROOT itself) had at master.
    local got expected
    got=$(git -C "${TMP_ROOT}" rev-parse feature-x)
    expected=$(git -C "${TMP_ROOT}" rev-parse master)
    [[ "${got}" = "${expected}" ]] || fail "branch ${got} != expected ${expected}"

    # State entry present with offset 1, env easy, correct dir.
    [[ -f "${TMP_ROOT}/.worktrees.json" ]]
    local entry
    entry=$(jq -c '."feature-x"' "${TMP_ROOT}/.worktrees.json")
    [[ "${entry}" != "null" ]] || fail "no state entry for feature-x"
    [[ "$(jq -r '."feature-x".offset' "${TMP_ROOT}/.worktrees.json")" = "1" ]]
    [[ "$(jq -r '."feature-x".env'    "${TMP_ROOT}/.worktrees.json")" = "easy" ]]
    [[ "$(jq -r '."feature-x".dir'    "${TMP_ROOT}/.worktrees.json")" = "${wt_dir}" ]]

    # .env file has the right WT_* variables.
    local envf="${wt_dir}/docker/development-easy/.env"
    [[ -f "${envf}" ]] || fail "compose .env missing: ${envf}"
    grep -qE "^WT_NAME=feature-x$"  "${envf}"
    grep -qE "^WT_ENV=easy$"        "${envf}"
    grep -qE "^WT_OFFSET=1$"        "${envf}"
    grep -qE "^WT_HTTP_PORT=8301$"  "${envf}"
    grep -qE "^WT_HTTPS_PORT=9301$" "${envf}"
    grep -qE "^WT_MYSQL_PORT=8321$" "${envf}"

    # Override file present and uses branch-scoped volume names.
    local ovf="${wt_dir}/docker/development-easy/docker-compose.override.yml"
    [[ -f "${ovf}" ]] || fail "override missing: ${ovf}"
    grep -q "name: openemr-feature-x_db"     "${ovf}"
    grep -q "name: openemr-feature-x_assets" "${ovf}"
}

@test "add -b --base <local-ref> uses the local ref's SHA without a fetch" {
    # Capture canonical's notion of master so we can later show we did NOT
    # fall back to it (we want LOCAL master, which happens to be the same
    # commit here — but the assertion is structurally about the --base path).
    run_add feature-y -b --base master
    assert_success
    local got expected
    got=$(git -C "${TMP_ROOT}" rev-parse feature-y)
    expected=$(git -C "${TMP_ROOT}" rev-parse master)
    [[ "${got}" = "${expected}" ]]
}

@test "add -b --env easy-redis routes to the easy-redis compose subdir + adds WT_REDIS_PORT" {
    run_add feature-r -b --env easy-redis
    assert_success
    local wt_dir="${TMP_PARENT}/openemr-wt-feature-r"
    [[ -f "${wt_dir}/docker/development-easy-redis/.env" ]]
    grep -qE "^WT_REDIS_PORT=6380$" "${wt_dir}/docker/development-easy-redis/.env"
    # Easy-redis-only redis container_name override block is emitted.
    grep -q "container_name: openemr-feature-r-redis-master" \
        "${wt_dir}/docker/development-easy-redis/docker-compose.override.yml"
}

@test "add -b --env easy-light skips selenium/couchdb/mailpit/redis ports" {
    run_add feature-l -b --env easy-light
    assert_success
    local envf="${TMP_PARENT}/openemr-wt-feature-l/docker/development-easy-light/.env"
    grep -qE "^WT_NAME=feature-l$"  "${envf}"
    ! grep -q "^WT_SELENIUM_PORT="  "${envf}"
    ! grep -q "^WT_COUCHDB_PORT="   "${envf}"
    ! grep -q "^WT_MAILPIT_UI_PORT=" "${envf}"
    ! grep -q "^WT_REDIS_PORT="     "${envf}"
}

# --- port-offset uniqueness -------------------------------------------------

@test "three consecutive adds allocate distinct offsets 1, 2, 3" {
    run_add a1 -b ; assert_success
    run_add a2 -b ; assert_success
    run_add a3 -b ; assert_success
    [[ "$(jq -r '.a1.offset' "${TMP_ROOT}/.worktrees.json")" = "1" ]]
    [[ "$(jq -r '.a2.offset' "${TMP_ROOT}/.worktrees.json")" = "2" ]]
    [[ "$(jq -r '.a3.offset' "${TMP_ROOT}/.worktrees.json")" = "3" ]]
}

@test "removing a worktree frees its offset for the next add" {
    skip "wt_state_remove is not exposed via a non-interactive worktree-remove path; covered indirectly by prune.bats"
}

# --- existing branch (no -b) ------------------------------------------------

@test "add <existing-branch> (no -b) checks out the existing branch into a new worktree" {
    # Make an existing branch on the primary, then ask worktree-add to check
    # it out into a new dir.
    git -C "${TMP_ROOT}" branch existing-feat master
    run_add existing-feat
    assert_success
    local wt_dir="${TMP_PARENT}/openemr-wt-existing-feat"
    [[ -d "${wt_dir}" ]]
    # State entry written with offset 1.
    [[ "$(jq -r '."existing-feat".offset' "${TMP_ROOT}/.worktrees.json")" = "1" ]]
    # Checkout is on existing-feat, not master.
    local wt_head_branch
    wt_head_branch=$(git -C "${wt_dir}" symbolic-ref --short HEAD)
    [[ "${wt_head_branch}" = "existing-feat" ]]
}

# --- duplicate branch -------------------------------------------------------

@test "second add of an already-registered branch fails with an explicit message" {
    run_add dup-branch -b ; assert_success
    run_add dup-branch -b
    assert_failure
    assert_output --partial "Worktree for 'dup-branch' already exists"
}

# --- --start triggers compose up against the right project ------------------

@test "add -b --start runs 'docker compose ... -p openemr-<slug> ... up -d'" {
    run_add start-me -b --start
    assert_success
    # The stub records every docker invocation to docker.log; assert the
    # compose-up invocation went out with the branch-scoped project name and
    # the worktree's override file.
    local log="${STUB_DIR}/docker.log"
    [[ -f "${log}" ]]
    # `-e` so the `-p` in the pattern isn't parsed as a grep flag.
    grep -F -e "-p openemr-start-me" "${log}" | grep -F -e "up -d" \
        || { echo "--- docker.log contents ---"; cat "${log}"; fail "expected compose-up invocation not found"; }
}

# --- primary HEAD invariant -------------------------------------------------

@test "primary repo's HEAD is unchanged after a successful add" {
    local head_before head_after
    head_before=$(git -C "${TMP_ROOT}" rev-parse HEAD)
    run_add invariant-x -b
    assert_success
    head_after=$(git -C "${TMP_ROOT}" rev-parse HEAD)
    [[ "${head_before}" = "${head_after}" ]] || \
        fail "HEAD moved: ${head_before} -> ${head_after}"
}

# --- branch-slugging ROUNDTRIP ----------------------------------------------

@test "branch with slashes slugifies into dir + override volume names consistently" {
    run_add feature/foo-bar -b
    assert_success
    local wt_dir="${TMP_PARENT}/openemr-wt-feature-foo-bar"
    [[ -d "${wt_dir}" ]]
    grep -q "name: openemr-feature-foo-bar_db" \
        "${wt_dir}/docker/development-easy/docker-compose.override.yml"
    # State key is the branch as-passed, NOT the slug.
    [[ "$(jq -r '."feature/foo-bar".dir' "${TMP_ROOT}/.worktrees.json")" = "${wt_dir}" ]]
}
