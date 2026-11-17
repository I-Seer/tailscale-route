#!/bin/zsh
set -euo pipefail

request_id="$(/usr/bin/uuidgen)"
# "shutdown" = 停止分流 + 释放外接网段保护路由 + 恢复本 App 改过的
# Tailscale 偏好（accept-routes / exit-node-allow-lan-access）。
# 旧版用 "pause"，不会恢复 Tailscale 偏好，紧急恢复后子网路由可能仍被关闭。
request="$(/usr/bin/printf '{"requestID":"%s","action":"shutdown","configuration":null}' "$request_id")"

read_response='
/"isFinal":false/ {
    if (match($0, /"completed":[0-9]+/)) {
        progress = substr($0, RSTART, RLENGTH)
        sub(/.*:/, "", progress)
        printf "Helper 正在清理，进度 %s\n", progress
        fflush()
    }
}
/"isFinal":true/ { final_response = $0 }
END {
    if (final_response == "") {
        print "没有收到 Helper 的最终响应。"
        exit 2
    }

    if (match(final_response, /"message":"[^"]*"/)) {
        message = substr(final_response, RSTART + 11, RLENGTH - 12)
    } else {
        message = ""
    }

    if (final_response ~ /"success":[[:space:]]*true/) {
        printf "网络恢复完成：%s\n", message
        exit 0
    }

    printf "网络恢复未完成：%s\n", message
    exit 1
}
'

helper_sockets=(
  "/var/run/tailscale-route-helper.sock"
  "$HOME/Library/Application Support/tailscale-route/helper.sock"
)

for helper_socket in "${helper_sockets[@]}"; do
  [[ -S "$helper_socket" ]] || continue
  if /usr/bin/printf '%s\n' "$request" \
    | /usr/bin/nc -U "$helper_socket" 2>/dev/null \
    | /usr/bin/awk "$read_response"; then
    exit 0
  fi
done

# Helper 不可用时，至少清除断网保护的 pf 规则，避免整机无法联网。
kill_switch_anchor="com.apple/250.TailscaleRouteKillSwitch"
# 读取 pf 规则需要 root，因此以 Helper 写下的拦截状态文件为准。
if [[ -e /var/run/tailscale-route-killswitch.json ]]; then
  print "Helper 不可用，正在清除断网保护规则（需要管理员密码）…"
  if /usr/bin/sudo /sbin/pfctl -a "$kill_switch_anchor" -F all; then
    /usr/bin/sudo /bin/rm -f /var/run/tailscale-route-killswitch.json
    print "断网保护规则已清除。"
  fi
fi

print -u2 "无法连接 tailscale-route Helper。请确认 Helper 已安装并运行；未对系统路由做任何修改。"
exit 1
