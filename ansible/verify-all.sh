#!/bin/sh
# verify-all.sh — Tailscale exit node 完整验证
# 用法: cd ansible && ./verify-all.sh

set -e
cd "$(dirname "$0")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo "${GREEN}✓ $1${NC}"; }
fail() { echo "${RED}✗ $1${NC}"; }
info() { echo "${YELLOW}▶ $1${NC}"; }

REMOTE_HOST="root@10.9.202.217"
TS_SOCKET_MAC="/Users/aresnasa/.tailscale/tailscaled.sock"
TS_BIN_MAC="/Users/aresnasa/.tailscale/bin/tailscale"

echo "═══════════════════════════════════════════════════════════"
echo "  Tailscale Exit Node 完整验证"
echo "═══════════════════════════════════════════════════════════"
echo ""

# 1. Mac daemon 状态
info "1. 检查 Mac daemon 状态"
MAC_STATUS=$("$TS_BIN_MAC" --socket="$TS_SOCKET_MAC" status 2>&1 | head -1)
if echo "$MAC_STATUS" | grep -q "Logged out"; then
    fail "Mac tailscaled 未登录"
    echo "  登录: $TS_BIN_MAC --socket=$TS_SOCKET_MAC up --hostname=mac-mini --advertise-exit-node"
    exit 1
fi
MAC_IP=$(echo "$MAC_STATUS" | awk '{print $1}')
pass "Mac tailscaled 在线，IP: $MAC_IP"

# 2. Mac exit node 广播
info "2. 检查 Mac exit node 广播"
if "$TS_BIN_MAC" --socket="$TS_SOCKET_MAC" status 2>&1 | grep -q "offers exit node"; then
    pass "Mac 正在广播 exit node"
else
    fail "Mac 未广播 exit node"
    echo "  执行: $TS_BIN_MAC --socket=$TS_SOCKET_MAC up --hostname=mac-mini --advertise-exit-node"
    echo "  然后去管理后台批准 exit node"
    exit 1
fi

# 3. Mac Clash 代理
info "3. 检查 Mac Clash 代理"
CLASH_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 3 -x http://127.0.0.1:7890 https://github.com 2>/dev/null || echo "000")
if [ "$CLASH_CODE" = "200" ]; then
    pass "Clash Verge 代理正常 (7890)"
else
    fail "Clash Verge 代理不可用 (HTTP $CLASH_CODE)"
    echo "  启动 Clash Verge 并确认 7890 端口"
    exit 1
fi

# 4. Mac exit node 转发路径（Clash TUN/增强模式）
info "4. 检查 Mac exit node 转发路径（Clash TUN/增强模式）"
echo "  exit node 的转发流量走系统默认出站路径。"
echo "  请确认 Clash Verge 已开启 TUN/增强模式，否则被墙站点（GitHub/Google）会失败。"

# 5. 217 tailscale 状态
info "5. 检查 217 tailscale 状态"
REMOTE_STATUS=$(ssh "$REMOTE_HOST" 'tailscale --socket=/var/run/tailscale/tailscaled.sock status 2>&1' 2>/dev/null)
if echo "$REMOTE_STATUS" | grep -q "exit node"; then
    REMOTE_IP=$(echo "$REMOTE_STATUS" | head -1 | awk '{print $1}')
    pass "217 在线 ($REMOTE_IP)，已使用 exit node"
else
    fail "217 未启用 exit node"
    echo "  远端状态:"
    echo "$REMOTE_STATUS" | sed 's/^/    /'
    echo "  修复: ./.venv/bin/ansible-playbook playbooks/deploy.yml --tags up"
    exit 1
fi

# 6. 217 内网直连
info "6. 检查 217 内网直连（lan-access）"
GW_PING=$(ssh "$REMOTE_HOST" 'ping -c 1 -W 2 10.9.202.1 2>&1' 2>/dev/null)
if echo "$GW_PING" | grep -q "0% packet loss"; then
    pass "217 内网网关 10.9.202.1 可达（直连）"
else
    fail "217 内网网关不可达"
    echo "  修复: ./.venv/bin/ansible-playbook playbooks/deploy.yml --tags lan"
fi

IP_RULE=$(ssh "$REMOTE_HOST" 'ip rule show | grep "^5260:"' 2>/dev/null)
if [ -n "$IP_RULE" ]; then
    pass "217 ip rule 5260 已安装"
else
    fail "217 缺少 ip rule 5260（lan-access）"
    echo "  修复: ./.venv/bin/ansible-playbook playbooks/deploy.yml --tags lan"
fi

# 7. 217 内网绕过配置（lan-routes.conf）
info "7. 检查 217 内网绕过配置（lan-routes.conf）"
LAN_CONF=$(ssh "$REMOTE_HOST" 'cat /etc/tailscale/lan-routes.conf 2>/dev/null' 2>/dev/null)
if echo "$LAN_CONF" | grep -q "10.0.0.0/8"; then
    pass "217 lan-routes.conf 包含 10.0.0.0/8"
else
    fail "217 lan-routes.conf 缺失"
    echo "  修复: ./.venv/bin/ansible-playbook playbooks/deploy.yml --tags detect,lan"
fi

# 8. GitHub
info "8. 测试 217 经 exit node 访问 GitHub"
GITHUB_CODE=$(ssh "$REMOTE_HOST" 'curl -4 -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 --resolve github.com:443:20.205.243.166 https://github.com 2>/dev/null || echo "000"' 2>/dev/null)
if [ "$GITHUB_CODE" = "200" ]; then
    pass "217 → GitHub: HTTP 200 (经 Mac exit node + Clash)"
else
    fail "217 → GitHub: HTTP $GITHUB_CODE"
fi

# 9. Google
info "9. 测试 217 经 exit node 访问 Google"
GOOGLE_CODE=$(ssh "$REMOTE_HOST" 'curl -4 -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 --resolve www.google.com:443:142.250.80.46 https://www.google.com 2>/dev/null || echo "000"' 2>/dev/null)
if [ "$GOOGLE_CODE" = "200" ]; then
    pass "217 → Google: HTTP 200 (经 Mac exit node + Clash)"
else
    fail "217 → Google: HTTP $GOOGLE_CODE (Google IP 可能已变，手动验证)"
fi

# 10. 纯 IP 隧道测试
info "10. 测试 217 纯 IP 经 exit node（隧道连通性）"
CF_CODE=$(ssh "$REMOTE_HOST" 'curl -4 -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 20 https://1.1.1.1 2>/dev/null || echo "000"' 2>/dev/null)
if [ "$CF_CODE" = "301" ] || [ "$CF_CODE" = "200" ]; then
    pass "217 → 1.1.1.1: HTTP $CF_CODE (exit node 隧道正常)"
else
    fail "217 → 1.1.1.1: HTTP $CF_CODE (隧道可能不通)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  验证完成"
echo "═══════════════════════════════════════════════════════════"
