# == repoify.sh ==
set -euo pipefail

GH_USER="Sonni4154"
REPO_NAME="wmx"
REPO_DESC="WMX backend + modular QBO token manager (Node/TypeScript, Postgres, Docker, Nginx)"
WORKDIR="/opt/wmx"

cd "$WORKDIR"

# 1) .gitignore (safe defaults for Node/TS/Docker + env files)
cat > .gitignore <<'GIT'
# Node / pnpm
node_modules/
pnpm-lock.yaml

# Builds
dist/
build/
*.tsbuildinfo

# Env & secrets
.env
*.env
infra/docker/.env

# Logs / dumps
npm-debug.log*
yarn-debug.log*
yarn-error.log*
pnpm-debug.log*
*.log
*.pid
*.seed
*.dump

# Editor/OS
.DS_Store
.vscode/
.idea/
GIT

# 2) README placeholder (paste the full content from the Canvas doc after push, or now)
if [ ! -f README.md ]; then
  cat > README.md <<'MD'
# WMX Backend + QBO Token Manager

> This is a placeholder. Paste the full README content from your Canvas doc
> titled **“Vps Backend Starter + Deploy Kit”** (Architecture, operations,
> token manager, integrations, API links, ops commands, troubleshooting, etc.)

MD
fi

# 3) Initialize git repo if needed
if [ ! -d .git ]; then
  git init -b main 2>/dev/null || (git init && git checkout -b main)
fi

git add .
git commit -m "Initial commit: WMX backend + modular QBO token manager (infra + services + docs placeholder)" || true

# 4) Create GitHub repo (prefer gh CLI if available; else use API with GITHUB_TOKEN)
create_repo_via_api() {
  test -n "${GITHUB_TOKEN:-}" || { echo "ERROR: Set GITHUB_TOKEN with 'repo' scope to create repo via API."; return 1; }
  curl -fsSL -H "Authorization: token ${GITHUB_TOKEN}" \
       -H "Accept: application/vnd.github+json" \
       https://api.github.com/user/repos \
       -d "$(jq -n --arg n "$REPO_NAME" --arg d "$REPO_DESC" '{name:$n, description:$d, private:false}')" \
  >/dev/null || true
}

if command -v gh >/dev/null 2>&1; then
  # Create if missing (gh will error if it already exists; that's fine)
  gh repo view "$GH_USER/$REPO_NAME" >/dev/null 2>&1 || gh repo create "$GH_USER/$REPO_NAME" --public -y -d "$REPO_DESC"
else
  create_repo_via_api || true
fi

# 5) Set remote (prefer SSH if you’ve set up keys; fallback to HTTPS)
if git remote get-url origin >/dev/null 2>&1; then
  echo "Remote 'origin' already set -> $(git remote get-url origin)"
else
  if [ -f "$HOME/.ssh/id_rsa" ] || [ -f "$HOME/.ssh/id_ed25519" ]; then
    git remote add origin "git@github.com:${GH_USER}/${REPO_NAME}.git"
  else
    git remote add origin "https://github.com/${GH_USER}/${REPO_NAME}.git"
  fi
fi

# 6) Push
git push -u origin main

echo
echo "✅ Repo pushed: https://github.com/${GH_USER}/${REPO_NAME}"
echo "👉 Next: open README.md and paste the full content from your Canvas doc, then:"
echo "   git add README.md && git commit -m 'docs: add full architecture & ops README' && git push"

