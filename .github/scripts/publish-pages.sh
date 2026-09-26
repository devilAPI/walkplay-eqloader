#!/usr/bin/env bash
# Publish a web build to the gh-pages branch, which GitHub Pages serves.
#
#   publish-pages.sh <build-dir> [preview]
#
# Without a second argument the build replaces the site root (the release
# site) and keeps preview/; with "preview" it replaces only preview/. The
# branch holds a single commit: the site is generated, never edited, so its
# history is dropped on every deploy.
#
# Needs GH_TOKEN (contents: write), GITHUB_REPOSITORY and GITHUB_SHA.
set -euo pipefail

src=$(cd "$1" && pwd)
target=${2:-}
remote="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
site=$(mktemp -d)

if git ls-remote --exit-code --heads "$remote" gh-pages >/dev/null 2>&1; then
  git clone --quiet --depth 1 --branch gh-pages "$remote" "$site"
else
  git init --quiet "$site"
  git -C "$site" remote add origin "$remote"
fi
cd "$site"

if [ -z "$target" ]; then
  find . -mindepth 1 -maxdepth 1 ! -name .git ! -name preview -exec rm -rf {} +
  cp -r "$src"/. .
else
  rm -rf "$target"
  mkdir -p "$target"
  cp -r "$src"/. "$target"/
fi
touch .nojekyll # serve files as-is (no Jekyll processing)

git checkout --quiet --orphan deploy
git add -A
git -c user.name='github-actions[bot]' \
  -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit --quiet -m "Deploy ${target:-release site} from ${GITHUB_SHA::7}"
git push --quiet --force origin deploy:gh-pages
echo "Published ${target:-release site} to gh-pages."
