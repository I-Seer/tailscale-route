#!/bin/zsh
set -euo pipefail

APP_DEST="/Applications/tailscale-route.app"
HELPER_LABEL="com.tailscale-route.helper"

# 卸载前先让 Helper 清理：移除受管路由和 /etc/hosts 钉住，并恢复本 App
# 改过的 Tailscale 偏好。Helper 未运行时跳过，不影响卸载。
request_id="$(/usr/bin/uuidgen)"
request="$(/usr/bin/printf '{"requestID":"%s","action":"shutdown","configuration":null}' "$request_id")"
helper_cleaned=0
for helper_socket in "/var/run/tailscale-route-helper.sock" "$HOME/Library/Application Support/tailscale-route/helper.sock"; do
  [[ -S "$helper_socket" ]] || continue
  # 先完整读取响应再判断，避免 grep -q 提前退出在 pipefail 下误判失败。
  response="$(/usr/bin/printf '%s\n' "$request" | /usr/bin/nc -U "$helper_socket" 2>/dev/null || true)"
  final_line="$(/usr/bin/printf '%s\n' "$response" | /usr/bin/grep '"isFinal":true' | /usr/bin/tail -n 1 || true)"
  if [[ "$final_line" == *'"success":true'* ]]; then
    helper_cleaned=1
    break
  fi
done
if [[ "$helper_cleaned" -eq 1 ]]; then
  echo "Helper 已清理受管路由并恢复 Tailscale 原设置。"
else
  echo "警告：未能让 Helper 完成清理（可能未运行）。如之前启用过外接网卡保护，请在 Tailscale 中检查“Use Tailscale subnets”和“Allow LAN access”。" >&2
fi

# 无论 Helper 是否响应，都清除断网保护的 pf 规则，避免卸载后无法联网。
/sbin/pfctl -a "com.apple/250.TailscaleRouteKillSwitch" -F all 2>/dev/null || true
/bin/rm -f /var/run/tailscale-route-killswitch.json 2>/dev/null || true

/bin/launchctl bootout system/"$HELPER_LABEL" 2>/dev/null || true
/bin/rm -f "/Library/PrivilegedHelperTools/$HELPER_LABEL"
/bin/rm -f "/Library/LaunchDaemons/$HELPER_LABEL.plist"
/bin/rm -rf "$APP_DEST"

echo "已卸载 tailscale-route App 和 Helper。"
echo "用户配置仍保留在 ~/Library/Application Support/tailscale-route，如需清理请在 App 中选择“恢复系统默认”。"
