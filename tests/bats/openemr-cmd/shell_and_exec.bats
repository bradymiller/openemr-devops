# BATS: top-level `s|shell` and `e|exec` subcommands.
#
# shell: drops into an interactive sh inside the openemr container's web
#   root: `docker exec -w /var/www/localhost/htdocs/openemr -it <id> sh`.
#   We can't drive interactivity, but the stub records the invocation
#   shape so we can assert -w / -it / sh are present.
#
# exec (alias 'e'): runs an arbitrary shell command in the container via
#   `docker exec -i <id> sh -c "<command>"`. With no args, prints a usage
#   hint instead of erroring.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    STUB_DIR=$(oc_make_docker_stub_dir)
    CONTAINER=fixed-shell-target
    export STUB_DIR CONTAINER
}

teardown() {
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

oc_run() {
    env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -d "${CONTAINER}" "$@"
}

# --- shell / s -------------------------------------------------------------

@test "shell: invokes 'docker exec -w /var/www/localhost/htdocs/openemr -it <id> sh'" {
    run oc_run shell
    assert_success
    grep -Fq "exec" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "no docker exec recorded"; }
    grep -Fq "${CONTAINER}" "${STUB_DIR}/docker.log" \
        || fail "container id missing"
    grep -Fq "/var/www/localhost/htdocs/openemr" "${STUB_DIR}/docker.log" \
        || fail "expected -w /var/www/localhost/htdocs/openemr"
    grep -Fq -- "-it" "${STUB_DIR}/docker.log" \
        || fail "expected -it (interactive + tty) flag"
    # The trailing `sh` shell command should be at the end of the recorded line.
    grep -Eq " sh$" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected trailing 'sh' as the exec command"; }
}

@test "shell: 's' alias is equivalent to 'shell'" {
    run oc_run s
    assert_success
    grep -Fq "/var/www/localhost/htdocs/openemr" "${STUB_DIR}/docker.log" \
        || fail "'s' alias did not invoke shell with -w workdir"
    grep -Eq " sh$" "${STUB_DIR}/docker.log" || fail "'s' alias did not invoke sh"
}

# --- exec / e --------------------------------------------------------------

@test "exec: 'e <command>' runs 'docker exec -i <id> sh -c <command>' in the container" {
    run oc_run e "echo hello-from-exec"
    assert_success
    grep -Fq "${CONTAINER}" "${STUB_DIR}/docker.log" || fail "container id missing"
    grep -Fq "echo hello-from-exec" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "command string not forwarded"; }
    # The dispatch uses sh -c, not just sh.
    grep -Fq -- "sh -c" "${STUB_DIR}/docker.log" || fail "expected 'sh -c' form"
    # -i (interactive, no tty) — different from shell's -it.
    grep -Fq -- "-i" "${STUB_DIR}/docker.log" || fail "expected -i flag"
}

@test "exec: 'exec <command>' (long form) is equivalent to 'e <command>'" {
    run oc_run exec "echo via-long-form"
    assert_success
    grep -Fq "echo via-long-form" "${STUB_DIR}/docker.log" || fail "long form not forwarded"
    grep -Fq -- "sh -c" "${STUB_DIR}/docker.log" || fail "long form did not use sh -c"
}

@test "exec: with no command prints usage hint (does NOT error out)" {
    # execute_command_flexible at line ~1504 has an explicit no-args branch
    # that prints two example lines and falls through. The script then
    # exits with FINAL_EXIT_CODE=0 (no error). Pinning that contract.
    run oc_run e
    assert_success
    assert_output --partial "Please provide the command"
    assert_output --partial "exec|e"
    # Verify NO `docker exec` was issued — the help branch is purely
    # informational, it must not accidentally start a container exec.
    if grep -Fq "exec" "${STUB_DIR}/docker.log" 2>/dev/null; then
        # ps/inspect/compose probe calls are fine; only complain about exec.
        if grep -E '^exec |^[^ ]* exec ' "${STUB_DIR}/docker.log" >/dev/null; then
            cat "${STUB_DIR}/docker.log"
            fail "no-args exec accidentally issued a docker exec"
        fi
    fi
}
