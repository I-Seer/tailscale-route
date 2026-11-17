#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SOURCE="$ROOT_DIR/dist/tailscale-route.app"
APP_DEST="/Applications/tailscale-route.app"

if [[ ! -d "$APP_SOURCE" ]]; then
  "$ROOT_DIR/scripts/build.sh"
fi

/usr/bin/ditto "$APP_SOURCE" "$APP_DEST"
/usr/bin/open "$APP_DEST"
echo "已安装：$APP_DEST"
