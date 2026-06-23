# BATS: cmd_worktree_{up,down,start,stop,regen,set-env} compose invocations.
#
# Where worktree_add_integration.bats covers the `add` create flow, this
# file exercises the lifecycle commands that act on an already-added
# worktree. The recording docker stub captures every `docker compose ...`
# invocation to ${STUB_DIR}/docker.log; each test asserts the lifecycle
# command went out with the right project name, env-file, override-file,
# and trailing action (up -d / down --volumes / start / stop / ...).

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

# Run any openemr-cmd invocation under the hermetic fixture.
run_oc() {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        DOCKER_PS_OUTPUT="${DOCKER_PS_OUTPUT-}" \
        "${SCRIPT}" "$@"
}

# Add a worktree as preconditions for lifecycle tests, then truncate the
# docker.log so the test sees only the lifecycle command's invocations.
setup_worktree() {
    run_oc worktree add "$@"
    assert_success
    : > "${STUB_DIR}/docker.log"
}

# Convenience: extract the compose invocation line (excludes the bare
# `compose` plugin-probe call).
compose_call_line() {
    grep -F -e "compose " "${STUB_DIR}/docker.log" | grep -F -e "-p openemr-" | head -1
}

# --- up ---------------------------------------------------------------------

@test "up <branch>: runs 'compose ... -p openemr-<slug> ... up -d'" {
    setup_worktree feature-a -b
    run_oc worktree up feature-a
    assert_success
    local line
    line=$(compose_call_line)
    [[ "${line}" == *"compose"*" --env-file "*"/openemr-wt-feature-a/docker/development-easy/.env"* ]]
    [[ "${line}" == *"-p openemr-feature-a"* ]]
    [[ "${line}" == *"-f "*"/docker-compose.yml"*"-f "*"/docker-compose.override.yml"* ]]
    [[ "${line}" == *"up -d" ]]
}

# --- down (volumes by default; --keep-volumes preserves) --------------------

@test "down <branch> (default): runs 'compose ... down --volumes'" {
    setup_worktree feature-b -b
    run_oc worktree down feature-b
    assert_success
    local line
    line=$(compose_call_line)
    [[ "${line}" == *"-p openemr-feature-b"* ]]
    [[ "${line}" == *"down --volumes" ]]
}

@test "down <branch> --keep-volumes: runs 'compose ... down' WITHOUT --volumes" {
    setup_worktree feature-c -b
    run_oc worktree down feature-c --keep-volumes
    assert_success
    local line
    line=$(compose_call_line)
    [[ "${line}" == *"-p openemr-feature-c"* ]]
    [[ "${line}" == *"down" ]]
    [[ "${line}" != *"--volumes"* ]] || fail "--keep-volumes should suppress --volumes; saw: ${line}"
}

# --- start / stop -----------------------------------------------------------

@test "start <branch>: runs 'compose ... start' (no -d, no --volumes)" {
    setup_worktree feature-d -b
    run_oc worktree start feature-d
    assert_success
    local line
    line=$(compose_call_line)
    [[ "${line}" == *"-p openemr-feature-d"* ]]
    [[ "${line}" == *" start" ]] || fail "expected trailing 'start'; saw: ${line}"
    [[ "${line}" != *"up -d"* ]] || fail "start should not invoke 'up -d'"
}

@test "stop <branch>: runs 'compose ... stop'" {
    setup_worktree feature-e -b
    run_oc worktree stop feature-e
    assert_success
    local line
    line=$(compose_call_line)
    [[ "${line}" == *"-p openemr-feature-e"* ]]
    [[ "${line}" == *" stop" ]]
    [[ "${line}" != *"down"* ]] || fail "stop should not invoke 'down'"
}

# --- regen (no docker call, just rewrites compose files) --------------------

@test "regen <branch>: rewrites .env + override; does NOT call docker compose" {
    setup_worktree feature-f -b
    local envf="${TMP_PARENT}/openemr-wt-feature-f/docker/development-easy/.env"
    local ovf="${TMP_PARENT}/openemr-wt-feature-f/docker/development-easy/docker-compose.override.yml"

    # Tamper with both files so we can prove they were rewritten.
    echo "# tampered" > "${envf}"
    echo "# tampered" > "${ovf}"

    run_oc worktree regen feature-f
    assert_success
    grep -qE "^WT_NAME=feature-f$" "${envf}"
    grep -q "name: openemr-feature-f_db" "${ovf}"

    # No `compose` invocation should appear in the log for regen (only the
    # plugin-probe `compose` line, which has no further args).
    ! grep -F -e "compose " "${STUB_DIR}/docker.log" | grep -F -e "-p openemr-" \
        || fail "regen should not call 'docker compose -p ...'"
}

# --- set-env ----------------------------------------------------------------

@test "set-env: refuses with explicit error when the stack is still up" {
    setup_worktree feature-g -b
    # Simulate `compose ps -aq` returning a non-empty container list.
    DOCKER_PS_OUTPUT="dummycontainerid" run_oc worktree set-env feature-g easy-redis
    assert_failure
    assert_output --partial "Stack must be down before switching env"
    # State entry's env did NOT change.
    [[ "$(jq -r '."feature-g".env' "${TMP_ROOT}/.worktrees.json")" = "easy" ]]
}

@test "set-env: when stack is down, rewrites state + .env + override for the new env" {
    setup_worktree feature-h -b
    # DOCKER_PS_OUTPUT empty (default) -> stack appears down -> proceed.
    run_oc worktree set-env feature-h easy-redis
    assert_success

    # State entry's env field updated.
    [[ "$(jq -r '."feature-h".env' "${TMP_ROOT}/.worktrees.json")" = "easy-redis" ]]

    # New env's .env + override files exist with redis bits.
    local new_envf="${TMP_PARENT}/openemr-wt-feature-h/docker/development-easy-redis/.env"
    local new_ovf="${TMP_PARENT}/openemr-wt-feature-h/docker/development-easy-redis/docker-compose.override.yml"
    [[ -f "${new_envf}" ]]
    grep -qE "^WT_REDIS_PORT=" "${new_envf}"
    grep -q "container_name: openemr-feature-h-redis-master" "${new_ovf}"
}

@test "set-env: no-op when the target env equals the current env" {
    setup_worktree feature-i -b
    run_oc worktree set-env feature-i easy
    assert_success
    assert_output --partial "already on env 'easy'"
}

@test "set-env: refuses an invalid env name with the validate-env message" {
    setup_worktree feature-j -b
    run_oc worktree set-env feature-j bogus-env-name
    assert_failure
    assert_output --partial "Invalid env 'bogus-env-name'"
    # State unchanged.
    [[ "$(jq -r '."feature-j".env' "${TMP_ROOT}/.worktrees.json")" = "easy" ]]
}

@test "set-env: easy -> easy-light rewrites compose dir + state, strips selenium/couchdb/mailpit/redis vars" {
    setup_worktree feature-k -b
    run_oc worktree set-env feature-k easy-light
    assert_success
    [[ "$(jq -r '."feature-k".env' "${TMP_ROOT}/.worktrees.json")" = "easy-light" ]]
    local envf="${TMP_PARENT}/openemr-wt-feature-k/docker/development-easy-light/.env"
    [[ -f "${envf}" ]]
    ! grep -q "^WT_SELENIUM_PORT="    "${envf}"
    ! grep -q "^WT_COUCHDB_PORT="     "${envf}"
    ! grep -q "^WT_MAILPIT_UI_PORT="  "${envf}"
    ! grep -q "^WT_REDIS_PORT="       "${envf}"
}

@test "set-env: easy-redis -> easy strips redis-specific container_name overrides from the new override" {
    setup_worktree feature-l -b --env easy-redis
    run_oc worktree set-env feature-l easy
    assert_success
    [[ "$(jq -r '."feature-l".env' "${TMP_ROOT}/.worktrees.json")" = "easy" ]]
    local new_ovf="${TMP_PARENT}/openemr-wt-feature-l/docker/development-easy/docker-compose.override.yml"
    [[ -f "${new_ovf}" ]]
    ! grep -q "redis-master:" "${new_ovf}"
    ! grep -q "redis-replica" "${new_ovf}"
    ! grep -q "sentinel"      "${new_ovf}"
}

@test "set-env: refuses when target env's docker-compose.yml is missing from the checkout" {
    setup_worktree feature-m -b
    # Simulate an older branch that predates easy-redis: delete its compose file.
    rm -f "${TMP_PARENT}/openemr-wt-feature-m/docker/development-easy-redis/docker-compose.yml"
    run_oc worktree set-env feature-m easy-redis
    assert_failure
    assert_output --partial "New env's compose file not found"
    # State unchanged.
    [[ "$(jq -r '."feature-m".env' "${TMP_ROOT}/.worktrees.json")" = "easy" ]]
}

# --- regen error paths ------------------------------------------------------

@test "regen: missing branch arg shows usage" {
    setup_worktree feature-regen-usage -b
    run_oc worktree regen
    assert_failure
    assert_output --partial "Usage: openemr-cmd worktree regen <branch>"
}

@test "regen: state file missing dies with 'No worktrees found'" {
    # No worktree setup, no state file.
    run_oc worktree regen anything
    assert_failure
    assert_output --partial "No worktrees found"
}

@test "regen: unknown branch dies with 'No worktree found for'" {
    setup_worktree feature-known -b
    run_oc worktree regen feature-unknown
    assert_failure
    assert_output --partial "No worktree found for 'feature-unknown'"
}
