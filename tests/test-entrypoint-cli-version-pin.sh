#!/usr/bin/env bash
# tests/test-entrypoint-cli-version-pin.sh
#
# The entrypoint must run @osaas/cli at the version pinned by OSAAS_CLI_VERSION
# (set once in each Dockerfile), never @latest, and fail fast when it is unset.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if grep -rn '@osaas/cli@latest' scripts Dockerfile Dockerfile.osc >/dev/null; then
  fail "@osaas/cli@latest still present"
else
  pass "no @osaas/cli@latest in scripts or Dockerfiles"
fi

for f in Dockerfile Dockerfile.osc; do
  if [ "$(grep -c '^ENV OSAAS_CLI_VERSION=[0-9][0-9.]*$' "$f")" = "1" ]; then
    pass "$f pins OSAAS_CLI_VERSION once"
  else
    fail "$f does not pin OSAAS_CLI_VERSION exactly once"
  fi
done

# Extract the package-spec expansion used by the npx call (the call itself
# redirects into temp files, so it is not run standalone).
expr=$(grep -m1 'timeout 60s npx -y' "$ENTRYPOINT" | grep -o '"@osaas/cli@\${OSAAS_CLI_VERSION:?[^}]*}"')
if [ -z "$expr" ]; then
  fail "could not extract the version expansion from the entrypoint"
else
  # Passing path: the pinned spec is what npx receives
  got=$(env -i OSAAS_CLI_VERSION=4.35.0 bash -c "echo $expr" 2>&1)
  if [ "$got" = "@osaas/cli@4.35.0" ]; then
    pass "npx uses the pinned @osaas/cli spec"
  else
    fail "npx did not use the pinned spec: $got"
  fi

  # Failing path: an unset version fails fast without running npx
  out=$(env -i bash -c "echo $expr" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'OSAAS_CLI_VERSION'; then
    pass "unset OSAAS_CLI_VERSION fails fast"
  else
    fail "unset OSAAS_CLI_VERSION did not fail fast (rc=$rc): $out"
  fi
fi

rm -rf "$STUB"
echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]
