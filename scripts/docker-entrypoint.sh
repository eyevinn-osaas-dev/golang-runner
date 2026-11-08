#!/bin/bash
set -e

PORT=${PORT:-8080}
WORK_DIR="/usercontent/app"

# Start loading server to show build status
node /runner/loading-server.js &
LOADING_PID=$!

cleanup() {
  kill $LOADING_PID 2>/dev/null || true
}
trap cleanup EXIT

# Hide a platform-written file from `git status` without touching tracked files.
exclude_from_git_status() {
  local repo_dir="$1" name="$2" excl
  excl="$(git -C "$repo_dir" rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  [ -n "$excl" ] || return 0
  # git prints this path relative to the -C directory, not to this script's cwd (/runner)
  case "$excl" in /*) ;; *) excl="$repo_dir/$excl" ;; esac
  mkdir -p "$(dirname "$excl")" 2>/dev/null || return 0
  grep -qxF "$name" "$excl" 2>/dev/null || echo "$name" >> "$excl" 2>/dev/null || true
}

# Write commit metadata to a well-known file for platform visibility
write_commit_info() {
  local repo_dir="$1"
  if [ -d "$repo_dir/.git" ]; then
    local sha shortSha msg author date recentCommits
    sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || return 0
    shortSha=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null) || return 0
    msg=$(git -C "$repo_dir" log -1 --format='%s' 2>/dev/null) || return 0
    author=$(git -C "$repo_dir" log -1 --format='%an' 2>/dev/null) || return 0
    date=$(git -C "$repo_dir" log -1 --format='%aI' 2>/dev/null) || return 0
    recentCommits=$(git -C "$repo_dir" log -5 --format='%H' 2>/dev/null | while read -r c_sha; do
      jq -n \
        --arg sha "$c_sha" \
        --arg shortSha "$(git -C "$repo_dir" rev-parse --short "$c_sha" 2>/dev/null)" \
        --arg message "$(git -C "$repo_dir" log -1 --format='%s' "$c_sha" 2>/dev/null)" \
        --arg author "$(git -C "$repo_dir" log -1 --format='%an' "$c_sha" 2>/dev/null)" \
        --arg date "$(git -C "$repo_dir" log -1 --format='%aI' "$c_sha" 2>/dev/null)" \
        '{sha:$sha,shortSha:$shortSha,message:$message,author:$author,date:$date}'
    done | jq -s '.' 2>/dev/null) || recentCommits='[]'
    jq -n \
      --arg sha "$sha" \
      --arg shortSha "$shortSha" \
      --arg message "$msg" \
      --arg author "$author" \
      --arg date "$date" \
      --argjson recentCommits "$recentCommits" \
      '{sha:$sha,shortSha:$shortSha,message:$message,author:$author,date:$date,recentCommits:$recentCommits}' \
      > "$repo_dir/.commit-info.json" 2>/dev/null || true
    exclude_from_git_status "$repo_dir" .commit-info.json
    echo "Commit info: $(jq -r '.shortSha + " - " + .message' "$repo_dir/.commit-info.json" 2>/dev/null || echo 'unavailable')"
  fi
}

# ---- Clone phase ----
SOURCE_URL="${SOURCE_URL:-$GITHUB_URL}"
if [[ -z "$SOURCE_URL" ]]; then
  echo "ERROR: SOURCE_URL (or GITHUB_URL) is required" >&2
  kill $LOADING_PID 2>/dev/null || true
  exec node /runner/loading-server.js error-page.html failed
fi

# Extract branch from URL fragment
BRANCH=""
if [[ "$SOURCE_URL" == *"#"* ]]; then
  BRANCH="${SOURCE_URL#*#}"
  SOURCE_URL="${SOURCE_URL%%#*}"
fi

# Parse URL components — needed for both token injection and credential scrubbing
GIT_HOST="${SOURCE_URL#*://}"   # strip scheme
GIT_HOST="${GIT_HOST%%/*}"      # keep only the hostname (may include user:pass@ if SOURCE_URL embeds credentials)
# Variant with any embedded credentials stripped — used for log lines and the
# persisted remote URL so that PATs never leak into pod logs or .git/config.
# When SOURCE_URL has no credentials, this is identical to GIT_HOST.
GIT_HOST_PUBLIC="${GIT_HOST##*@}"
GIT_PATH="/${SOURCE_URL#*://*/}"
[[ "/${SOURCE_URL}" == "${GIT_PATH}" ]] && GIT_PATH="/"
PROTOCOL="${SOURCE_URL%%://*}"

# Build git auth args so credentials never appear in SOURCE_URL, process
# listings, or shell history — passed via `-c http.<url>.extraheader` instead.
GIT_TOKEN="${GIT_TOKEN:-$GITHUB_TOKEN}"
GIT_AUTH_ARGS=()
if [[ -n "$GIT_TOKEN" ]]; then
  AUTH_B64=$(printf '%s' "x-access-token:${GIT_TOKEN}" | base64 | tr -d '\n')
  GIT_AUTH_ARGS=(-c "http.https://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
elif [[ "$GIT_HOST" != "$GIT_HOST_PUBLIC" ]]; then
  CREDS="${GIT_HOST%@*}"
  AUTH_B64=$(printf '%s' "$CREDS" | base64 | tr -d '\n')
  GIT_AUTH_ARGS=(-c "http.https://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
fi

git_scrub_stderr() {
  "$@" 2> >(sed -r 's/gh[pso]_[A-Za-z0-9]{20,}/[REDACTED]/g; s/([Bb]asic )[A-Za-z0-9+\/=]{8,}/\1[REDACTED]/g' >&2)
}

rm -rf "$WORK_DIR"
echo "cloning https://${GIT_HOST_PUBLIC}${GIT_PATH}"
if [[ -n "$BRANCH" ]]; then
  git_scrub_stderr git "${GIT_AUTH_ARGS[@]}" clone --branch "$BRANCH" --depth 1 "https://${GIT_HOST_PUBLIC}${GIT_PATH}" "$WORK_DIR"
else
  git_scrub_stderr git "${GIT_AUTH_ARGS[@]}" clone --depth 1 "https://${GIT_HOST_PUBLIC}${GIT_PATH}" "$WORK_DIR"
fi

# Scrub credentials from origin remote — PAT must not persist to .git/config.
# Uses GIT_HOST_PUBLIC which has any embedded user:pass@ stripped.
git -C "$WORK_DIR" remote set-url origin "${PROTOCOL}://${GIT_HOST_PUBLIC}${GIT_PATH}"

write_commit_info "$WORK_DIR"

# ---- Sub-path support ----
BUILD_DIR="$WORK_DIR"
if [[ -n "$SUB_PATH" ]]; then
  BUILD_DIR="$WORK_DIR/$SUB_PATH"
fi

# ---- Config service phase ----
if [[ -z "${OSC_ENV:-}" && -n "${OSC_MCP_URL:-}" ]]; then
  _extracted=$(echo "$OSC_MCP_URL" | sed -n 's|.*\.svc\.\([a-z]*\)\.osaas\.io.*|\1|p')
  OSC_ENV=${_extracted:-prod}
fi

# BEGIN runner-refresh
# Exchange the runner refresh token for a fresh 1h PAT used ONLY by
# config-to-env. The app keeps today's OSC_ACCESS_TOKEN (Stage 2 of
# python-runner#39 is gated on the REJECT_RUNNER_REFRESH_TOKENS rollout) and
# additionally receives the original token as OSC_REFRESH_TOKEN.
# The fresh token is kept in a NON-exported shell variable and never assigned
# to OSC_ACCESS_TOKEN. The request body goes through a 0600 temp file so the
# token never appears in curl's argv.
config_access_token=""
if [[ -n "${OSC_ACCESS_TOKEN:-}" && -n "${OSC_ENV:-}" ]]; then
  refresh_http=""
  refresh_json=""
  refresh_code=""
  for refresh_attempt in 1 2 3; do
    refresh_body_file=$(mktemp)
    chmod 600 "$refresh_body_file"
    printf '{"token":"%s"}' "$OSC_ACCESS_TOKEN" > "$refresh_body_file"
    refresh_raw=$(curl -s --max-time 10 -w "\n%{http_code}" -X POST \
      "https://token.svc.${OSC_ENV}.osaas.io/runner-token/refresh" \
      -H "Content-Type: application/json" \
      --data @"$refresh_body_file" 2>/dev/null) || refresh_raw=""
    rm -f "$refresh_body_file"
    refresh_http=$(echo "$refresh_raw" | tail -n 1)
    refresh_json=$(echo "$refresh_raw" | sed '$d')
    # 200 and 401 are definitive; only transient failures are retried.
    if [ "$refresh_http" = "200" ] || [ "$refresh_http" = "401" ]; then
      break
    fi
    if [ "$refresh_attempt" -lt 3 ]; then
      sleep 3
    fi
  done

  refresh_outcome="failed"
  if [ "$refresh_http" = "200" ]; then
    # jq may be missing or fail: any failure leaves the result empty, which
    # is treated as a failed exchange.
    refresh_token=$(echo "$refresh_json" | jq -r '.token // empty' 2>/dev/null) || refresh_token=""
    if [ -n "$refresh_token" ]; then
      config_access_token="$refresh_token"
      refresh_outcome="ok"
    fi
    unset refresh_token
  elif [ "$refresh_http" = "401" ]; then
    refresh_code=$(echo "$refresh_json" | jq -r '.code // empty' 2>/dev/null) || refresh_code=""
    case "$refresh_code" in
      refresh_token_expired|refresh_token_revoked) refresh_outcome="expired" ;;
      refresh_token_invalid) refresh_outcome="invalid" ;;
    esac
  fi

  case "$refresh_outcome" in
    ok)
      echo "[CONFIG] Refreshed access token via runner refresh token"
      export OSC_REFRESH_TOKEN="$OSC_ACCESS_TOKEN"
      ;;
    expired)
      echo "[CONFIG] WARNING: runner refresh token is $refresh_code"
      ;;
    invalid)
      echo "[CONFIG] WARNING: OSC_ACCESS_TOKEN is not a runner refresh token, exchange skipped"
      ;;
    *)
      echo "[CONFIG] WARNING: runner token exchange failed (HTTP '${refresh_http}'), using the original token"
      export OSC_REFRESH_TOKEN="$OSC_ACCESS_TOKEN"
      ;;
  esac
  unset refresh_http refresh_json refresh_raw refresh_outcome refresh_code
fi
# END runner-refresh

# BEGIN config-load
if [[ -n "$OSC_ACCESS_TOKEN" && -n "$CONFIG_SVC" ]]; then
  echo "[CONFIG] Loading environment variables from config service '$CONFIG_SVC'"
  # NOTE: this script runs under `set -e`. A plain `x=$(cmd)` assignment
  # propagates a non-zero command-substitution exit status and terminates the
  # script immediately, before `config_exit=$?` on the next line is ever read.
  # The same applies to `valid_exports=$(... | grep ...)` when grep matches
  # nothing (exit 1). Every substitution below therefore has an explicit
  # `|| fallback` so the exit handling is actually reached instead of the
  # container dying silently (and the EXIT trap taking /healthz down with it).
  config_max_attempts=3
  config_attempt=1
  config_failed=0
  config_fail_reason=""
  config_exit=0
  config_env_output=""
  config_err_output=""
  valid_exports=""
  config_out_file=$(mktemp)
  config_err_file=$(mktemp)
  while true; do
    config_failed=0
    config_exit=0
    valid_exports=""
    OSC_ACCESS_TOKEN="${config_access_token:-$OSC_ACCESS_TOKEN}" timeout 60s npx -y "@osaas/cli@${OSAAS_CLI_VERSION:?OSAAS_CLI_VERSION must be set (pinned in the Dockerfile)}" web config-to-env ${OSC_ENV:+--env "$OSC_ENV"} "$CONFIG_SVC" >"$config_out_file" 2>"$config_err_file" || config_exit=$?
    config_env_output=$(cat "$config_out_file") || config_env_output=""
    config_err_output=$(cat "$config_err_file") || config_err_output=""
    if [ $config_exit -eq 124 ]; then
      config_failed=1
      config_fail_reason="config-to-env timed out after 60s"
    elif [ $config_exit -ne 0 ]; then
      config_failed=1
      config_fail_reason="exit code $config_exit"
    else
      # Only eval lines that are valid shell export statements to prevent
      # executing error messages or malformed output as shell commands
      valid_exports=$(echo "$config_env_output" | grep "^export [A-Za-z_][A-Za-z0-9_]*=") || valid_exports=""
      if [ -z "$valid_exports" ] && [ -n "$config_env_output" ]; then
        config_failed=1
        config_fail_reason="config service returned output with no valid export statements"
      fi
    fi
    if [ $config_failed -eq 0 ]; then
      break
    fi
    # Auth and not-found failures are permanent: do not retry
    if echo "$config_env_output $config_err_output" | grep -qi "expired\|unauthorized\|401\|not found\|404"; then
      break
    fi
    if [ $config_attempt -ge $config_max_attempts ]; then
      break
    fi
    echo "[CONFIG] WARNING: Failed to load config (attempt $config_attempt/$config_max_attempts: $config_fail_reason) - retrying in 3s" >&2
    config_attempt=$((config_attempt + 1))
    sleep 3
  done
  rm -f "$config_out_file" "$config_err_file"

  if [ $config_failed -eq 1 ]; then
    # Never print parameter values: drop export lines from the logged output
    config_safe_output=$(printf '%s\n%s\n' "$config_env_output" "$config_err_output" | grep -v "^export [A-Za-z_][A-Za-z0-9_]*=" | tr '\n' ' ') || config_safe_output=""
    echo "[CONFIG] ERROR: Failed to load config from '$CONFIG_SVC' ($config_fail_reason, exit code $config_exit): $config_safe_output" >&2
    if echo "$config_env_output $config_err_output" | grep -qi "expired\|unauthorized\|401"; then
      echo "[CONFIG] Action required: Your OSC_ACCESS_TOKEN may have expired." >&2
      echo "[CONFIG] Use the 'refresh-app-config' MCP tool to issue a fresh token." >&2
    fi
    echo "[CONFIG] Not starting the application without its configuration." >&2
    # Enter the loading server's failed state (/healthz 500 build-failed, / 503)
    # instead of `exit 1`: the EXIT trap would kill the loading server and make
    # /healthz unreachable.
    kill $LOADING_PID 2>/dev/null || true
    wait $LOADING_PID 2>/dev/null || true
    trap - EXIT
    exec node /runner/loading-server.js error-page.html failed
  fi

  if [ -n "$valid_exports" ]; then
    eval "$valid_exports"
    var_count=$(echo "$valid_exports" | wc -l | tr -d ' ')
    echo "[CONFIG] Loaded $var_count environment variable(s)"
  else
    echo "[CONFIG] Config service '$CONFIG_SVC' has no parameters"
  fi
fi
# END config-load

# ---- Build phase ----
cd "$BUILD_DIR"
mkdir -p /app

# set -e is active: every build command must tolerate failure (|| BUILD_EXIT=$?)
# so a failed build reaches the failed-mode branch below instead of aborting.
BUILD_EXIT=0
if [[ -n "$OSC_BUILD_CMD" ]]; then
  eval "$OSC_BUILD_CMD" || BUILD_EXIT=$?
elif [[ -f "cmd/server/main.go" ]]; then
  go build -o /app/server ./cmd/server || BUILD_EXIT=$?
elif ls cmd/*/main.go 1>/dev/null 2>&1; then
  CMD_DIR=$(dirname "$(ls cmd/*/main.go | head -1)")
  go build -o /app/server "./$CMD_DIR" || BUILD_EXIT=$?
elif [[ -f "main.go" ]]; then
  go build -o /app/server . || BUILD_EXIT=$?
else
  go build -o /app/server ./... || BUILD_EXIT=$?
fi

if [[ $BUILD_EXIT -ne 0 ]]; then
  echo "Build failed with exit code $BUILD_EXIT" >&2
  kill $LOADING_PID 2>/dev/null || true
  exec node /runner/loading-server.js error-page.html failed
fi

# ---- Run phase ----
kill $LOADING_PID 2>/dev/null || true
wait $LOADING_PID 2>/dev/null || true
trap - EXIT

if [[ -n "$OSC_ENTRY" ]]; then
  exec $OSC_ENTRY
else
  exec /app/server
fi
