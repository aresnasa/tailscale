#!/bin/sh
# tailscale CLI 包装: 自动使用与 tailscaled 相同的 socket，保证连通
# 用法: ./tailscale.sh status | up --authkey=tskey-xxx | netcheck | ...
set -eu
CONF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$CONF_DIR/tailscaled.env"
exec tailscale --socket="$TS_SOCKET" "$@"

