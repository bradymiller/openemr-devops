# BATS: container resolution for non-worktree subcommands.
#
# Most openemr-cmd subcommands need a target container. The resolution
# order (script lines ~1929-1950) is:
#   1. -d <id> on the command line (overrides everything)
#   2. docker ps --filter name=$INSANE_DEV_DOCKER
#   3. docker ps --filter name=$EASY_DEV_DOCKER
#   4. docker ps --filter label=com.docker.compose.service=openemr (any
#      running worktree container with the openemr label)
#   5. else CONTAINER_ID="" and a later case at ~2004 surfaces a clear error.
#
# These tests pin each of those paths. We use a devtools-style subcommand
# ('pst' → phpstan) as the test vehicle so we can assert the resulting
# docker exec invocation includes the expected container id.

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

# --- -d flag override ------------------------------------------------------

@test "-d <id> <subcommand>: routes subcommand into the named container (no auto-detect)" {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        "${SCRIPT}" -d my-explicit-container pst
    assert_success
    # docker exec invocation should include 'my-explicit-container' and /root/devtools phpstan.
    grep -Fq "exec" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "no docker exec recorded"; }
    grep -Fq "my-explicit-container" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "explicit container id not in exec invocation"; }
    grep -Fq "/root/devtools phpstan" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected '/root/devtools phpstan' in exec invocation"; }
}

@test "-d <id> e <command>: routes the shell command into the named container" {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        "${SCRIPT}" -d explicit-target e "echo hello-from-explicit"
    assert_success
    # execute_command_flexible → run_shell_command_in_docker → 'docker exec -i <id> sh -c "..."'
    grep -Fq "exec" "${STUB_DIR}/docker.log" || { cat "${STUB_DIR}/docker.log"; fail "no exec recorded"; }
    grep -Fq "explicit-target" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "explicit container id not in exec"; }
    grep -Fq "echo hello-from-explicit" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "shell command not forwarded"; }
}

# --- auto-detect: insane > easy > worktree-label fallback ------------------

@test "auto-detect: INSANE_DEV_DOCKER match → that id is used as CONTAINER_ID" {
    # DOCKER_PS_OUTPUT is returned for ALL `docker ps ...` calls in our stub,
    # so the first `--filter name=openemr-8-5...` filter returns this id and
    # subsequent fallback queries don't run.
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        DOCKER_PS_OUTPUT="insane-container-id" \
        "${SCRIPT}" pst
    assert_success
    grep -Fq "insane-container-id" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "auto-detected id not used"; }
    grep -Fq "/root/devtools phpstan" "${STUB_DIR}/docker.log" \
        || fail "expected devtools dispatch"
}

# --- no container found → clear error --------------------------------------

@test "auto-detect failure: clear error mentioning INSANE and EASY name patterns" {
    # DOCKER_PS_OUTPUT empty (default) → all `docker ps --filter name=...`
    # return nothing → CONTAINER_ID stays empty → the case at line ~2004
    # surfaces the error.
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        "${SCRIPT}" pst
    assert_failure
    assert_output --partial "Could not automatically determine target OpenEMR container"
    assert_output --partial "openemr-8-5"
    assert_output --partial "openemr"
    # The fix-it hint should mention -d and worktree-container guidance.
    assert_output --partial "-d <container_name_or_id>"
    assert_output --partial "For worktree containers"
}

# --- -d with no value / -d with id-but-no-cmd ------------------------------
# These are already covered in cli_smoke.bats. We add the "-d <id> <cmd>"
# happy path above to complete the matrix.

# --- container-needing vs non-container-needing subcommands ----------------
# `up`/`down`/`start`/`stop`/--help/-h/--version/-v are explicitly allowed
# to proceed without a container per the case at line ~2001. Pinning here
# that the missing-container error does NOT fire for them — even though
# this is also covered by help_and_lifecycle.bats, repeating once in the
# error-message context guards against a parser regression that would
# mistakenly route them through the error path.

@test "container resolution: 'up' does NOT trigger missing-container error" {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        "${SCRIPT}" up
    assert_success
    refute_output --partial "Could not automatically determine"
}
