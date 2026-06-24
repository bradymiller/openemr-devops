# BATS: --help / -h dispatch + top-level lifecycle (up / down / start / stop).
# These are non-worktree paths exercised in everyday openemr-cmd use that
# until now had no hermetic coverage.
#
# --help / -h: print usage banner, exit USAGE_EXIT_CODE (13).
# up / down / start / stop: pass through to `docker compose <verb>` on the
# project's compose file — verified by the docker stub's recorded args.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    STUB_DIR=$(oc_make_docker_stub_dir)
    export STUB_DIR
}

teardown() {
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

# --- --help / -h ------------------------------------------------------------

@test "openemr-cmd --help exits 13 (USAGE_EXIT_CODE) and prints the usage banner" {
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" --help
    [[ "${status}" -eq 13 ]] || fail "expected exit 13; got ${status}"
    assert_output --partial "Usage:"
    assert_output --partial "worktree add"
    assert_output --partial "-d"
    assert_output --partial "--help"
    assert_output --partial "--version"
}

@test "openemr-cmd -h is equivalent to --help (same exit, same banner)" {
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -h
    [[ "${status}" -eq 13 ]] || fail "expected exit 13; got ${status}"
    assert_output --partial "Usage:"
    assert_output --partial "worktree add"
}

@test "openemr-cmd with no args (zero argv) prints usage and exits 13" {
    # Same code path as --help — the script's first guard checks $# -eq 0.
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}"
    [[ "${status}" -eq 13 ]] || fail "expected exit 13; got ${status}"
    assert_output --partial "Usage:"
}

# --- top-level docker-compose lifecycle ------------------------------------
# `openemr-cmd {up,down,start,stop}` skip the container-detection path (per
# the case at line ~2001) and call run_docker_compose <verb...> directly.
# The docker stub records every invocation to ${STUB_DIR}/docker.log; we
# assert the recorded args match the expected `compose <verb>` form.

@test "openemr-cmd up: calls 'compose up -d'" {
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" up
    assert_success
    grep -Fqe ' up -d' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'compose up -d' in stub log"; }
}

@test "openemr-cmd down: calls 'compose down -v' (deletes volumes by default)" {
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" down
    assert_success
    grep -Fqe ' down -v' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'compose down -v' in stub log"; }
}

@test "openemr-cmd stop: calls 'compose stop' (preserves containers + volumes)" {
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" stop
    assert_success
    # The stub records the stripped 'compose <args>' invocation; run_docker_compose
    # invokes 'compose -f <FILE> stop' (the -f path is real and may be empty,
    # making the log line "compose stop"). Match either shape with a portable
    # whitespace class (\s is a GNU-grep extension; BSD/macOS grep treats it
    # literally — use [[:space:]]).
    grep -Eq '^compose( |[[:space:]].*[[:space:]])stop$' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'compose ... stop' in stub log"; }
    # And we did NOT pass --volumes (stop is non-destructive).
    if grep -Eq 'compose.*stop.*--volumes' "${STUB_DIR}/docker.log"; then
        cat "${STUB_DIR}/docker.log"
        fail "stop accidentally passed --volumes"
    fi
}

@test "openemr-cmd start: calls 'compose start' (resumes a stopped stack)" {
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" start
    assert_success
    grep -Eq '^compose( |[[:space:]].*[[:space:]])start$' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'compose ... start' in stub log"; }
}

# --- lifecycle bypasses container detection --------------------------------
# Even with no openemr container running on the host, up/down/start/stop
# must succeed (they only need the compose file path, not a container ID).
# The script's case at ~2001 explicitly skips the "no container found" error
# for these commands. Pinning that contract.

@test "openemr-cmd up: succeeds even when no openemr container is running" {
    # DOCKER_PS_OUTPUT default is empty → no container detected → without
    # the skip, the script would print "Could not automatically determine
    # target OpenEMR container" and exit 1.
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        DOCKER_PS_OUTPUT="" \
        "${SCRIPT}" up
    assert_success
    refute_output --partial "Could not automatically determine"
}

@test "openemr-cmd start: succeeds even when no openemr container is running" {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        DOCKER_PS_OUTPUT="" \
        "${SCRIPT}" start
    assert_success
    refute_output --partial "Could not automatically determine"
}
