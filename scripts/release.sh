#!/bin/sh
set -eu

# Cut a release in one command:
#   scripts/release.sh <version>          e.g.  scripts/release.sh 0.2.0
#
# It bumps the app version, commits "Release vX.Y.Z", tags it, pushes, and
# creates the GitHub release (notes from the matching CHANGELOG.md section, or
# auto-generated). Requires a clean working tree and the gh CLI.
#
# Tip: add the new version's section to CHANGELOG.md *before* running this.

VERSION="${1:-}"
case "${VERSION}" in
  "")  echo "Usage: scripts/release.sh <version>   (e.g. 0.2.0)"; exit 1 ;;
  v*)  echo "Pass the version without a leading 'v' (e.g. 0.2.0, not v0.2.0)"; exit 1 ;;
esac
echo "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || { echo "Version must be MAJOR.MINOR.PATCH (e.g. 0.2.0)"; exit 1; }

cd "$(dirname "$0")/.."

command -v gh >/dev/null 2>&1 || { echo "gh (GitHub CLI) is required: https://cli.github.com"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree is not clean — commit or stash changes first."; exit 1; }

TAG="v${VERSION}"
if git rev-parse "${TAG}" >/dev/null 2>&1; then
  echo "Tag ${TAG} already exists."; exit 1
fi

# Bump CFBundleShortVersionString in the installer's Info.plist template.
python3 - "${VERSION}" <<'PY'
import re, sys
v = sys.argv[1]
path = "scripts/install.sh"
src = open(path).read()
out, n = re.subn(
    r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)',
    r'\g<1>' + v + r'\g<2>', src)
if n == 0:
    sys.exit("Could not find CFBundleShortVersionString in scripts/install.sh")
open(path, "w").write(out)
PY

git add scripts/install.sh
if git diff --cached --quiet; then
  printf '%s\n' "scripts/install.sh already at ${VERSION}; tagging the current commit."
else
  git commit -m "Release ${TAG}"
fi
git tag "${TAG}"
git push origin HEAD
git push origin "${TAG}"

# Release notes: the matching CHANGELOG section if present, else auto-generated.
NOTES="$(awk -v v="${VERSION}" '
  $0 ~ ("^## \\[" v "\\]") { grab = 1; next }
  grab && /^## \[/         { exit }
  grab                     { print }
' CHANGELOG.md 2>/dev/null || true)"

if [ -n "$(printf '%s' "${NOTES}" | tr -d '[:space:]')" ]; then
  TMP_NOTES="$(mktemp)"
  printf '%s\n' "${NOTES}" > "${TMP_NOTES}"
  gh release create "${TAG}" --title "${TAG}" --notes-file "${TMP_NOTES}"
  rm -f "${TMP_NOTES}"
else
  gh release create "${TAG}" --title "${TAG}" --generate-notes
fi

echo "Released ${TAG}"
