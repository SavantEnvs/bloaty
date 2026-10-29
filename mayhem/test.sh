#!/usr/bin/env bash
#
# mayhem/test.sh — RUN upstream's gtest suites (built by mayhem/build.sh in build-tests/) and the
# `bloaty` CLI on a known fixture. Counts come from each gtest binary's own summary and a missing
# summary counts as a failure, so a program neutered to exit(0) cannot pass.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

B="$SRC/build-tests"
passed=0 failed=0 skipped=0

# run_gtest <binary> <workdir>: add the binary's reported counts; no summary line => 1 failure.
run_gtest() {
  local bin="$1" dir="$2" out p f s
  if [ ! -x "$B/$bin" ]; then echo "missing $B/$bin — mayhem/build.sh must build it" >&2; failed=$((failed+1)); return; fi
  out="$(cd "$SRC/tests/testdata/$dir" && "$B/$bin" 2>&1)"; local rc=$?
  printf '%s\n' "$out" | tail -n 15
  p="$(printf '%s\n' "$out" | sed -nE 's/^\[  PASSED  \] ([0-9]+) tests?\..*/\1/p' | tail -n1)"
  f="$(printf '%s\n' "$out" | sed -nE 's/^\[  FAILED  \] ([0-9]+) tests?, listed below:.*/\1/p' | tail -n1)"
  s="$(printf '%s\n' "$out" | sed -nE 's/^\[  SKIPPED \] ([0-9]+) tests?, listed below:.*/\1/p' | tail -n1)"
  if [ -z "$p" ]; then failed=$((failed+1)); return; fi
  passed=$((passed+p)); failed=$((failed+${f:-0})); skipped=$((skipped+${s:-0}))
  [ "$rc" -eq 0 ] || [ "${f:-0}" -gt 0 ] || failed=$((failed+1))
}

run_gtest range_map_test .
run_gtest bloaty_test linux-x86_64
run_gtest bloaty_test linux-x86
run_gtest bloaty_test_pe PE/x64
run_gtest bloaty_test_pe PE/x86
run_gtest bloaty_misc_test misc

# Known-answer check on the CLI: the section sizes bloaty reports for a committed fixture.
csv="$("$B/bloaty" -d sections -n 0 --csv "$SRC/tests/testdata/linux-x86_64/05-binary.bin" 2>&1)"
if [ "$(printf '%s\n' "$csv" | head -n1)" = 'sections,vmsize,filesize' ] \
   && printf '%s\n' "$csv" | grep -qx '\.text,436,436' \
   && printf '%s\n' "$csv" | grep -qx '\.data,4036,4036'; then
  passed=$((passed+1))
else
  echo "bloaty CLI known-answer check failed; output was:" >&2; printf '%s\n' "$csv" | head >&2
  failed=$((failed+1))
fi

emit_ctrf gtest "$passed" "$failed" "$skipped"
