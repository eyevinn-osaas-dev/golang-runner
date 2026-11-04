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

# Extract the npx invocation line and run it with stub npx/timeout binaries.
LINE=$(grep -m1 'timeout 60s npx -y' "$ENTRYPOINT" | sed -E 's/^ *if //; s/; then *$//')
STUB=$(mktemp -d)
printf '#!/bin/sh\necho "NPX:$*"\n' > "$STUB/npx"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$STUB/timeout"
chmod +x "$STUB/npx" "$STUB/timeout"

# Passing path: the pinned spec is used
out=$(env -i PATH="$STUB:$PATH" OSAAS_CLI_VERSION=4.35.0 CONFIG_SVC=store bash -c "$LINE; echo \"\$config_env_output\"" 2>&1)
if echo "$out" | grep -qF 'NPX:-y @osaas/cli@4.35.0 web'; then
  pass "npx uses the pinned @osaas/cli spec"
else
  fail "npx did not use the pinned spec: $out"
fi

# Failing path: an unset version fails fast without running npx
out=$(env -i PATH="$STUB:$PATH" CONFIG_SVC=store bash -c "if $LINE; then echo reached; else echo failed; fi" 2>&1)
rc=$?
if echo "$out" | grep -q "^failed" && ! echo "$out" | grep -q "NPX:" && echo "$out" | grep -q 'OSAAS_CLI_VERSION'; then
  pass "unset OSAAS_CLI_VERSION fails fast"
else
  fail "unset OSAAS_CLI_VERSION did not fail fast (rc=$rc): $out"
fi

rm -rf "$STUB"
echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]
