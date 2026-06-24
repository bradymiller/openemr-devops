# BATS: macOS-only diagnostic. Captures actual mtime behavior through
# touch + dir-rename on the macos-14 runner to diagnose the race in
# state_lock.bats's "lost RMW" test. To be deleted (or converted into
# a portable workaround) once root cause is understood.
#
# Skipped on non-macOS.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    [[ "$OSTYPE" == darwin* ]] || skip "diagnostic-only; macOS path"
    TMP_ROOT=$(oc_mktempdir)
    export TMP_ROOT
}

teardown() {
    [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
    return 0
}

@test "DIAG-macOS: touch -t backdates dir mtime as expected (~946684800 = 2000-01-01 UTC)" {
    local d="${TMP_ROOT}/touchtest"
    mkdir "$d"
    touch -t 200001010000 "$d"
    local m
    m=$(stat -f %m "$d")
    echo "stat -f %m = ${m}"
    echo "expected   = 946684800 (give or take TZ offset)"
    # Allow for timezone variance — accept anything in the 1999-2001 range.
    [[ "${m}" -lt 1000000000 ]] || fail "mtime ${m} > 2001 — touch -t didn't backdate"
}

@test "DIAG-macOS: mv (dir rename) preservation of mtime" {
    local d1="${TMP_ROOT}/dir1" d2="${TMP_ROOT}/dir2"
    mkdir "$d1"
    touch -t 200001010000 "$d1"
    local before
    before=$(stat -f %m "$d1")
    echo "BEFORE mv: stat -f %m d1 = ${before}"

    mv "$d1" "$d2"
    local after
    after=$(stat -f %m "$d2")
    echo "AFTER mv:  stat -f %m d2 = ${after}"

    echo "delta = $((after - before))"
    [[ "${after}" = "${before}" ]] \
        || fail "mv updated mtime (delta=$((after - before))); rename(2) was expected to preserve"
}

@test "DIAG-macOS: full state_lock scenario — manually create stale lockdir, mv-steal, verify mtime" {
    local lock="${TMP_ROOT}/lock"
    mkdir "$lock"
    echo 99999 > "$lock/holder"
    touch -t 200001010000 "$lock"
    local mtime_initial
    mtime_initial=$(stat -f %m "$lock")
    echo "INITIAL: mtime=${mtime_initial}"

    local steal="${TMP_ROOT}/steal"
    mv "$lock" "$steal"
    local mtime_after_mv
    mtime_after_mv=$(stat -f %m "$steal")
    echo "AFTER mv: mtime=${mtime_after_mv}"

    local now
    now=$(date +%s)
    local age=$((now - mtime_after_mv))
    echo "now=${now}, age=${age}"

    # The state_lock steal logic computes `actual_age > WT_STATE_LOCK_STALE_S`
    # (default 120). If macOS preserves mtime correctly, age should be ~25 years.
    if (( age < 120 )); then
        echo "FAIL signal: age (${age}) is below stale threshold (120); the"
        echo "  state_lock steal would NOT recognize this as still stale,"
        echo "  triggering put-back and infinite-loop-into-timeout."
        fail "macOS mv apparently updated mtime; steal verify is broken under this assumption"
    fi
}
