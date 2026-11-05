#!/usr/bin/env bash
# tests/test-entrypoint-build-failure.sh
#
# Regression test: under `set -e` a failing build command must not abort the
# entrypoint; it must reach the BUILD_EXIT check and exec the loading server in
# failed mode (scripts/docker-entrypoint.sh). Extracts the build phase, stubs
# go/node/mkdir on PATH, and runs it under `bash -e`.
# ENTRYPOINT may be overridden to check another copy of the script.

ENTRYPOINT="${ENTRYPOINT:-scripts/docker-entrypoint.sh}"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/src/cmd/server"

cat > "$SANDBOX/bin/go" <<'S'
#!/bin/bash
exit "${GO_STUB_EXIT:-0}"
S
cat > "$SANDBOX/bin/node" <<'S'
#!/bin/bash
echo "node $*" > "$NODE_LOG"
exit 0
S
cat > "$SANDBOX/bin/mkdir" <<'S'
#!/bin/bash
exit 0
S
chmod +x "$SANDBOX/bin/"*

# Build phase through the failed-mode branch (exclude the run phase header).
{
  echo 'set -e'
  echo 'LOADING_PID=999999'
  echo "BUILD_DIR=\"$SANDBOX/src\""
  sed -n '/^# ---- Build phase ----/,/^# ---- Run phase ----/p' "$ENTRYPOINT" | sed '$d'
  echo 'echo "REACHED_RUN_PHASE"'
} > "$SANDBOX/phase.sh"

run_case() {
  # $1=label $2=GO_STUB_EXIT $3=expect failed mode (yes|no) $4=OSC_BUILD_CMD
  : > "$SANDBOX/node.log"
  out=$(cd "$SANDBOX/src" && PATH="$SANDBOX/bin:$PATH" NODE_LOG="$SANDBOX/node.log" \
    GO_STUB_EXIT="$2" OSC_BUILD_CMD="$4" bash "$SANDBOX/phase.sh" 2>&1)
  log=$(cat "$SANDBOX/node.log")
  if [ "$3" = "yes" ]; then
    if [[ "$log" == *"error-page.html failed"* ]]; then pass "$1"; else fail "$1 (node log: '$log'; out: $out)"; fi
  else
    if [ -z "$log" ] && [[ "$out" == *REACHED_RUN_PHASE* ]]; then pass "$1"; else fail "$1 (node log: '$log'; out: $out)"; fi
  fi
}

touch "$SANDBOX/src/cmd/server/main.go"
run_case "failing go build (cmd/server) reaches failed mode" 1 yes ""
run_case "successful go build proceeds to run phase" 0 no ""
run_case "failing OSC_BUILD_CMD reaches failed mode" 0 yes "false"
run_case "successful OSC_BUILD_CMD proceeds to run phase" 0 no "true"

rm "$SANDBOX/src/cmd/server/main.go"
mkdir -p "$SANDBOX/src/cmd/api"
touch "$SANDBOX/src/cmd/api/main.go"
run_case "failing go build (cmd/*) reaches failed mode" 1 yes ""
rm -r "$SANDBOX/src/cmd"
touch "$SANDBOX/src/main.go"
run_case "failing go build (main.go) reaches failed mode" 1 yes ""
rm "$SANDBOX/src/main.go"
run_case "failing go build (./...) reaches failed mode" 1 yes ""

echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]
