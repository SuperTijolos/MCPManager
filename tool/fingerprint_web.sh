#!/usr/bin/env bash
# Run after `flutter build web --release`, before copying the build to a host
# behind a CDN.
#
# Flutter names its two main scripts the same in every build, and a CDN such as
# Cloudflare keeps any .js file for hours. After an update, people (and the
# edge) would keep loading the old app. This gives each script a name that
# changes with its content and points index.html at them, so a new build is
# fetched at once; index.html itself is never cached.
#
# Usage: tool/fingerprint_web.sh [build/web]
set -euo pipefail
cd "${1:-build/web}"

short() { sha256sum "$1" | cut -c1-10; }

main="main.$(short main.dart.js).dart.js"
mv main.dart.js "$main"
sed -i "s#\"main.dart.js\"#\"$main\"#g" flutter_bootstrap.js

boot="flutter_bootstrap.$(short flutter_bootstrap.js).js"
mv flutter_bootstrap.js "$boot"
sed -i "s#flutter_bootstrap\.js#$boot#g" index.html

echo "index.html -> $boot -> $main"
