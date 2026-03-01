#!/bin/bash
set -euo pipefail

# Session start hook for Claude Code on the web.
# Injects environment variables from .env into the session.
# This enables tools like dev/gh-api.sh to auto-detect GH_TOKEN.

# Only run in remote (web/mobile) environments
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
ENV_FILE="$PROJECT_DIR/.env"

# Source .env and inject select variables into the session
if [ -f "$ENV_FILE" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  # Inject GH_TOKEN if present (for dev/gh-api.sh GitHub API access)
  gh_token=$(grep -E '^GH_TOKEN=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" | xargs)
  if [ -n "$gh_token" ] && [ "$gh_token" != "your-github-token-here" ]; then
    echo "export GH_TOKEN='${gh_token}'" >> "$CLAUDE_ENV_FILE"
  fi
fi
