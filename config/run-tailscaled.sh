#!/bin/sh
# 手动运行 tailscaled（生产环境建议 systemd，见 tailscaled.service）
# 需要 root（TUN 权限）; 无 root 测试可追加: --tun=userspace-networking
set -eu
CONF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$CONF_DIR/tailscaled.env"
mkdir -p "$TS_STATE_DIR"
exec tailscaled --statedir="$TS_STATE_DIR" --socket="$TS_SOCKET" --port="$TS_PORT" "$@"

