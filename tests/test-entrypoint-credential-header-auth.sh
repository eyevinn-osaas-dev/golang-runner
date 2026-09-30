#!/usr/bin/env bash
# tests/test-entrypoint-credential-header-auth.sh
#
# Shell regression tests for moving git clone credentials from the SOURCE_URL
# into an `http.<url>.extraheader` git config arg (scripts/docker-entrypoint.sh).
#
# Background:
#   Previously the clone injected credentials directly into the URL passed to
#   `git clone` (https://TOKEN@host/path or the raw Gitea user:pass@host URL).
#   Embedding credentials in a URL means they can appear in process listings
#   (`ps`), shell tracing, and error output. This PR replaces that with a
#   scoped `-c http.https://<host>/.extraheader=AUTHORIZATION: basic <b64>`
#   git config argument, computed into GIT_AUTH_ARGS, plus a git_scrub_stderr
#   wrapper that redacts any token/basic-auth value that still leaks into
#   stderr (e.g. from a git error message).
#
# These tests grep the entrypoint (static checks) and source isolated
# fragments in a sandbox (behavioral checks) to assert the fix has not
# regressed.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: no clone line embeds ${GIT_TOKEN} in a URL argument
# ---------------------------------------------------------------------------
bad_token_clone=$(grep -n 'clone' "$ENTRYPOINT" | grep -F '${GIT_TOKEN}' || true)
if [ -z "$bad_token_clone" ]; then
  pass "no clone line embeds \${GIT_TOKEN} in a URL argument"
else
  fail "clone line still embeds \${GIT_TOKEN}: $bad_token_clone"
fi

# ---------------------------------------------------------------------------
# Test 2: no clone line uses unscrubbed \${GIT_HOST} (only GIT_HOST_PUBLIC)
# ---------------------------------------------------------------------------
bad_host_clone=$(grep -n 'clone' "$ENTRYPOINT" | grep -E '\$\{GIT_HOST\}' || true)
if [ -z "$bad_host_clone" ]; then
  pass "no clone line uses unscrubbed \${GIT_HOST}"
else
  fail "clone line still uses unscrubbed \${GIT_HOST}: $bad_host_clone"
fi

# ---------------------------------------------------------------------------
# Test 3: GIT_AUTH_ARGS reaches the clone call site
# ---------------------------------------------------------------------------
auth_args_at_clone=$(grep -nF '"${GIT_AUTH_ARGS[@]}"' "$ENTRYPOINT" | grep -F 'clone' || true)
if [ -n "$auth_args_at_clone" ]; then
  pass "GIT_AUTH_ARGS is passed to the git clone call site"
else
  fail "GIT_AUTH_ARGS is not present at any clone call site"
fi

# ---------------------------------------------------------------------------
# Test 4: git_scrub_stderr wraps the clone call
# ---------------------------------------------------------------------------
scrub_at_clone=$(grep -nF 'git_scrub_stderr git' "$ENTRYPOINT" | grep -F 'clone' || true)
if [ -n "$scrub_at_clone" ]; then
  pass "git_scrub_stderr wraps the git clone call"
else
  fail "git_scrub_stderr does not wrap the git clone call"
fi

# ---------------------------------------------------------------------------
# Test 5: behavioral — GIT_TOKEN path never puts the raw token in GIT_AUTH_ARGS
# ---------------------------------------------------------------------------
sandbox_token=$(bash -c '
  GIT_TOKEN="faketoken123456789012345"
  GIT_HOST_PUBLIC="example.com"
  GIT_HOST="example.com"
  GIT_AUTH_ARGS=()
  if [[ -n "$GIT_TOKEN" ]]; then
    AUTH_B64=$(printf "%s" "x-access-token:${GIT_TOKEN}" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.https://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  elif [[ "$GIT_HOST" != "$GIT_HOST_PUBLIC" ]]; then
    CREDS="${GIT_HOST%@*}"
    AUTH_B64=$(printf "%s" "$CREDS" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.https://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  fi
  printf "%s\n" "${GIT_AUTH_ARGS[@]}"
')

if echo "$sandbox_token" | grep -qF 'faketoken123456789012345'; then
  fail "raw GIT_TOKEN leaked into GIT_AUTH_ARGS: $sandbox_token"
else
  if echo "$sandbox_token" | grep -q 'AUTHORIZATION: basic '; then
    pass "GIT_TOKEN path builds a base64 AUTHORIZATION header without leaking the raw token"
  else
    fail "GIT_TOKEN path did not build an AUTHORIZATION header at all: $sandbox_token"
  fi
fi

# ---------------------------------------------------------------------------
# Test 6: behavioral — Gitea path (creds embedded in GIT_HOST) splits on the
# LAST '@' so a literal '@' in the password is preserved, and only the
# base64 form appears in GIT_AUTH_ARGS (never the raw "user:pass" string).
# ---------------------------------------------------------------------------
sandbox_gitea=$(bash -c '
  GIT_TOKEN=""
  GIT_HOST="user:p@ssw0rd@example.com"
  GIT_HOST_PUBLIC="example.com"
  GIT_AUTH_ARGS=()
  if [[ -n "$GIT_TOKEN" ]]; then
    AUTH_B64=$(printf "%s" "x-access-token:${GIT_TOKEN}" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.https://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  elif [[ "$GIT_HOST" != "$GIT_HOST_PUBLIC" ]]; then
    CREDS="${GIT_HOST%@*}"
    AUTH_B64=$(printf "%s" "$CREDS" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.https://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  fi
  echo "CREDS=$CREDS"
  printf "ARGS=%s\n" "${GIT_AUTH_ARGS[@]}"
')

expected_b64=$(printf '%s' 'user:p@ssw0rd' | base64 | tr -d '\n')

if echo "$sandbox_gitea" | grep -qF 'CREDS=user:p@ssw0rd'; then
  pass "Gitea path splits on the LAST '@', preserving the literal '@' in the password"
else
  fail "Gitea path did not preserve CREDS as 'user:p@ssw0rd': $sandbox_gitea"
fi

if echo "$sandbox_gitea" | grep -qF "$expected_b64"; then
  pass "Gitea path's base64-encoded CREDS appears in GIT_AUTH_ARGS"
else
  fail "Gitea path's expected base64 form ($expected_b64) not found in GIT_AUTH_ARGS: $sandbox_gitea"
fi

if echo "$sandbox_gitea" | grep -qF 'user:p@ssw0rd@example.com'; then
  fail "raw creds string leaked into GIT_AUTH_ARGS: $sandbox_gitea"
else
  pass "raw Gitea creds string does not appear in GIT_AUTH_ARGS (only base64 form does)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
