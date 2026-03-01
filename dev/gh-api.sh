#!/usr/bin/env bash
# gh-api.sh — GitHub API access from Claude Code web/mobile sandbox
#
# The Claude Code sandbox proxies git traffic through a local HTTP proxy.
# This script reuses that same proxy to reach the GitHub REST API, enabling
# issue/PR operations without `gh auth login` or a personal access token.
#
# Usage:
#   ./dev/gh-api.sh issues                  # list open issues
#   ./dev/gh-api.sh issues 15               # show issue #15
#   ./dev/gh-api.sh pulls                   # list open PRs
#   ./dev/gh-api.sh pulls 42                # show PR #42
#   ./dev/gh-api.sh pr-comments 42          # list PR #42 review comments
#   ./dev/gh-api.sh raw <api-path>          # raw API call (e.g. /repos/OWNER/REPO/labels)
#   ./dev/gh-api.sh assign <number> <user>  # add assignee to issue/PR
#
# Environment:
#   REPO_OWNER / REPO_NAME  — override auto-detected owner/repo
#   GH_API_PROXY            — override auto-detected proxy URL

set -euo pipefail

# --- Detect proxy from git remote -----------------------------------------
detect_proxy() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"

  if [[ -z "$remote_url" ]]; then
    echo "ERROR: no git remote 'origin' found" >&2
    return 1
  fi

  # Extract proxy host:port from URL like http://local_proxy@127.0.0.1:50136/git/...
  local proxy
  proxy="$(echo "$remote_url" | sed -n 's|^\(http://[^/]*\)/git/.*|\1|p')"

  if [[ -z "$proxy" ]]; then
    echo "ERROR: could not extract proxy from remote URL: $remote_url" >&2
    echo "       Expected format: http://<user>@<host>:<port>/git/<owner>/<repo>" >&2
    return 1
  fi

  echo "$proxy"
}

# --- Detect owner/repo from git remote ------------------------------------
detect_owner_repo() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"

  # Extract from http://local_proxy@127.0.0.1:PORT/git/OWNER/REPO
  echo "$remote_url" | sed -n 's|.*/git/\([^/]*/[^/]*\)$|\1|p' | sed 's/\.git$//'
}

# --- Setup -----------------------------------------------------------------
PROXY="${GH_API_PROXY:-$(detect_proxy)}"
OWNER_REPO="${REPO_OWNER:+${REPO_OWNER}/${REPO_NAME:-}}"; : "${OWNER_REPO:=$(detect_owner_repo)}"

if [[ -z "$OWNER_REPO" || "$OWNER_REPO" == "/" ]]; then
  echo "ERROR: could not detect owner/repo. Set REPO_OWNER and REPO_NAME." >&2
  exit 1
fi

export HTTP_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"

API_BASE="https://api.github.com"

# --- Helpers ---------------------------------------------------------------
api_get() {
  curl -sf \
    -H "Accept: application/vnd.github+json" \
    "${API_BASE}$1"
}

api_post() {
  local path="$1" body="$2"
  curl -sf \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${API_BASE}${path}"
}

format_issues() {
  python3 -c "
import json, sys, textwrap
items = json.load(sys.stdin)
if not isinstance(items, list):
    items = [items]
for i in items:
    num = i['number']
    title = i['title']
    state = i['state']
    labels = ', '.join(l['name'] for l in i.get('labels', []))
    assignees = ', '.join(a['login'] for a in i.get('assignees', []))
    body = i.get('body') or ''
    print(f'#{num} [{state}] {title}')
    if labels:   print(f'  Labels:    {labels}')
    if assignees: print(f'  Assignees: {assignees}')
    if len(sys.argv) > 1 and sys.argv[1] == '--detail' and body:
        wrapped = textwrap.indent(body.strip(), '  ')
        print(f'{wrapped}')
    print()
" "$@"
}

format_pulls() {
  python3 -c "
import json, sys, textwrap
items = json.load(sys.stdin)
if not isinstance(items, list):
    items = [items]
for pr in items:
    num = pr['number']
    title = pr['title']
    state = pr['state']
    head = pr.get('head', {}).get('ref', '?')
    base = pr.get('base', {}).get('ref', '?')
    user = pr.get('user', {}).get('login', '?')
    draft = ' [DRAFT]' if pr.get('draft') else ''
    body = pr.get('body') or ''
    print(f'#{num} [{state}]{draft} {title}')
    print(f'  {head} -> {base}  (by {user})')
    if len(sys.argv) > 1 and sys.argv[1] == '--detail' and body:
        wrapped = textwrap.indent(body.strip(), '  ')
        print(f'{wrapped}')
    print()
" "$@"
}

# --- Commands --------------------------------------------------------------
cmd="${1:-help}"
shift || true

case "$cmd" in
  issues)
    if [[ -n "${1:-}" ]]; then
      # Single issue detail
      api_get "/repos/${OWNER_REPO}/issues/$1" | format_issues --detail
    else
      api_get "/repos/${OWNER_REPO}/issues?state=open&per_page=50" | format_issues
    fi
    ;;

  pulls)
    if [[ -n "${1:-}" ]]; then
      api_get "/repos/${OWNER_REPO}/pulls/$1" | format_pulls --detail
    else
      api_get "/repos/${OWNER_REPO}/pulls?state=open&per_page=50" | format_pulls
    fi
    ;;

  pr-comments)
    num="${1:?Usage: gh-api.sh pr-comments <pr-number>}"
    api_get "/repos/${OWNER_REPO}/pulls/${num}/comments" | python3 -c "
import json, sys
comments = json.load(sys.stdin)
for c in comments:
    user = c.get('user', {}).get('login', '?')
    body = c.get('body', '')
    path = c.get('path', '')
    print(f'--- {user} on {path} ---')
    print(body)
    print()
"
    ;;

  assign)
    num="${1:?Usage: gh-api.sh assign <number> <user>}"
    user="${2:?Usage: gh-api.sh assign <number> <user>}"
    api_post "/repos/${OWNER_REPO}/issues/${num}/assignees" "{\"assignees\":[\"${user}\"]}" \
      | python3 -c "
import json, sys
i = json.load(sys.stdin)
assignees = ', '.join(a['login'] for a in i.get('assignees', []))
print(f'#{i[\"number\"]}: assignees now: {assignees}')
"
    ;;

  raw)
    path="${1:?Usage: gh-api.sh raw <api-path>}"
    api_get "$path" | python3 -m json.tool
    ;;

  help|--help|-h)
    head -18 "$0" | tail -16
    echo ""
    echo "Detected proxy:      $PROXY"
    echo "Detected owner/repo: $OWNER_REPO"
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    echo "Run '$0 help' for usage." >&2
    exit 1
    ;;
esac
