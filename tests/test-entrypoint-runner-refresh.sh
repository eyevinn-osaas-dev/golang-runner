#!/usr/bin/env bash
# tests/test-entrypoint-runner-refresh.sh
#
# Behavioural tests for the runner-refresh exchange in
# scripts/docker-entrypoint.sh (between "BEGIN runner-refresh" and
# "END runner-refresh") together with the config-load block that consumes it.
#
# Both real blocks are extracted and run under `set -e` with stub `curl`,
# `npx`, `timeout`, `sleep` (and, for the 127 case, `jq`). Contract (Stage 1,
# python-runner#39 / golang-runner#32):
#   - the exchange POSTs {"token": "<orig>"} as the body, no Authorization
#     header, and the token never appears in curl's argv
#   - on 200 with a non-empty .token, config-to-env (npx) runs with the FRESH
#     token, while the shell/app keeps the ORIGINAL OSC_ACCESS_TOKEN and gains
#     OSC_REFRESH_TOKEN
#   - every failure (401, 5xx, timeout, empty/unparsable body, jq exiting 127)
#     logs a [CONFIG] WARNING and config-to-env runs with the original token

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

refresh_block=$(awk '/^# BEGIN runner-refresh/,/^# END runner-refresh/' "$ENTRYPOINT")
config_block=$(awk '/^# BEGIN config-load/,/^# END config-load/' "$ENTRYPOINT")
if [ -z "$refresh_block" ] || [ -z "$config_block" ]; then
  echo "FAIL: could not extract blocks from $ENTRYPOINT"
  exit 1
fi

unset CONFIG_SVC OSC_ACCESS_TOKEN OSC_ENV OSC_REFRESH_TOKEN
SB=$(mktemp -d)
export SB
mkdir -p "$SB/bin" "$SB/nojq"
printf '%s\n' "$refresh_block" > "$SB/refresh.sh"
printf '%s\n' "$config_block" > "$SB/config.sh"

# curl stub: n-th call reads curl<n>.out (body) and curl<n>.code (HTTP code,
# empty/absent = connection failure, exit 28). Records argv and the body file.
cat > "$SB/bin/curl" <<'EOF'
#!/bin/bash
n=$(cat "$SB/ccount" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$SB/ccount"
echo "$*" >> "$SB/curlargs"
for a in "$@"; do
  case "$a" in @*) cat "${a#@}" >> "$SB/curlbody"; echo >> "$SB/curlbody" ;; esac
done
if [ -s "$SB/curl$n.code" ]; then
  [ -f "$SB/curl$n.out" ] && cat "$SB/curl$n.out"
  printf '\n%s' "$(cat "$SB/curl$n.code")"
  exit 0
fi
exit 28
EOF
# npx stub: records the OSC_ACCESS_TOKEN it sees in its environment
cat > "$SB/bin/npx" <<'EOF'
#!/bin/bash
echo "npx_token=${OSC_ACCESS_TOKEN:-}" >> "$SB/npxenv"
echo "$*" >> "$SB/npxargs"
[ -f "$SB/npx.out" ] && cat "$SB/npx.out"
exit 0
EOF
cat > "$SB/bin/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
cat > "$SB/bin/sleep" <<'EOF'
#!/bin/bash
echo "$@" >> "$SB/sleeps"
exit 0
EOF
cat > "$SB/bin/node" <<'EOF'
#!/bin/bash
exit 0
EOF
# jq stub that is "missing" (command not found semantics, exit 127)
cat > "$SB/nojq/jq" <<'EOF'
#!/bin/bash
exit 127
EOF
chmod +x "$SB/bin/"* "$SB/nojq/jq"

cat > "$SB/harness.sh" <<'EOF'
#!/bin/bash
set -e
if [ -n "${STUB_JQ_127:-}" ]; then
  export PATH="$SB/bin:$SB/nojq:$PATH"
else
  export PATH="$SB/bin:$PATH"
fi
OSAAS_CLI_VERSION=1.2.3
exec() { echo "EXEC_FAILED_STATE: $*"; exit 42; }
source "$SB/refresh.sh"
source "$SB/config.sh"
echo "REACHED_BUILD"
echo "SHELL_TOKEN=${OSC_ACCESS_TOKEN:-}"
echo "SHELL_REFRESH=${OSC_REFRESH_TOKEN-unset}"
echo "FRESH_EXPORTED=$(env | grep -c '^config_access_token=' || true)"
EOF

reset() { rm -f "$SB"/curl* "$SB/ccount" "$SB/sleeps" "$SB/npxenv" "$SB/npxargs" "$SB/npx.out"; echo 'export FOO=bar' > "$SB/npx.out"; }
run() {
  OUT=$(CONFIG_SVC="${CONFIG_SVC-mystore}" OSC_ACCESS_TOKEN="${OSC_ACCESS_TOKEN-orig.runner.tok}" \
    OSC_ENV="${OSC_ENV-dev}" STUB_JQ_127="${STUB_JQ_127:-}" bash "$SB/harness.sh" 2>&1)
  CODE=$?
  CALLS=$(cat "$SB/ccount" 2>/dev/null || echo 0)
}
# expect_original <name> <warning-substring> <refresh-token-state>
expect_original() {
  local name="$1" warn="$2" refresh="$3"
  if [ "$CODE" -eq 0 ] && echo "$OUT" | grep -q "\[CONFIG\] WARNING: $warn" \
     && grep -q '^npx_token=orig.runner.tok$' "$SB/npxenv" \
     && echo "$OUT" | grep -q 'SHELL_TOKEN=orig.runner.tok' \
     && echo "$OUT" | grep -q "SHELL_REFRESH=$refresh" \
     && echo "$OUT" | grep -q 'Loaded 1 environment variable(s)' \
     && ! echo "$OUT" | grep -q 'EXEC_FAILED_STATE'; then
    pass "$name: warning logged, original token used, config still loaded"
  else
    fail "$name (code=$CODE)"; echo "$OUT"; cat "$SB/npxenv" 2>/dev/null
  fi
}

# 1. success: fresh token used by config-to-env, app keeps the original
reset
printf '{"token":"fresh.pat.tok","expiresIn":3600}' > "$SB/curl1.out"; echo 200 > "$SB/curl1.code"
run
if [ "$CODE" -eq 0 ] && echo "$OUT" | grep -q 'Refreshed access token via runner refresh token' \
   && grep -q '^npx_token=fresh.pat.tok$' "$SB/npxenv" \
   && echo "$OUT" | grep -q 'SHELL_TOKEN=orig.runner.tok' \
   && echo "$OUT" | grep -q 'SHELL_REFRESH=orig.runner.tok' \
   && echo "$OUT" | grep -q 'FRESH_EXPORTED=0' \
   && echo "$OUT" | grep -q 'Loaded 1 environment variable(s)'; then
  pass "success: config-to-env uses the fresh token, app keeps original, OSC_REFRESH_TOKEN set"
else
  fail "success (code=$CODE)"; echo "$OUT"; cat "$SB/npxenv" 2>/dev/null
fi
[ "$CALLS" -eq 1 ] && pass "success: single request" || fail "success: calls=$CALLS"

# 1b. request shape: JSON body, no Authorization header, token not in argv
if grep -q '^{"token":"orig.runner.tok"}$' "$SB/curlbody" \
   && ! grep -qi 'authorization' "$SB/curlargs" \
   && ! grep -q 'orig.runner.tok' "$SB/curlargs" \
   && grep -q 'https://token.svc.dev.osaas.io/runner-token/refresh' "$SB/curlargs" \
   && grep -q -- '--max-time 10' "$SB/curlargs"; then
  pass "request: JSON body from file, no Authorization header, token not in argv"
else
  fail "request shape"; cat "$SB/curlargs" "$SB/curlbody"
fi

# 2. 401 expired: not retried, original token
reset
echo '{"code":"refresh_token_expired"}' > "$SB/curl1.out"; echo 401 > "$SB/curl1.code"
run
expect_original "401 expired" "runner refresh token is refresh_token_expired" "unset"
[ "$CALLS" -eq 1 ] && pass "401: not retried" || fail "401: calls=$CALLS"

# 3. 401 invalid (e.g. classic PAT)
reset
echo '{"code":"refresh_token_invalid"}' > "$SB/curl1.out"; echo 401 > "$SB/curl1.code"
run
expect_original "401 invalid" "OSC_ACCESS_TOKEN is not a runner refresh token" "unset"

# 4. 500 x3: retried with 3s backoff
reset
for i in 1 2 3; do echo 500 > "$SB/curl$i.code"; done
run
expect_original "500 x3" "runner token exchange failed (HTTP '500')" "orig.runner.tok"
[ "$CALLS" -eq 3 ] && [ "$(wc -l < "$SB/sleeps")" -eq 2 ] && pass "500: 3 attempts with backoff" || fail "500: calls=$CALLS"

# 5. 200 with {} and with empty token
reset
echo '{}' > "$SB/curl1.out"; echo 200 > "$SB/curl1.code"
run
expect_original "200 without token key" "runner token exchange failed (HTTP '200')" "orig.runner.tok"
reset
echo '{"token":""}' > "$SB/curl1.out"; echo 200 > "$SB/curl1.code"
run
expect_original "200 with empty token" "runner token exchange failed (HTTP '200')" "orig.runner.tok"

# 6. timeout / no HTTP code
reset
run
expect_original "no HTTP code" "runner token exchange failed (HTTP '')" "orig.runner.tok"
[ "$CALLS" -eq 3 ] && pass "no HTTP code: 3 attempts" || fail "no HTTP code: calls=$CALLS"

# 7. jq exits 127 on a 200: must not use the fresh token, must not go tokenless
reset
printf '{"token":"fresh.pat.tok","expiresIn":3600}' > "$SB/curl1.out"; echo 200 > "$SB/curl1.code"
STUB_JQ_127=1 run
expect_original "jq exits 127" "runner token exchange failed (HTTP '200')" "orig.runner.tok"

# 8. skip: no OSC_ENV or no token -> no request
reset
OSC_ENV="" run
if [ "$CODE" -eq 0 ] && [ "$CALLS" -eq 0 ]; then pass "no OSC_ENV: exchange skipped"; else fail "no OSC_ENV (code=$CODE calls=$CALLS)"; echo "$OUT"; fi

# 9. the refresh token never appears in any log line
reset
printf '{"token":"fresh.pat.tok","expiresIn":3600}' > "$SB/curl1.out"; echo 200 > "$SB/curl1.code"
run
if echo "$OUT" | grep -v '^SHELL_' | grep -q 'fresh.pat.tok\|orig.runner.tok'; then
  fail "token leaked into logs"
else
  pass "fresh token not printed"
fi

# 10. entrypoint never assigns OSC_ACCESS_TOKEN= inside the refresh block (Stage 2 swap)
if awk '/^# BEGIN runner-refresh/,/^# END runner-refresh/' "$ENTRYPOINT" | grep -Eq '^[[:space:]]*(export )?OSC_ACCESS_TOKEN='; then
  fail "refresh block assigns OSC_ACCESS_TOKEN (Stage 2 not allowed)"
else
  pass "refresh block does not assign OSC_ACCESS_TOKEN"
fi

rm -rf "$SB"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
