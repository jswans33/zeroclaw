#!/usr/bin/env bash
# gh-api.sh — GitHub REST API client for Claude Code web/mobile sandbox
#
# HOW IT WORKS
# ~~~~~~~~~~~~
# The Claude Code sandbox routes git traffic through a local HTTP proxy
# visible in `git remote -v` (e.g. http://local_proxy@HOST:PORT/git/...).
# Setting HTTP_PROXY/HTTPS_PROXY to that proxy lets curl reach
# api.github.com for read operations on public repos — no token needed.
#
# LIMITS
# ~~~~~~
# - READ-ONLY: 60 requests/hour (unauthenticated GitHub rate limit).
# - WRITES (comment, label, assign, close, etc.) require a GitHub token.
#   Pass one via GH_TOKEN env var if available. Without it, writes will 401.
# - Git push/fetch works independently via the git proxy (always authenticated).
#
# USAGE
# ~~~~~
#   ./dev/gh-api.sh help                        # show this help + detected config
#   ./dev/gh-api.sh rate-limit                   # check remaining API quota
#
#   # Issues
#   ./dev/gh-api.sh issues                       # list open issues
#   ./dev/gh-api.sh issues --state=closed        # list closed issues
#   ./dev/gh-api.sh issues --label=bug           # filter by label
#   ./dev/gh-api.sh issue 15                     # show issue #15 detail
#   ./dev/gh-api.sh issue-comments 15            # list comments on issue #15
#   ./dev/gh-api.sh issue-labels 15              # list labels on issue #15
#   ./dev/gh-api.sh issue-reactions 15           # list reactions on issue #15
#
#   # Pull Requests
#   ./dev/gh-api.sh pulls                        # list open PRs
#   ./dev/gh-api.sh pulls --state=closed         # list closed/merged PRs
#   ./dev/gh-api.sh pull 42                      # show PR #42 detail
#   ./dev/gh-api.sh pr-comments 42               # review comments on PR #42
#   ./dev/gh-api.sh pr-files 42                  # files changed in PR #42
#   ./dev/gh-api.sh pr-checks 42                 # CI check runs for PR #42
#
#   # Repository
#   ./dev/gh-api.sh repo                         # repo metadata
#   ./dev/gh-api.sh branches                     # list branches
#   ./dev/gh-api.sh tags                         # list tags
#   ./dev/gh-api.sh releases                     # list releases
#   ./dev/gh-api.sh labels                       # list all repo labels
#   ./dev/gh-api.sh milestones                   # list milestones
#   ./dev/gh-api.sh commits                      # recent commits (default branch)
#   ./dev/gh-api.sh commits --branch=dev         # recent commits on branch
#   ./dev/gh-api.sh commit abc123                # show single commit detail
#   ./dev/gh-api.sh contributors                 # list contributors
#
#   # CI / Actions
#   ./dev/gh-api.sh workflows                    # list workflows
#   ./dev/gh-api.sh runs                         # recent workflow runs
#   ./dev/gh-api.sh run 12345                    # single run detail
#   ./dev/gh-api.sh run-jobs 12345               # jobs in a workflow run
#
#   # Search (separate 10 req/min limit)
#   ./dev/gh-api.sh search-issues "memory leak"  # search issues/PRs
#   ./dev/gh-api.sh search-code "fn main"        # search code (needs auth)
#
#   # Write operations (require GH_TOKEN)
#   ./dev/gh-api.sh comment 15 "message"         # add comment to issue/PR
#   ./dev/gh-api.sh close 15                     # close issue/PR
#   ./dev/gh-api.sh reopen 15                    # reopen issue/PR
#   ./dev/gh-api.sh add-labels 15 bug,help       # add labels to issue
#   ./dev/gh-api.sh remove-label 15 bug          # remove label from issue
#   ./dev/gh-api.sh assign 15 user1,user2        # add assignees
#   ./dev/gh-api.sh unassign 15 user1            # remove assignee
#   ./dev/gh-api.sh react 15 "+1"                # add reaction to issue
#   ./dev/gh-api.sh create-label name color desc  # create repo label
#
#   # Escape hatch
#   ./dev/gh-api.sh raw GET /repos/OWNER/REPO/X  # raw GET
#   ./dev/gh-api.sh raw POST /path '{"json":1}'  # raw POST
#
# AUTHENTICATION
# ~~~~~~~~~~~~~~
# Write operations require a GitHub token. The script auto-detects from:
#   1. GH_TOKEN env var (highest priority)
#   2. .env file in repo root (GH_TOKEN=ghp_...)
#   3. ~/.config/gh/hosts.yml (gh CLI auth store)
#
# To set up:
#   ./dev/gh-api.sh auth <your-github-token>
#
# This saves the token to .env (gitignored) and injects it into the
# current Claude Code session via CLAUDE_ENV_FILE.
#
# To create a token: github.com/settings/tokens?type=beta
#   Scopes needed: Issues (read/write), Pull requests (read/write),
#   Contents (read), Actions (read)
#
# ENVIRONMENT
# ~~~~~~~~~~~
#   GH_TOKEN          — GitHub token (auto-detected, see above)
#   GH_API_PROXY      — override auto-detected proxy URL
#   REPO_OWNER        — override auto-detected owner
#   REPO_NAME         — override auto-detected repo name

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Detect proxy from git remote ────────────────────────────────────────────
detect_proxy() {
  local remote_url
  remote_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$remote_url" ]]; then
    echo "ERROR: no git remote 'origin' found" >&2; return 1
  fi
  local proxy
  proxy="$(echo "$remote_url" | sed -n 's|^\(http://[^/]*\)/git/.*|\1|p')"
  if [[ -z "$proxy" ]]; then
    echo "ERROR: cannot extract proxy from remote: $remote_url" >&2; return 1
  fi
  echo "$proxy"
}

# ─── Detect owner/repo from git remote ───────────────────────────────────────
detect_owner_repo() {
  git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -n 's|.*/git/\([^/]*/[^/]*\)$|\1|p' \
    | sed 's/\.git$//'
}

# ─── Auto-detect GH_TOKEN ────────────────────────────────────────────────────
detect_gh_token() {
  # 1. Already set in environment
  if [[ -n "${GH_TOKEN:-}" ]]; then
    return 0
  fi

  # 2. Read from .env in repo root
  if [[ -f "$REPO_ROOT/.env" ]]; then
    local token
    token=$(grep -E '^GH_TOKEN=' "$REPO_ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" | xargs)
    if [[ -n "$token" && "$token" != "your-github-token-here" ]]; then
      export GH_TOKEN="$token"
      return 0
    fi
  fi

  # 3. Read from gh CLI config
  local gh_hosts="${HOME}/.config/gh/hosts.yml"
  if [[ -f "$gh_hosts" ]]; then
    local token
    token=$(grep -A5 'github.com' "$gh_hosts" 2>/dev/null | grep 'oauth_token:' | head -1 | awk '{print $2}' | tr -d "'\"")
    if [[ -n "$token" ]]; then
      export GH_TOKEN="$token"
      return 0
    fi
  fi

  # No token found — read-only mode
  return 1
}

detect_gh_token || true

# ─── Setup ────────────────────────────────────────────────────────────────────
PROXY="${GH_API_PROXY:-$(detect_proxy)}"
OWNER_REPO="${REPO_OWNER:+${REPO_OWNER}/${REPO_NAME:-}}"
: "${OWNER_REPO:=$(detect_owner_repo)}"
if [[ -z "$OWNER_REPO" || "$OWNER_REPO" == "/" ]]; then
  echo "ERROR: cannot detect owner/repo. Set REPO_OWNER and REPO_NAME." >&2
  exit 1
fi

export HTTP_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"
API="https://api.github.com"
REPO_API="${API}/repos/${OWNER_REPO}"

# ─── HTTP helpers ─────────────────────────────────────────────────────────────
_auth_headers() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    echo -H "Authorization: Bearer ${GH_TOKEN}"
  fi
}

require_token() {
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "ERROR: GH_TOKEN required for write operations." >&2
    echo "       Export a GitHub personal access token: export GH_TOKEN=ghp_..." >&2
    exit 1
  fi
}

api_get() {
  local url="$1"
  [[ "$url" == /* ]] && url="${API}${url}"
  local response http_code body
  response=$(curl -s -w "\n%{http_code}" $(_auth_headers) \
    -H "Accept: application/vnd.github+json" "$url")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')
  if [[ "$http_code" == 403 ]]; then
    echo "ERROR: HTTP 403 — likely rate-limited (60 req/hr unauthenticated)." >&2
    echo "       Run './dev/gh-api.sh rate-limit' to check quota." >&2
    echo "       Set GH_TOKEN for 5000 req/hr." >&2
    exit 1
  elif [[ "$http_code" -ge 400 ]]; then
    echo "ERROR: HTTP ${http_code}" >&2
    echo "$body" >&2
    exit 1
  fi
  echo "$body"
}

api_post() {
  local url="$1" body="${2:-}"
  [[ "$url" == /* ]] && url="${API}${url}"
  require_token
  curl -sf \
    -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    ${body:+-d "$body"} \
    "$url"
}

api_patch() {
  local url="$1" body="${2:-}"
  [[ "$url" == /* ]] && url="${API}${url}"
  require_token
  curl -sf \
    -X PATCH \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    ${body:+-d "$body"} \
    "$url"
}

api_delete() {
  local url="$1" body="${2:-}"
  [[ "$url" == /* ]] && url="${API}${url}"
  require_token
  curl -sf \
    -X DELETE \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    ${body:+-d "$body"} \
    "$url"
}

# ─── Parse --key=value flags from args ────────────────────────────────────────
# Sets FLAG_<key> variables and returns remaining positional args in POSITIONAL
parse_flags() {
  POSITIONAL=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --*=*) local key="${1%%=*}"; key="${key#--}"; key="${key//-/_}"
             declare -g "FLAG_${key}=${1#*=}"; shift ;;
      *)     POSITIONAL+=("$1"); shift ;;
    esac
  done
}

# ─── Formatters (python3 one-liners) ─────────────────────────────────────────
fmt_issues() {
  python3 -c "
import json, sys, textwrap
detail = '--detail' in sys.argv
items = json.load(sys.stdin)
if not isinstance(items, list): items = [items]
for i in items:
    n, t, s = i['number'], i['title'], i['state']
    labels = ', '.join(l['name'] for l in i.get('labels', []))
    assignees = ', '.join(a['login'] for a in i.get('assignees', []))
    milestone = (i.get('milestone') or {}).get('title', '')
    pr = ' [PR]' if i.get('pull_request') else ''
    print(f'#{n} [{s}]{pr} {t}')
    if labels:    print(f'  Labels:    {labels}')
    if assignees: print(f'  Assignees: {assignees}')
    if milestone: print(f'  Milestone: {milestone}')
    if detail:
        body = (i.get('body') or '').strip()
        if body: print(textwrap.indent(body, '  '))
    print()
" "$@"
}

fmt_pulls() {
  python3 -c "
import json, sys, textwrap
detail = '--detail' in sys.argv
items = json.load(sys.stdin)
if not isinstance(items, list): items = [items]
for pr in items:
    n, t, s = pr['number'], pr['title'], pr['state']
    head = pr.get('head', {}).get('ref', '?')
    base = pr.get('base', {}).get('ref', '?')
    user = pr.get('user', {}).get('login', '?')
    draft = ' [DRAFT]' if pr.get('draft') else ''
    merged = ' [MERGED]' if pr.get('merged') else ''
    labels = ', '.join(l['name'] for l in pr.get('labels', []))
    print(f'#{n} [{s}]{draft}{merged} {t}')
    print(f'  {head} -> {base}  (by {user})')
    if labels: print(f'  Labels: {labels}')
    if detail:
        body = (pr.get('body') or '').strip()
        if body: print(textwrap.indent(body, '  '))
    print()
" "$@"
}

fmt_comments() {
  python3 -c "
import json, sys
comments = json.load(sys.stdin)
if not isinstance(comments, list): comments = [comments]
for c in comments:
    user = c.get('user', {}).get('login', '?')
    date = c.get('created_at', '?')[:10]
    body = c.get('body', '')
    path = c.get('path', '')
    loc = f' on {path}' if path else ''
    print(f'--- {user}{loc} ({date}) ---')
    print(body)
    print()
"
}

fmt_simple_list() {
  # Generic: extract 'name' field from array of objects
  local field="${1:-name}"
  python3 -c "
import json, sys
field = sys.argv[1]
items = json.load(sys.stdin)
if not isinstance(items, list): items = [items]
for i in items:
    val = i.get(field, '?')
    extra = ''
    if 'color' in i: extra += f'  #{i[\"color\"]}'
    if 'description' in i and i['description']: extra += f'  {i[\"description\"]}'
    if 'sha' in i: extra = f'  {i[\"sha\"][:7]}'
    print(f'  {val}{extra}')
" "$field"
}

fmt_branches() {
  python3 -c "
import json, sys
items = json.load(sys.stdin)
for b in items:
    name = b['name']
    sha = b.get('commit', {}).get('sha', '?')[:7]
    prot = ' [protected]' if b.get('protected') else ''
    print(f'  {name}  {sha}{prot}')
"
}

fmt_commits() {
  python3 -c "
import json, sys, textwrap
detail = '--detail' in sys.argv
items = json.load(sys.stdin)
if not isinstance(items, list): items = [items]
for c in items:
    sha = c.get('sha', '?')[:7]
    msg = c.get('commit', {}).get('message', '').split('\n')[0]
    author = c.get('commit', {}).get('author', {}).get('name', '?')
    date = c.get('commit', {}).get('author', {}).get('date', '?')[:10]
    print(f'  {sha} {msg}  ({author}, {date})')
    if detail:
        full = c.get('commit', {}).get('message', '')
        if '\n' in full:
            rest = '\n'.join(full.split('\n')[1:]).strip()
            if rest: print(textwrap.indent(rest, '         '))
"  "$@"
}

fmt_releases() {
  python3 -c "
import json, sys
items = json.load(sys.stdin)
if not isinstance(items, list): items = [items]
for r in items:
    tag = r.get('tag_name', '?')
    name = r.get('name', '')
    draft = ' [draft]' if r.get('draft') else ''
    pre = ' [pre-release]' if r.get('prerelease') else ''
    date = (r.get('published_at') or r.get('created_at', '?'))[:10]
    display = f'{tag}: {name}' if name and name != tag else tag
    print(f'  {display}{draft}{pre}  ({date})')
"
}

fmt_workflows() {
  python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('workflows', data) if isinstance(data, dict) else data
if not isinstance(items, list): items = [items]
for w in items:
    name = w.get('name', '?')
    state = w.get('state', '?')
    path = w.get('path', '')
    wid = w.get('id', '?')
    print(f'  [{wid}] {name} ({state})  {path}')
"
}

fmt_runs() {
  python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('workflow_runs', data) if isinstance(data, dict) else data
if not isinstance(items, list): items = [items]
for r in items:
    rid = r.get('id', '?')
    name = r.get('name', '?')
    status = r.get('status', '?')
    conclusion = r.get('conclusion', '')
    branch = r.get('head_branch', '?')
    result = f'{status}' + (f'/{conclusion}' if conclusion else '')
    print(f'  [{rid}] {name}  {result}  on {branch}')
"
}

fmt_jobs() {
  python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('jobs', data) if isinstance(data, dict) else data
if not isinstance(items, list): items = [items]
for j in items:
    name = j.get('name', '?')
    status = j.get('status', '?')
    conclusion = j.get('conclusion', '')
    result = f'{status}' + (f'/{conclusion}' if conclusion else '')
    print(f'  {name}: {result}')
    for s in j.get('steps', []):
        sc = s.get('conclusion', s.get('status', '?'))
        print(f'    [{sc}] {s.get(\"name\", \"?\")}')
"
}

fmt_pr_files() {
  python3 -c "
import json, sys
items = json.load(sys.stdin)
for f in items:
    status = f.get('status', '?')
    name = f.get('filename', '?')
    adds = f.get('additions', 0)
    dels = f.get('deletions', 0)
    print(f'  {status:10s} +{adds}/-{dels}  {name}')
"
}

fmt_checks() {
  python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('check_runs', data) if isinstance(data, dict) else data
if not isinstance(items, list): items = [items]
for c in items:
    name = c.get('name', '?')
    status = c.get('status', '?')
    conclusion = c.get('conclusion', '')
    result = f'{status}' + (f'/{conclusion}' if conclusion else '')
    print(f'  {name}: {result}')
"
}

fmt_reactions() {
  python3 -c "
import json, sys
items = json.load(sys.stdin)
if not isinstance(items, list): items = [items]
counts = {}
for r in items:
    c = r.get('content', '?')
    counts[c] = counts.get(c, 0) + 1
if counts:
    print('  ' + '  '.join(f'{v}x {k}' for k, v in sorted(counts.items(), key=lambda x: -x[1])))
else:
    print('  (no reactions)')
"
}

fmt_search_issues() {
  python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'Found {data.get(\"total_count\", 0)} results')
for i in data.get('items', []):
    n, t, s = i['number'], i['title'], i['state']
    pr = ' [PR]' if i.get('pull_request') else ''
    print(f'  #{n} [{s}]{pr} {t}')
"
}

fmt_milestones() {
  python3 -c "
import json, sys
items = json.load(sys.stdin)
if not isinstance(items, list): items = [items]
for m in items:
    num = m.get('number', '?')
    title = m.get('title', '?')
    state = m.get('state', '?')
    opn = m.get('open_issues', 0)
    cls = m.get('closed_issues', 0)
    print(f'  [{num}] {title} ({state})  open={opn} closed={cls}')
"
}

fmt_repo() {
  python3 -c "
import json, sys
r = json.load(sys.stdin)
print(f'Repository: {r[\"full_name\"]}')
print(f'  Description: {r.get(\"description\", \"(none)\")}')
print(f'  Default branch: {r.get(\"default_branch\", \"?\")}')
print(f'  Visibility: {r.get(\"visibility\", \"?\")}')
print(f'  Stars: {r.get(\"stargazers_count\", 0)}  Forks: {r.get(\"forks_count\", 0)}  Issues: {r.get(\"open_issues_count\", 0)}')
print(f'  Language: {r.get(\"language\", \"?\")}')
print(f'  Created: {r.get(\"created_at\", \"?\")[:10]}  Updated: {r.get(\"updated_at\", \"?\")[:10]}')
topics = r.get('topics', [])
if topics: print(f'  Topics: {\", \".join(topics)}')
"
}

# ─── Commands ─────────────────────────────────────────────────────────────────
cmd="${1:-help}"
shift || true

case "$cmd" in

  # ── Issues (read) ──────────────────────────────────────────────────────────
  issues)
    parse_flags "$@"
    state="${FLAG_state:-open}"
    label="${FLAG_label:-}"
    qs="state=${state}&per_page=50"
    [[ -n "$label" ]] && qs="${qs}&labels=${label}"
    api_get "${REPO_API}/issues?${qs}" | fmt_issues
    ;;

  issue)
    num="${1:?Usage: gh-api.sh issue <number>}"
    api_get "${REPO_API}/issues/${num}" | fmt_issues --detail
    ;;

  issue-comments)
    num="${1:?Usage: gh-api.sh issue-comments <number>}"
    api_get "${REPO_API}/issues/${num}/comments?per_page=100" | fmt_comments
    ;;

  issue-labels)
    num="${1:?Usage: gh-api.sh issue-labels <number>}"
    api_get "${REPO_API}/issues/${num}/labels" | fmt_simple_list name
    ;;

  issue-reactions)
    num="${1:?Usage: gh-api.sh issue-reactions <number>}"
    api_get "${REPO_API}/issues/${num}/reactions" | fmt_reactions
    ;;

  # ── Pull Requests (read) ───────────────────────────────────────────────────
  pulls)
    parse_flags "$@"
    state="${FLAG_state:-open}"
    api_get "${REPO_API}/pulls?state=${state}&per_page=50" | fmt_pulls
    ;;

  pull)
    num="${1:?Usage: gh-api.sh pull <number>}"
    api_get "${REPO_API}/pulls/${num}" | fmt_pulls --detail
    ;;

  pr-comments)
    num="${1:?Usage: gh-api.sh pr-comments <number>}"
    api_get "${REPO_API}/pulls/${num}/comments?per_page=100" | fmt_comments
    ;;

  pr-files)
    num="${1:?Usage: gh-api.sh pr-files <number>}"
    api_get "${REPO_API}/pulls/${num}/files?per_page=100" | fmt_pr_files
    ;;

  pr-checks)
    num="${1:?Usage: gh-api.sh pr-checks <number>}"
    # Get the head SHA first, then check runs
    sha=$(api_get "${REPO_API}/pulls/${num}" | python3 -c "import json,sys; print(json.load(sys.stdin)['head']['sha'])")
    api_get "${REPO_API}/commits/${sha}/check-runs?per_page=100" | fmt_checks
    ;;

  # ── Repository (read) ─────────────────────────────────────────────────────
  repo)
    api_get "${REPO_API}" | fmt_repo
    ;;

  branches)
    api_get "${REPO_API}/branches?per_page=100" | fmt_branches
    ;;

  tags)
    api_get "${REPO_API}/tags?per_page=50" | fmt_simple_list name
    ;;

  releases)
    api_get "${REPO_API}/releases?per_page=20" | fmt_releases
    ;;

  labels)
    api_get "${REPO_API}/labels?per_page=100" | fmt_simple_list name
    ;;

  milestones)
    api_get "${REPO_API}/milestones?state=open&per_page=20" | fmt_milestones
    ;;

  commits)
    parse_flags "$@"
    branch="${FLAG_branch:-}"
    qs="per_page=20"
    [[ -n "$branch" ]] && qs="${qs}&sha=${branch}"
    api_get "${REPO_API}/commits?${qs}" | fmt_commits
    ;;

  commit)
    ref="${1:?Usage: gh-api.sh commit <sha>}"
    api_get "${REPO_API}/commits/${ref}" | fmt_commits --detail
    ;;

  contributors)
    api_get "${REPO_API}/contributors?per_page=50" | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    print(f'  {c[\"login\"]:20s} {c[\"contributions\"]} commits')
"
    ;;

  # ── CI / Actions (read) ────────────────────────────────────────────────────
  workflows)
    api_get "${REPO_API}/actions/workflows" | fmt_workflows
    ;;

  runs)
    parse_flags "$@"
    branch="${FLAG_branch:-}"
    qs="per_page=15"
    [[ -n "$branch" ]] && qs="${qs}&branch=${branch}"
    api_get "${REPO_API}/actions/runs?${qs}" | fmt_runs
    ;;

  run)
    run_id="${1:?Usage: gh-api.sh run <run-id>}"
    api_get "${REPO_API}/actions/runs/${run_id}" | fmt_runs
    ;;

  run-jobs)
    run_id="${1:?Usage: gh-api.sh run-jobs <run-id>}"
    api_get "${REPO_API}/actions/runs/${run_id}/jobs" | fmt_jobs
    ;;

  # ── Search (separate 10 req/min limit) ─────────────────────────────────────
  search-issues)
    query="${1:?Usage: gh-api.sh search-issues <query>}"
    api_get "${API}/search/issues?q=repo:${OWNER_REPO}+${query// /+}&per_page=20" | fmt_search_issues
    ;;

  search-code)
    query="${1:?Usage: gh-api.sh search-code <query>}"
    api_get "${API}/search/code?q=repo:${OWNER_REPO}+${query// /+}&per_page=20" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'Found {data.get(\"total_count\", 0)} results')
for i in data.get('items', []):
    print(f'  {i.get(\"path\", \"?\")}')
"
    ;;

  # ── Write operations (require GH_TOKEN) ────────────────────────────────────
  comment)
    require_token
    num="${1:?Usage: gh-api.sh comment <number> <body>}"
    body="${2:?Usage: gh-api.sh comment <number> <body>}"
    json_body=$(python3 -c "import json,sys; print(json.dumps({'body': sys.argv[1]}))" "$body")
    api_post "${REPO_API}/issues/${num}/comments" "$json_body" | fmt_comments
    ;;

  close)
    require_token
    num="${1:?Usage: gh-api.sh close <number>}"
    api_patch "${REPO_API}/issues/${num}" '{"state":"closed"}' \
      | python3 -c "import json,sys; i=json.load(sys.stdin); print(f'#{i[\"number\"]} [{i[\"state\"]}] {i[\"title\"]}')"
    ;;

  reopen)
    require_token
    num="${1:?Usage: gh-api.sh reopen <number>}"
    api_patch "${REPO_API}/issues/${num}" '{"state":"open"}' \
      | python3 -c "import json,sys; i=json.load(sys.stdin); print(f'#{i[\"number\"]} [{i[\"state\"]}] {i[\"title\"]}')"
    ;;

  add-labels)
    require_token
    num="${1:?Usage: gh-api.sh add-labels <number> <label1,label2,...>}"
    labels_csv="${2:?Usage: gh-api.sh add-labels <number> <label1,label2,...>}"
    json_body=$(python3 -c "import json,sys; print(json.dumps({'labels': sys.argv[1].split(',')}))" "$labels_csv")
    api_post "${REPO_API}/issues/${num}/labels" "$json_body" | fmt_simple_list name
    ;;

  remove-label)
    require_token
    num="${1:?Usage: gh-api.sh remove-label <number> <label>}"
    label="${2:?Usage: gh-api.sh remove-label <number> <label>}"
    api_delete "${REPO_API}/issues/${num}/labels/${label}" | fmt_simple_list name
    ;;

  assign)
    require_token
    num="${1:?Usage: gh-api.sh assign <number> <user1,user2,...>}"
    users="${2:?Usage: gh-api.sh assign <number> <user1,user2,...>}"
    json_body=$(python3 -c "import json,sys; print(json.dumps({'assignees': sys.argv[1].split(',')}))" "$users")
    api_post "${REPO_API}/issues/${num}/assignees" "$json_body" \
      | python3 -c "import json,sys; i=json.load(sys.stdin); a=', '.join(x['login'] for x in i.get('assignees',[])); print(f'#{i[\"number\"]}: assignees = {a}')"
    ;;

  unassign)
    require_token
    num="${1:?Usage: gh-api.sh unassign <number> <user>}"
    user="${2:?Usage: gh-api.sh unassign <number> <user>}"
    json_body=$(python3 -c "import json,sys; print(json.dumps({'assignees': [sys.argv[1]]}))" "$user")
    api_delete "${REPO_API}/issues/${num}/assignees" "$json_body" \
      | python3 -c "import json,sys; i=json.load(sys.stdin); a=', '.join(x['login'] for x in i.get('assignees',[])); print(f'#{i[\"number\"]}: assignees = {a}')"
    ;;

  react)
    require_token
    num="${1:?Usage: gh-api.sh react <number> <reaction>}"
    reaction="${2:?Usage: gh-api.sh react <number> <reaction>  (+1, -1, laugh, confused, heart, hooray, rocket, eyes)}"
    json_body=$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$reaction")
    api_post "${REPO_API}/issues/${num}/reactions" "$json_body" \
      | python3 -c "import json,sys; r=json.load(sys.stdin); print(f'Added {r[\"content\"]} reaction')"
    ;;

  create-label)
    require_token
    name="${1:?Usage: gh-api.sh create-label <name> <color-hex> [description]}"
    color="${2:?Usage: gh-api.sh create-label <name> <color-hex> [description]}"
    desc="${3:-}"
    json_body=$(python3 -c "import json,sys; print(json.dumps({'name':sys.argv[1],'color':sys.argv[2],'description':sys.argv[3]}))" "$name" "$color" "$desc")
    api_post "${REPO_API}/labels" "$json_body" \
      | python3 -c "import json,sys; l=json.load(sys.stdin); print(f'Created label: {l[\"name\"]} #{l[\"color\"]}')"
    ;;

  # ── Escape hatch ───────────────────────────────────────────────────────────
  raw)
    method="${1:?Usage: gh-api.sh raw <GET|POST|PATCH|DELETE> <path> [body]}"
    path="${2:?Usage: gh-api.sh raw <method> <path> [body]}"
    body="${3:-}"
    case "$method" in
      GET)    api_get "$path" | python3 -m json.tool ;;
      POST)   require_token; api_post "$path" "$body" | python3 -m json.tool ;;
      PATCH)  require_token; api_patch "$path" "$body" | python3 -m json.tool ;;
      DELETE) require_token; api_delete "$path" "$body" | python3 -m json.tool ;;
      *)      echo "Unknown method: $method (use GET|POST|PATCH|DELETE)" >&2; exit 1 ;;
    esac
    ;;

  # ── Auth setup ──────────────────────────────────────────────────────────────
  auth)
    subcmd="${1:-status}"
    shift || true

    case "$subcmd" in
      status)
        echo "─── GitHub Auth Status ───"
        if [[ -n "${GH_TOKEN:-}" ]]; then
          masked="${GH_TOKEN:0:8}...${GH_TOKEN: -4}"
          echo "  Token:  $masked"
          resp=$(api_get "${API}/rate_limit" 2>/dev/null || echo '{}')
          limit=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('resources',{}).get('core',{}).get('limit',0))" 2>/dev/null || echo 0)
          if [[ "$limit" -gt 60 ]]; then
            echo "  Status: authenticated ($limit req/hr)"
            user_resp=$(api_get "${API}/user" 2>/dev/null || echo '{}')
            login=$(echo "$user_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('login','unknown'))" 2>/dev/null || echo "unknown")
            echo "  User:   $login"
          else
            echo "  Status: token present but not authenticating (possibly expired)"
          fi
          echo ""
          echo "  Source:"
          if [[ -f "$REPO_ROOT/.env" ]] && grep -qE '^GH_TOKEN=' "$REPO_ROOT/.env" 2>/dev/null; then
            echo "    .env file (persistent across sessions)"
          fi
          if [[ -f "${HOME}/.config/gh/hosts.yml" ]]; then
            echo "    gh CLI config"
          fi
          echo "    environment variable"
        else
          echo "  Token:  not set (read-only mode)"
          echo ""
          echo "  To authenticate, run:"
          echo "    ./dev/gh-api.sh auth set <your-github-token>"
          echo ""
          echo "  To create a token:"
          echo "    1. Go to github.com/settings/tokens?type=beta"
          echo "    2. Create a fine-grained token for repo: ${OWNER_REPO}"
          echo "    3. Scopes: Issues (rw), Pull requests (rw), Contents (r)"
        fi
        ;;

      set)
        token="${1:?Usage: gh-api.sh auth set <github-token>}"

        # Validate token format
        if [[ ! "$token" =~ ^(ghp_|github_pat_|gho_|ghs_) ]]; then
          echo "WARNING: token doesn't match known GitHub token prefixes." >&2
          echo "         Expected: ghp_..., github_pat_..., gho_..., or ghs_..." >&2
          echo "         Proceeding anyway." >&2
          echo ""
        fi

        # 1. Save to .env (persistent, gitignored)
        if [[ -f "$REPO_ROOT/.env" ]]; then
          if grep -qE '^GH_TOKEN=' "$REPO_ROOT/.env"; then
            sed -i "s|^GH_TOKEN=.*|GH_TOKEN=${token}|" "$REPO_ROOT/.env"
            echo "  Updated GH_TOKEN in .env"
          else
            echo "" >> "$REPO_ROOT/.env"
            echo "GH_TOKEN=${token}" >> "$REPO_ROOT/.env"
            echo "  Added GH_TOKEN to .env"
          fi
        else
          echo "GH_TOKEN=${token}" > "$REPO_ROOT/.env"
          echo "  Created .env with GH_TOKEN"
        fi

        # 2. Inject into current Claude Code session
        if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
          echo "export GH_TOKEN='${token}'" >> "$CLAUDE_ENV_FILE"
          echo "  Injected into current session (CLAUDE_ENV_FILE)"
        fi

        # 3. Export for this script's remaining execution
        export GH_TOKEN="$token"

        # 4. Verify
        echo ""
        echo "  Verifying..."
        verify_resp=$(api_get "${API}/rate_limit" 2>/dev/null || echo '{}')
        verify_limit=$(echo "$verify_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('resources',{}).get('core',{}).get('limit',0))" 2>/dev/null || echo 0)
        if [[ "$verify_limit" -gt 60 ]]; then
          echo "  Token verified: authenticated ($verify_limit req/hr)"
          echo ""
          echo "  .env is gitignored — your token is safe."
          echo "  Future sessions will auto-detect it from .env."
        else
          echo "  WARNING: token saved but not authenticating with GitHub." >&2
          echo "  The token may be invalid, expired, or the API is rate-limited." >&2
          echo "  It's saved in .env — verify later with: ./dev/gh-api.sh auth status" >&2
        fi
        ;;

      remove)
        if [[ -f "$REPO_ROOT/.env" ]] && grep -qE '^GH_TOKEN=' "$REPO_ROOT/.env"; then
          sed -i '/^GH_TOKEN=/d' "$REPO_ROOT/.env"
          echo "  Removed GH_TOKEN from .env"
        else
          echo "  No GH_TOKEN found in .env"
        fi
        unset GH_TOKEN 2>/dev/null || true
        echo "  Unset GH_TOKEN from environment"
        echo "  Note: restart your session for full effect"
        ;;

      *)
        echo "Usage:" >&2
        echo "  gh-api.sh auth              # show auth status" >&2
        echo "  gh-api.sh auth status       # show auth status" >&2
        echo "  gh-api.sh auth set <token>  # save token to .env" >&2
        echo "  gh-api.sh auth remove       # remove saved token" >&2
        exit 1
        ;;
    esac
    ;;

  # ── Rate limit ──────────────────────────────────────────────────────────────
  rate-limit)
    api_get "${API}/rate_limit" | python3 -c "
import json, sys, datetime
d = json.load(sys.stdin)
for k in ('core', 'search', 'code_search'):
    v = d.get('resources', {}).get(k, {})
    if not v: continue
    reset = datetime.datetime.fromtimestamp(v['reset']).strftime('%H:%M:%S')
    bar_len = 20
    used_pct = v['used'] / max(v['limit'], 1)
    filled = int(bar_len * used_pct)
    bar = '#' * filled + '.' * (bar_len - filled)
    print(f'  {k:12s} [{bar}] {v[\"remaining\"]}/{v[\"limit\"]} remaining  (resets {reset})')
auth = 'authenticated' if d.get('resources',{}).get('core',{}).get('limit',0) > 60 else 'unauthenticated'
print(f'\n  Mode: {auth}')
"
    ;;

  # ── Help ────────────────────────────────────────────────────────────────────
  help|--help|-h)
    # Print the header comment block as help
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p; }' "$0"
    echo ""
    echo "─── Detected Configuration ───"
    echo "  Proxy:      $PROXY"
    echo "  Repository: $OWNER_REPO"
    echo "  GH_TOKEN:   ${GH_TOKEN:+set (write ops enabled)}${GH_TOKEN:-not set (read-only mode)}"
    if [[ -z "${GH_TOKEN:-}" ]]; then
      echo ""
      echo "  Run './dev/gh-api.sh auth set <token>' to enable write operations."
    fi
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    echo "Run '$(basename "$0") help' for usage." >&2
    exit 1
    ;;
esac
