#!/usr/bin/env bash
# scripts/sync_wiki.sh - Mirror local wiki/ directory to GitHub Wiki repository
set -euo pipefail

REPO_WIKI_URL="https://github.com/Swapnil-2004/A3-PS023-TC301.wiki.git"
TEMP_DIR=$(mktemp -d /tmp/gh_wiki_XXXXXX)

echo "==> Checking if GitHub Wiki repository is initialized..."
if ! git ls-remote "$REPO_WIKI_URL" > /dev/null 2>&1; then
    echo "[!] GitHub Wiki repository is not yet initialized by GitHub."
    echo "GitHub requires you to create the initial page once in your browser before enabling git access:"
    echo "👉 Visit: https://github.com/Swapnil-2004/A3-PS023-TC301/wiki/_new"
    echo "Click 'Save Page' to initialize it, then re-run this script!"
    exit 1
fi

echo "==> Cloning wiki repository..."
git clone "$REPO_WIKI_URL" "$TEMP_DIR"

echo "==> Copying wiki pages..."
cp -r wiki/* "$TEMP_DIR/"

echo "==> Committing and pushing to GitHub Wiki..."
cd "$TEMP_DIR"
git add .
if [ -n "$(git status --porcelain)" ]; then
    git commit -m "docs(wiki): update wiki documentation pages from main repository"
    git push origin master
    echo "==> SUCCESS: GitHub Wiki pages published successfully!"
else
    echo "==> GitHub Wiki is already up to date."
fi

rm -rf "$TEMP_DIR"
