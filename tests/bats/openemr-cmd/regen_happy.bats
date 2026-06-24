# BATS: cmd_worktree_regen happy path.
#
# regen calls wt_write_env + wt_write_override against the current state
# entry — useful when the user has manually stomped the .env / override
# files, or when wt_state_set has been hand-edited to a different env
# and the files need to catch up. The failure paths (missing branch arg,
# no state file, unknown branch) are pinned in worktree_lifecycle.bats;
# this file covers the actual rewrite behavior.

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

# Add a worktree (helper for setting up fixtures).
oc_add() {
    env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        "${SCRIPT}" worktree add "$@"
}

oc_regen() {
    env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree regen "$@"
}

# --- regen rewrites .env after a manual stomp -------------------------------

@test "regen: rewrites .env back to the canonical contents after a manual stomp" {
    oc_add regen-env -b --env easy >/dev/null
    local env_file="${TMP_PARENT}/openemr-wt-regen-env/docker/development-easy/.env"
    [[ -f "${env_file}" ]] || fail "fixture .env missing"
    local before
    before=$(cat "${env_file}")

    # Stomp the file with garbage.
    echo "STOMPED_GARBAGE=1" > "${env_file}"

    run oc_regen regen-env
    assert_success
    assert_output --partial "Regenerating compose files for 'regen-env'"

    # File restored to what cmd_worktree_add originally wrote.
    [[ "$(cat "${env_file}")" = "${before}" ]] \
        || { diff <(echo "${before}") "${env_file}"; fail ".env was not restored to original contents"; }
}

@test "regen: rewrites docker-compose.override.yml after a manual stomp" {
    oc_add regen-override -b --env easy >/dev/null
    local override="${TMP_PARENT}/openemr-wt-regen-override/docker/development-easy/docker-compose.override.yml"
    [[ -f "${override}" ]] || fail "fixture override missing"
    local before
    before=$(cat "${override}")

    # Stomp.
    : > "${override}"

    run oc_regen regen-override
    assert_success
    [[ "$(cat "${override}")" = "${before}" ]] \
        || fail "override.yml was not restored to original contents"
}

@test "regen: when state was hand-edited to a different env, regen rewrites the files for the NEW env" {
    # Add on easy, then hand-edit state to say easy-light. regen should
    # write files into the easy-light compose subdir (state is source of
    # truth for env; regen brings files in line).
    oc_add regen-env-switch -b --env easy >/dev/null
    local wt_dir="${TMP_PARENT}/openemr-wt-regen-env-switch"
    [[ -f "${wt_dir}/docker/development-easy/.env" ]] || fail "easy .env not created by add"

    # Hand-edit state to easy-light.
    local tmp
    tmp=$(mktemp)
    jq '."regen-env-switch".env = "easy-light"' "${STATE_FILE}" > "${tmp}"
    mv "${tmp}" "${STATE_FILE}"

    run oc_regen regen-env-switch
    assert_success
    # easy-light files now exist (regen wrote them).
    [[ -f "${wt_dir}/docker/development-easy-light/.env" ]] \
        || fail "regen did not write easy-light .env after state edit"
    [[ -f "${wt_dir}/docker/development-easy-light/docker-compose.override.yml" ]] \
        || fail "regen did not write easy-light override after state edit"
    # NOTE: regen does NOT delete the old env's files (the previous
    # easy/.env is still on disk). Pinning that current behavior — if it
    # changes, this assertion documents the contract was different before.
    [[ -f "${wt_dir}/docker/development-easy/.env" ]] \
        || fail "regen unexpectedly removed the old env's .env; that would be a contract change"
}

# --- regen against multi-entry state preserves other entries ---------------

@test "regen: only touches the named branch's entry; other entries' files unaffected" {
    oc_add regen-a -b --env easy >/dev/null
    oc_add regen-b -b --env easy-light >/dev/null

    local env_a="${TMP_PARENT}/openemr-wt-regen-a/docker/development-easy/.env"
    local env_b="${TMP_PARENT}/openemr-wt-regen-b/docker/development-easy-light/.env"

    local before_b
    before_b=$(cat "${env_b}")

    # Stomp BOTH files, but only regen 'a'.
    echo "STOMPED_A=1" > "${env_a}"
    echo "STOMPED_B=1" > "${env_b}"

    run oc_regen regen-a
    assert_success
    # 'a' restored — assert file presence first so a missing-file scenario
    # (grep returns non-zero for "no match" AND for "no file") can't false-pass.
    [[ -f "${env_a}" ]] || fail "'a' .env file missing after regen"
    if grep -q "STOMPED_A" "${env_a}"; then
        fail "'a' was not regenerated (STOMPED_A still present)"
    fi
    # 'b' still stomped (we didn't regen it).
    grep -q "STOMPED_B" "${env_b}" || fail "'b' was modified by regen of 'a'"
}
