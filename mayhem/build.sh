#!/usr/bin/env bash
#
# mayhem/build.sh — build bloaty's libFuzzer harness (tests/fuzz_target.cc), its standalone
# reproducer, and the upstream gtest suite. Runs in the commit image as `mayhem` in /mayhem, and
# re-runs offline at the PATCH tier: every dependency is a git submodule under third_party/ that
# is already checked out, so nothing is fetched (the system-package lookups are switched off).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

CMAKE_COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release
  -DBLOATY_PREFER_SYSTEM_ABSL=OFF -DBLOATY_PREFER_SYSTEM_CAPSTONE=OFF
  -DBLOATY_PREFER_SYSTEM_PROTOBUF=OFF -DBLOATY_PREFER_SYSTEM_RE2=OFF
  -DBLOATY_PREFER_SYSTEM_ZLIB=OFF -DBLOATY_PREFER_SYSTEM_ZSTD=OFF
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX")

# 1) Sanitized fuzz build. Upstream's CMakeLists builds `fuzz_target` (instead of `bloaty`) when
#    LIB_FUZZING_ENGINE is in the environment, and overwrites CMAKE_CXX_FLAGS but appends $CXXFLAGS
#    (which also seeds the bundled third_party projects), so the flags travel through CXXFLAGS.
#    fuzzer-no-link adds libFuzzer coverage instrumentation to libbloaty and its deps.
FUZZ_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
mkdir -p build-fuzz
CXXFLAGS="$FUZZ_FLAGS" cmake -S . -B build-fuzz "${CMAKE_COMMON[@]}" -DBUILD_TESTING=OFF \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS"
CXXFLAGS="$FUZZ_FLAGS" ninja -C build-fuzz -j"$MAYHEM_JOBS" fuzz_target

# 2) Relink the harness: the fuzzer binary with the LeakSanitizer-off hook, and a run-once
#    reproducer driven by the project's own file-input driver (tests/fuzz_driver.cc), which
#    supplies main(); it links libFuzzer's no-main runtime only for the coverage callbacks the
#    instrumented objects reference.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-fuzz/lsan_off.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++20 -c tests/fuzz_driver.cc -o build-fuzz/fuzz_driver.o
FUZZER_NO_MAIN="$($CC --print-resource-dir)/lib/linux/libclang_rt.fuzzer_no_main-$(uname -m).a"
LINK_CMD="$(ninja -C build-fuzz -t commands fuzz_target | tail -n 1)"
relink() { # <output> <engine flags> <extra objects...>
  local out="$1" engine="$2"; shift 2
  local cmd="${LINK_CMD//-o fuzz_target /-o $out $* }"
  cmd="${cmd//-fsanitize=fuzzer /$engine }"
  (cd build-fuzz && bash -c "$cmd")
}
relink "$SRC/fuzz_target" "-fsanitize=fuzzer" "$SRC/build-fuzz/lsan_off.o"
relink "$SRC/fuzz_target-standalone" "-fsanitize=fuzzer-no-link $FUZZER_NO_MAIN" \
  "$SRC/build-fuzz/lsan_off.o $SRC/build-fuzz/fuzz_driver.o"

# 3) Upstream test suite, built with the project's NORMAL flags (no sanitizers) in its own tree.
#    LIB_FUZZING_ENGINE must be absent or CMake builds only the fuzz target.
mkdir -p build-tests
env -u LIB_FUZZING_ENGINE CXXFLAGS="$COVERAGE_FLAGS" cmake -S . -B build-tests "${CMAKE_COMMON[@]}" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_TESTING=ON -DCMAKE_C_FLAGS="$COVERAGE_FLAGS"
env -u LIB_FUZZING_ENGINE CXXFLAGS="$COVERAGE_FLAGS" ninja -C build-tests -j"$MAYHEM_JOBS" \
  bloaty bloaty_test bloaty_test_pe bloaty_misc_test range_map_test
