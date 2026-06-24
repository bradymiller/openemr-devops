# BATS: devtools passthrough — non-worktree subcommands that map to
# `docker exec -e <ENV_VAR> -i <CONTAINER_ID> /root/devtools <name>` via
# run_devtools_in_docker. Covers the explicit short-alias cases (pst, rd,
# cps, ut, ccc) and the default-case fall-through (any unknown subcommand
# is treated as a devtools name and dispatched the same way).
#
# We use -d to fix CONTAINER_ID deterministically; the auto-detect path
# is exercised in container_resolution.bats.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    STUB_DIR=$(oc_make_docker_stub_dir)
    CONTAINER=fixed-test-container
    export STUB_DIR CONTAINER
}

teardown() {
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

# Run openemr-cmd with -d fixed-test-container <subcommand>.
oc_dev() {
    env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -d "${CONTAINER}" "$@"
}

# Assert the recorded docker invocation includes 'exec', the container id,
# and '/root/devtools <name>'.
assert_devtools_dispatch() {
    local devtool_name=$1
    grep -Fq "exec" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "no docker exec recorded"; }
    grep -Fq "${CONTAINER}" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "container id missing from exec"; }
    grep -Fq "/root/devtools ${devtool_name}" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected '/root/devtools ${devtool_name}' invocation"; }
}

# --- explicit short-alias cases --------------------------------------------

@test "devtools: pst → /root/devtools phpstan" {
    run oc_dev pst
    assert_success
    assert_devtools_dispatch phpstan
}

@test "devtools: rd → /root/devtools rector-dry-run" {
    run oc_dev rd
    assert_success
    assert_devtools_dispatch rector-dry-run
}

@test "devtools: cps → /root/devtools codespell (codespell long-form too)" {
    run oc_dev cps
    assert_success
    assert_devtools_dispatch codespell
    : > "${STUB_DIR}/docker.log"
    # The long alias 'codespell' should route the same way (cps|codespell case).
    run oc_dev codespell
    assert_success
    assert_devtools_dispatch codespell
}

@test "devtools: ut → /root/devtools unit-test" {
    run oc_dev ut
    assert_success
    assert_devtools_dispatch unit-test
}

@test "devtools: ccc → /root/devtools conventional-commits-check" {
    run oc_dev ccc
    assert_success
    assert_devtools_dispatch conventional-commits-check
    : > "${STUB_DIR}/docker.log"
    run oc_dev conventional-commits-check
    assert_success
    assert_devtools_dispatch conventional-commits-check
}

@test "devtools: cq → /root/devtools code-quality" {
    run oc_dev cq
    assert_success
    assert_devtools_dispatch code-quality
}

# --- default-case fall-through ---------------------------------------------
# The 'esac' default at line ~2375 dispatches any unknown subcommand as a
# devtools call: `run_devtools_in_docker CONTAINER_ID FIRST_ARG`. This is
# what makes new devtools commands work without script edits — useful when
# the in-container devtools script gains a new subcommand but the host CLI
# hasn't been updated. Pinning the behavior so it doesn't accidentally
# regress to "Unknown command" + exit.

@test "devtools default-case: 'arbitrary-new-tool' → /root/devtools arbitrary-new-tool" {
    run oc_dev arbitrary-new-tool
    assert_success
    assert_devtools_dispatch arbitrary-new-tool
}

# --- env var pass-through (run_devtools_in_docker -e ENV_VAR) --------------
# run_devtools_in_docker invokes `docker exec -e "${ENV_VAR}" -i <id> ...`.
# ENV_VAR is set to a real value for some subcommands (e.g. irp sets
# OPENEMR_ENABLE_CCDA_IMPORT=1 at line ~1671). Pin that the -e flag is
# in the recorded invocation.

@test "devtools: -e ENV_VAR is passed to docker exec" {
    run oc_dev pst
    assert_success
    grep -Fq "exec -e" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'docker exec -e' invocation"; }
}
