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

if [[ -n "${OSC_ACCESS_TOKEN:-}" && -n "${OSC_ENV:-}" ]]; then
  _refreshed=$(curl -sf -X POST \
    "https://token.svc.${OSC_ENV:-prod}.osaas.io/runner-token/refresh" \
    -H "Authorization: Bearer ${OSC_ACCESS_TOKEN}" \
    -H "Content-Type: application/json" || true)
  if [[ -n "${_refreshed}" ]]; then
    OSC_ACCESS_TOKEN=$(echo "$_refreshed" | grep -o '"token":"[^"]*"' | cut -d'"' -f4 || echo "$OSC_ACCESS_TOKEN")
  fi
fi

if [[ -n "$OSC_ACCESS_TOKEN" && -n "$CONFIG_SVC" ]]; then
  echo "[CONFIG] Loading environment variables from config service '$CONFIG_SVC'"
  if config_env_output=$(timeout 60s npx -y @osaas/cli@latest web config-to-env ${OSC_ENV:+--env "$OSC_ENV"} "$CONFIG_SVC" 2>&1); then
    config_exit=0
  else
    config_exit=$?
  fi
  if [ $config_exit -eq 0 ]; then
    valid_exports=$(echo "$config_env_output" | grep "^export [A-Za-z_][A-Za-z0-9_]*=")
    if [ -n "$valid_exports" ]; then
      eval "$valid_exports"
      var_count=$(echo "$valid_exports" | wc -l | tr -d ' ')
      echo "[CONFIG] Loaded $var_count environment variable(s)"
    fi
  else
    echo "[CONFIG] ERROR: Failed to load config (exit $config_exit): $config_env_output" >&2
  fi
fi

# ---- Build phase ----
cd "$BUILD_DIR"
mkdir -p /app

BUILD_EXIT=0
if [[ -n "$OSC_BUILD_CMD" ]]; then
  eval "$OSC_BUILD_CMD"
  BUILD_EXIT=$?
elif [[ -f "cmd/server/main.go" ]]; then
  go build -o /app/server ./cmd/server
  BUILD_EXIT=$?
elif ls cmd/*/main.go 1>/dev/null 2>&1; then
  CMD_DIR=$(dirname "$(ls cmd/*/main.go | head -1)")
  go build -o /app/server "./$CMD_DIR"
  BUILD_EXIT=$?
elif [[ -f "main.go" ]]; then
  go build -o /app/server .
  BUILD_EXIT=$?
else
  go build -o /app/server ./...
  BUILD_EXIT=$?
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
