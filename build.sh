#!/usr/bin/env bash
# Build nginx for the `hosting` droplet on GitHub Actions (inside Ubuntu 18.04),
# download it, show the checks, and optionally publish a public release.
#
#   ./build.sh            build + download + check (into builds/<version>/)
#   ./build.sh --release  same, then publish a GitHub Release with the binary
#   NGINX_VERSION=1.30.6 ./build.sh   pick a version (default: newest stable)
set -euo pipefail

REPO=cartpauj/nginx-hosting
HERE="$(cd "$(dirname "$0")" && pwd)"
RELEASE=false
[ "${1:-}" = "--release" ] && RELEASE=true

VERSION=${NGINX_VERSION:-$(curl -fsSL https://nginx.org/en/download.html | grep -o 'Stable version.*' | grep -oE 'nginx-1\.[0-9]+\.[0-9]+' | head -1 | cut -d- -f2)}
# Release tag: nginx-<version>, or nginx-<version>-2, -3... when rebuilding the same version.
TAG="nginx-$VERSION"; N=1
while gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; do N=$((N+1)); TAG="nginx-$VERSION-$N"; done
echo "Building nginx $VERSION ($TAG)"

gh workflow run build.yml -R "$REPO" --ref main -f version="$VERSION"
sleep 10
RUN_ID=$(gh run list -R "$REPO" -w build.yml -e workflow_dispatch -L 1 --json databaseId -q '.[0].databaseId')
RUN_URL="https://github.com/$REPO/actions/runs/$RUN_ID"
echo "Build running: $RUN_URL"
gh run watch "$RUN_ID" -R "$REPO" --exit-status --interval 30 >/dev/null

OUT="$HERE/builds/${TAG#nginx-}"
rm -rf "$OUT" && mkdir -p "$OUT"
gh run download "$RUN_ID" -R "$REPO" -D "$OUT"
mv "$OUT/nginx-$VERSION"/* "$OUT/" && rmdir "$OUT/nginx-$VERSION"
chmod +x "$OUT/nginx"
cd "$OUT"
cat checks.txt
sha256sum -c SHA256SUMS

cat > notes.md <<NOTES
nginx $VERSION for Linux x86_64, built inside Ubuntu 18.04. It uses the system's OpenSSL 1.1.1,
PCRE2 and zlib, so the server's own security updates keep patching them.
Build run: $RUN_URL

\`\`\`
$(cat SHA256SUMS)
\`\`\`
NOTES

if $RELEASE; then
  gh release create "$TAG" nginx SHA256SUMS checks.txt -R "$REPO" --target main \
    --title "nginx ${TAG#nginx-} for hosting (Ubuntu 18.04)" --notes-file notes.md
fi
echo "Done: $OUT"
