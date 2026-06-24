# BATS: concurrent `worktree add` operations don't collide on state.
#
# wt_next_offset reads .worktrees.json, picks the lowest unused offset,
# then wt_state_set writes a new entry. The read-modify-write happens via
# jq + mv (mv is atomic but the read and write are NOT atomic together),
# so in principle two concurrent invocations could each pick the same
# offset and the later mv wins. These tests stress that flow by spawning
# three parallel adds — one per env — and asserting all three succeed
# with distinct offsets and distinct compose subdirs.
#
# If the offset race ever became a real bug, these tests would catch it
# under high-concurrency CI loads (or could be made deterministic by
# adding fixture-side coordination — left for if/when that's needed).

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

# Spawn a single `worktree add` in the background. Captures exit code to
# a per-branch file so the parent can sum them after `wait`.
add_in_bg() {
    local branch=$1 env=$2 rc_file=$3
    (
        env \
            PATH="${STUB_DIR}:${PATH}" \
            OPENEMR_ROOT="${TMP_ROOT}" \
            WORKTREE_PARENT="${TMP_PARENT}" \
            WT_CANONICAL_URL="file://${TMP_ROOT}" \
            "${SCRIPT}" worktree add "${branch}" -b --env "${env}" >/dev/null 2>&1
        echo $? > "${rc_file}"
    ) &
}

@test "three concurrent adds (one per env): all succeed, distinct offsets, distinct compose subdirs" {
    # Race-closed by the state-lock work that introduced wt_acquire_state_lock /
    # wt_release_state_lock in cmd_worktree_add. Before the lock landed, this
    # test reproduced the bug 5/5: two concurrent invocations would both read
    # the same starting state from wt_next_offset and wt_state_set, race on
    # the final mv, and the later writer would silently clobber the earlier
    # writer's entry (or both would land with the same offset → port
    # collision). With the mkdir-based lock holding the wt_next_offset →
    # wt_state_set critical section, this test is now the regression guard.
    local rc_a="${TMP_PARENT}/rc-a" rc_b="${TMP_PARENT}/rc-b" rc_c="${TMP_PARENT}/rc-c"

    add_in_bg conc-easy        easy        "${rc_a}"
    add_in_bg conc-easy-light  easy-light  "${rc_b}"
    add_in_bg conc-easy-redis  easy-redis  "${rc_c}"
    wait

    # All three exited 0.
    [[ "$(cat "${rc_a}")" = "0" ]] || fail "conc-easy add failed (rc=$(cat "${rc_a}"))"
    [[ "$(cat "${rc_b}")" = "0" ]] || fail "conc-easy-light add failed (rc=$(cat "${rc_b}"))"
    [[ "$(cat "${rc_c}")" = "0" ]] || fail "conc-easy-redis add failed (rc=$(cat "${rc_c}"))"

    # All three present in the state file.
    [[ "$(jq -r '."conc-easy".env'       "${TMP_ROOT}/.worktrees.json")" = "easy"       ]] || fail "conc-easy entry wrong/missing"
    [[ "$(jq -r '."conc-easy-light".env' "${TMP_ROOT}/.worktrees.json")" = "easy-light" ]] || fail "conc-easy-light entry wrong/missing"
    [[ "$(jq -r '."conc-easy-redis".env' "${TMP_ROOT}/.worktrees.json")" = "easy-redis" ]] || fail "conc-easy-redis entry wrong/missing"

    # Distinct offsets — this is the offset-allocation-race assertion. If
    # the read-modify-write on .worktrees.json ever lost an update, two
    # entries would share an offset and this would fail.
    local o_a o_b o_c
    o_a=$(jq -r '."conc-easy".offset'        "${TMP_ROOT}/.worktrees.json")
    o_b=$(jq -r '."conc-easy-light".offset'  "${TMP_ROOT}/.worktrees.json")
    o_c=$(jq -r '."conc-easy-redis".offset'  "${TMP_ROOT}/.worktrees.json")
    local sorted
    sorted=$(printf '%s\n%s\n%s\n' "${o_a}" "${o_b}" "${o_c}" | sort -u | wc -l | tr -d ' ')
    [[ "${sorted}" = "3" ]] || \
        fail "expected 3 distinct offsets, got ${sorted} (a=${o_a} b=${o_b} c=${o_c})"
}

@test "three concurrent adds: each lands in its own env's compose subdir" {
    local rc_a="${TMP_PARENT}/rc-a" rc_b="${TMP_PARENT}/rc-b" rc_c="${TMP_PARENT}/rc-c"

    add_in_bg cs-easy        easy        "${rc_a}"
    add_in_bg cs-easy-light  easy-light  "${rc_b}"
    add_in_bg cs-easy-redis  easy-redis  "${rc_c}"
    wait

    [[ "$(cat "${rc_a}")" = "0" ]]
    [[ "$(cat "${rc_b}")" = "0" ]]
    [[ "$(cat "${rc_c}")" = "0" ]]

    # Each .env file landed in the env-specific compose subdir AND nowhere
    # else. A regression that hardcoded the env subdir (or shared a single
    # subdir across runs) would fail this.
    [[ -f "${TMP_PARENT}/openemr-wt-cs-easy/docker/development-easy/.env"             ]] || fail "easy .env missing"
    [[ -f "${TMP_PARENT}/openemr-wt-cs-easy-light/docker/development-easy-light/.env" ]] || fail "easy-light .env missing"
    [[ -f "${TMP_PARENT}/openemr-wt-cs-easy-redis/docker/development-easy-redis/.env" ]] || fail "easy-redis .env missing"

    # Cross-pollination check: easy's worktree must NOT have written into
    # easy-light's or easy-redis's compose subdir, and vice versa.
    [[ ! -f "${TMP_PARENT}/openemr-wt-cs-easy/docker/development-easy-light/.env"     ]] || fail "easy leaked into easy-light dir"
    [[ ! -f "${TMP_PARENT}/openemr-wt-cs-easy/docker/development-easy-redis/.env"     ]] || fail "easy leaked into easy-redis dir"
    [[ ! -f "${TMP_PARENT}/openemr-wt-cs-easy-light/docker/development-easy/.env"     ]] || fail "easy-light leaked into easy dir"
    [[ ! -f "${TMP_PARENT}/openemr-wt-cs-easy-redis/docker/development-easy/.env"     ]] || fail "easy-redis leaked into easy dir"
}
