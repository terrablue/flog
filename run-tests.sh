#!/bin/bash

set -u

binary=${FLOG_BIN:-zig-out/bin/flog}
passed=0
failed=0

run_test() {
  name=$1
  expected=$2
  shift 2
  output=$("$binary" "$@" 2>/dev/null)
  status=$?
  if [ "$status" -eq 0 ] && [ "$output" = "$expected" ]; then
    printf 'passed %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'failed %s (status=%s, output=%s)\n' "$name" "$status" "$output"
    failed=$((failed + 1))
  fi
}

run_test basic "." test/top-level-await/main.js
run_test imports $'.\n.' test/imports/main.js
run_test eval "3" -e 'log(1 + 2)'

printf '\ntotals\n=======\npassed %s\nfailed %s\n' "$passed" "$failed"
test "$failed" -eq 0
