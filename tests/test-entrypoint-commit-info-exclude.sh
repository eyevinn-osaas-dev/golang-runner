#!/usr/bin/env bash
# tests/test-entrypoint-commit-info-exclude.sh
#
# .commit-info.json written by the entrypoint must not show up in
# `git status --porcelain` of the user's checkout (info/exclude, not .gitignore).
# The entrypoint runs from /runner, so the test calls from a different cwd.

ENTRYPOINT="${ENTRYPOINT:-scripts/docker-entrypoint.sh}"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FUNCS="$TMP/funcs.sh"
{
  sed -n '/^exclude_from_git_status() {/,/^}/p' "$ENTRYPOINT"
  sed -n '/^write_commit_info() {/,/^}/p' "$ENTRYPOINT"
} > "$FUNCS"

REPO="$TMP/repo"
CALLER="$TMP/caller"
mkdir -p "$REPO" "$CALLER"
git -C "$REPO" init -q
echo hi > "$REPO/a.txt"
mkdir -p "$REPO/.git/info"
echo "user-rule" > "$REPO/.git/info/exclude"
git -C "$REPO" add a.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m init
BEFORE="$(git -C "$REPO" rev-list --count HEAD)"

( cd "$CALLER" && source "$FUNCS" && write_commit_info "$REPO" >/dev/null && write_commit_info "$REPO" >/dev/null )

if [ -f "$REPO/.commit-info.json" ] && grep -q '"sha"' "$REPO/.commit-info.json"; then pass "commit info written"; else fail "commit info written"; fi
if [ -z "$(git -C "$REPO" status --porcelain)" ]; then pass "git status clean"; else fail "git status clean"; fi
if [ "$(grep -cxF .commit-info.json "$REPO/.git/info/exclude")" = 1 ]; then pass "exclude entry idempotent"; else fail "exclude entry idempotent"; fi
if grep -qxF user-rule "$REPO/.git/info/exclude"; then pass "user rules survive"; else fail "user rules survive"; fi
if [ "$(git -C "$REPO" rev-list --count HEAD)" = "$BEFORE" ] && [ ! -e "$REPO/.gitignore" ] \
  && git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet; then
  pass "no tracked changes or commits"
else
  fail "no tracked changes or commits"
fi
if [ ! -e "$CALLER/.git" ]; then pass "caller cwd clean"; else fail "caller cwd clean"; fi
OUT="$( ( set -e; cd "$CALLER"; source "$FUNCS"; exclude_from_git_status "$TMP/not-a-repo" x; echo reached ) )"
if [ "$OUT" = reached ]; then pass "set -e safe"; else fail "set -e safe"; fi

echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]
