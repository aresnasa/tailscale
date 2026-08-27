# Tailscale Ansible 自动部署 — 中文文档

## 概述

在**本机 macOS** 上作为 Ansible 控制节点，向两台目标机部署 headless 版 `tailscaled` + `tailscale`：

| 节点 | 地址 | 角色 | 平台 | 二进制产物 | 守护方式 |
| --- | --- | --- | --- | --- | --- |
| mac-mini（本机） | localhost | **exit node**（出口网关） | darwin/arm64 | `dist/*-darwin-arm64` | 用户级 LaunchAgent（非 root，userspace-networking） |
| box-217（远端） | 10.9.202.217 (root) | **exit node client**（经 Mac 出网） | linux/amd64 | `dist/*-linux-amd64` | systemd (`tailscaled.service`) |

**拓扑意图**：217 的出网流量经 Tailscale 隧道送到 Mac，由 Mac 通过 Clash Verge（TUN/增强模式）转发到公网。

```mermaid
graph LR
    A["box-217 (Linux)<br/>10.9.202.217"] -->|"Tailscale 隧道"| B["mac-mini (macOS)<br/>exit node"]
    B -->|"Clash TUN<br/>增强模式"| C["公网<br/>GitHub / Google"]
    A -.->|"lan-access<br/>内网直连"| D["内网<br/>10.9.202.0/24"]
```

---

## 前置条件

1. **控制节点 (Mac)**: ansible-core 2.18（用仓库自带的 venv）：
   ```sh
   /opt/homebrew/bin/python3.13 -m venv .venv
   ./.venv/bin/pip install 'ansible-core>=2.18,<2.19'
   ```

2. 远端 `10.9.202.217` 可免密 SSH（root）。

3. **Mac 上 Clash Verge 已启动并开启 TUN/增强模式**（关键：仅系统代理不够，
   netstack 转发不走系统代理）。验证：关闭系统代理后 Mac 仍能直连
   `https://www.google.com`，即为 TUN 已接管。

4. **Mac 上 Tailscale GUI 客户端已退出**（避免抢占端口/接口）。

5. 已在 Tailscale 管理后台生成 **auth key**（可选，用于自动注册）：
   https://login.tailscale.com/admin/settings/keys

---

## 分阶段部署

### 阶段 1：构建并安装（不涉及登录/配置，最快）

```sh
cd ansible
./.venv/bin/ansible-playbook playbooks/deploy.yml --tags build,install
```

**做什么**：
- 交叉编译 `tailscale` + `tailscaled`（darwin/arm64 + linux/amd64）
- 分发二进制到 Mac (`~/.tailscale/bin/`) 和 217 (`/usr/local/bin/`)
- 生成 `tailscaled.env`（含 `HTTP_PROXY`/`HTTPS_PROXY`，仅用于连控制面）
- 安装 daemon（Mac: LaunchAgent / 217: systemd）并启动
- 等待 daemon 就绪

**预期输出**：两节点 `ok`，`changed`（二进制/配置有更新），无 `failed`。

### 阶段 2：检测内网 + 配置 exit node + lan-access

```sh
./.venv/bin/ansible-playbook playbooks/deploy.yml --tags detect,up,lan
```

**做什么**：
- 自动检测 RFC1918 三大私有网段（`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`）
- Mac: `tailscale up --advertise-exit-node`（广播出口节点）
- 217: `tailscale up --exit-node=<Mac-IP> --exit-node-allow-lan-access`
- 内网不走隧道（lan-access ip rule 5260）
- 安装 `tailscale-lan-rules.service`（ip rule 5260，绕过 table 52 的 throw）

**如果节点未登录**：
- Playbook 会输出登录 URL（`https://login.tailscale.com/a/xxx`）
- 浏览器打开完成认证后，重跑 `--tags up`

**如果 Mac exit node 未审批**：
- Playbook 输出提示框，去管理后台批准：
  https://login.tailscale.com/admin/machines → mac-mini → ⋯ → Edit route settings → 勾选 Use as exit node

### 阶段 3：验证

```sh
./.venv/bin/ansible-playbook playbooks/deploy.yml --tags verify
# 或用专门的验证 playbook（末尾汇总结论，Mac→217 走 tailscale ping，只要 stdout 有 pong 即为通）
./.venv/bin/ansible-playbook playbooks/verify.yml
# 或交互脚本（可选输入 Mac sudo / 自定义 TEST_URLS）
./scripts/verify-interactive.sh
```

> **说明**：`tailscale ping` 若走 DERP 中转（绝大多数跨地域场景）会在最后一行提示 `direct connection not established` 并设 rc=1，但任何一句 `pong from xxx` 返回即代表连通。verify.yml 会以 stdout 包含 `pong from` 为连通标准。

### 全量一键（带 authkey）

```sh
./.venv/bin/ansible-playbook playbooks/deploy.yml -e ts_authkey=tskey-auth-xxxxxxxx
```

### 两阶段交互部署（推荐：自动回填 Mac tailnet IP）

推荐用 `scripts/deploy-interactive.sh` 驱动全流程，脚本会依次：

1. 提示输入 **`ts_authkey`**（读自 `TS_AUTHKEY` 环境变量优先）
2. 提示输入本机 **Mac sudo 密码**（读自 `MAC_SUDO` 环境变量优先，校验后透传 ansible_become_password）
3. **Phase 1**: `--tags build,install,detect,up` —— 构建 + 分发 + Mac 用 authkey 自动注册并起 up `--advertise-exit-node`
4. 提示你在管理后台 [批准 mac-mini 为 exit node](https://login.tailscale.com/admin/machines)
5. **Phase 2**: `--tags discover,up,lan,dns,verify` —— 查询 `tailscale ip -4` 得到 Mac 实际 tailnet IP，自动回填 `inventory/hosts.ini` 里客户端的 `ts_exit_node=`，重跑客户端 up/lan/dns 并验证

```sh
# 什么都不输入，逐项提示
./scripts/deploy-interactive.sh

# 或预先提供
TS_AUTHKEY=tskey-auth-xxx MAC_SUDO=xxx ./scripts/deploy-interactive.sh
```

也可只手动走一次 discover（比如换 Mac 后重同步 IP）：
```sh
./.venv/bin/ansible-playbook playbooks/deploy.yml --tags discover
```

---

## Tag 说明

| Tag | 阶段 | 说明 |
|---|---|---|
| `build` | 1a | 交叉编译 darwin/arm64 + linux/amd64 二进制 |
| `install` | 1b | 分发二进制 + 生成配置 + 启动 daemon |
| `detect` | 2 | 检测 RFC1918 三大私有网段 → 填充 `ts_ignore_routes` |
| `up` | 3 | tailscale up（Mac 广播 exit node，客户端指向 Mac） |
| `discover` | 3.5 | 查询 tailnet IP + 回填 `ts_exit_node` + 重算 up 命令 （`ts_interactive=true` 时会先暂停等确认） |
| `lan` | 3 | 配置 ip rule 5260 绕过 table 52（内网双向可达） |
| `dns` | 3 | 仅在 `-e ts_dns_tcp_override=true` 时启用，默认不修改 DNS |
| `verify` | 4 | 验证：tailscale status + 内网 ping + 外网 curl |

> **DNS 默认行为**：不修改 217 原生 DNS（k8s 集群的 10.9.200.21 / 10.96.0.10）。部署后 tailscaled 通过 `--accept-dns=false` 保持不接管本地 DNS。仅在明确需要 TCP 转发绕 GFW 时使用：
> ```sh
> ./.venv/bin/ansible-playbook playbooks/deploy.yml -e ts_dns_tcp_override=true --tags dns
> ```

---

## 完整验证脚本

以下脚本用于部署完成后的全面验证。**在 `ansible/` 目录下执行**。

### 一键验证脚本

```sh
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

# 从 inventory 读取 217 的 SSH 地址
REMOTE_HOST="root@10.9.202.217"
TS_SOCKET_MAC="/Users/aresnasa/.tailscale/tailscaled.sock"
TS_BIN_MAC="/Users/aresnasa/.tailscale/bin/tailscale"

echo "═══════════════════════════════════════════════════════════"
echo "  Tailscale Exit Node 完整验证"
echo "═══════════════════════════════════════════════════════════"
echo ""

# -------------------------------------------------------
info "1. 检查 Mac daemon 状态"
# -------------------------------------------------------
MAC_STATUS=$("$TS_BIN_MAC" --socket="$TS_SOCKET_MAC" status 2>&1 | head -1)
if echo "$MAC_STATUS" | grep -q "Logged out"; then
    fail "Mac tailscaled 未登录"
    echo "  登录: $TS_BIN_MAC --socket=$TS_SOCKET_MAC up --hostname=mac-mini --advertise-exit-node"
    exit 1
fi
MAC_IP=$(echo "$MAC_STATUS" | awk '{print $1}')
pass "Mac tailscaled 在线，IP: $MAC_IP"

# -------------------------------------------------------
info "2. 检查 Mac exit node 广播"
# -------------------------------------------------------
if "$TS_BIN_MAC" --socket="$TS_SOCKET_MAC" status 2>&1 | grep -q "offers exit node"; then
    pass "Mac 正在广播 exit node"
else
    fail "Mac 未广播 exit node"
    echo "  执行: $TS_BIN_MAC --socket=$TS_SOCKET_MAC up --hostname=mac-mini --advertise-exit-node"
    echo "  然后去管理后台批准 exit node"
    exit 1
fi

# -------------------------------------------------------
info "3. 检查 Mac Clash 代理"
# -------------------------------------------------------
CLASH_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 3 -x http://127.0.0.1:7890 https://github.com 2>/dev/null || echo "000")
if [ "$CLASH_CODE" = "200" ]; then
    pass "Clash Verge 代理正常 (7890)"
else
    fail "Clash Verge 代理不可用 (HTTP $CLASH_CODE)"
    echo "  启动 Clash Verge 并确认 7890 端口"
    exit 1
fi

# -------------------------------------------------------
info "4. 检查 Mac exit node 转发路径（Clash TUN/增强模式）"
# -------------------------------------------------------
echo "  exit node 的转发流量走系统默认出站路径。"
echo "  请确认 Clash Verge 已开启 TUN/增强模式，否则被墙站点（GitHub/Google）会失败。"

# -------------------------------------------------------
info "5. 检查 217 tailscale 状态"
# -------------------------------------------------------
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

# -------------------------------------------------------
info "6. 检查 217 内网直连（lan-access）"
# -------------------------------------------------------
GW_PING=$(ssh "$REMOTE_HOST" 'ping -c 1 -W 2 10.9.202.1 2>&1' 2>/dev/null)
if echo "$GW_PING" | grep -q "1 packets received"; then
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

# -------------------------------------------------------
info "7. 检查 217 内网绕过配置（lan-routes.conf）"
# -------------------------------------------------------
LAN_CONF=$(ssh "$REMOTE_HOST" 'cat /etc/tailscale/lan-routes.conf 2>/dev/null' 2>/dev/null)
if echo "$LAN_CONF" | grep -q "10.0.0.0/8"; then
    pass "217 lan-routes.conf 包含 10.0.0.0/8"
else
    fail "217 lan-routes.conf 缺失"
    echo "  修复: ./.venv/bin/ansible-playbook playbooks/deploy.yml --tags detect,lan"
fi

# -------------------------------------------------------
info "8. 测试 217 经 exit node 访问 GitHub"
# -------------------------------------------------------
GITHUB_CODE=$(ssh "$REMOTE_HOST" 'curl -4 -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 --resolve github.com:443:20.205.243.166 https://github.com 2>/dev/null || echo "000"' 2>/dev/null)
if [ "$GITHUB_CODE" = "200" ]; then
    pass "217 → GitHub: HTTP 200 (经 Mac exit node + Clash)"
else
    fail "217 → GitHub: HTTP $GITHUB_CODE"
fi

# -------------------------------------------------------
info "9. 测试 217 经 exit node 访问 Google"
# -------------------------------------------------------
GOOGLE_CODE=$(ssh "$REMOTE_HOST" 'curl -4 -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 --resolve www.google.com:443:142.250.80.46 https://www.google.com 2>/dev/null || echo "000"' 2>/dev/null)
if [ "$GOOGLE_CODE" = "200" ]; then
    pass "217 → Google: HTTP 200 (经 Mac exit node + Clash)"
else
    fail "217 → Google: HTTP $GOOGLE_CODE (Google IP 可能已变，手动验证: ssh root@10.9.202.217 'curl -4 -sS -o /dev/null -w \"%{http_code}\" --resolve www.google.com:443:<IP> https://www.google.com')"
fi

# -------------------------------------------------------
info "10. 测试 217 纯 IP 经 exit node（隧道连通性）"
# -------------------------------------------------------
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
```

### 使用方法

```sh
cd ansible
chmod +x verify-all.sh
./verify-all.sh
```

### 预期输出（全部通过）

```
═══════════════════════════════════════════════════════════
  Tailscale Exit Node 完整验证
═══════════════════════════════════════════════════════════

▶ 1. 检查 Mac daemon 状态
✓ Mac tailscaled 在线，IP: 100.112.144.72
▶ 2. 检查 Mac exit node 广播
✓ Mac 正在广播 exit node
▶ 3. 检查 Mac Clash 代理
✓ Clash Verge 代理正常 (7890)
▶ 4. 检查 Mac exit node 转发路径（Clash TUN/增强模式）
  exit node 的转发流量走系统默认出站路径。
▶ 5. 检查 217 tailscale 状态
✓ 217 在线 (100.73.82.118)，已使用 exit node
▶ 6. 检查 217 内网直连（lan-access）
✓ 217 内网网关 10.9.202.1 可达（直连）
✓ 217 ip rule 5260 已安装
▶ 7. 检查 217 内网绕过配置（lan-routes.conf）
✓ 217 lan-routes.conf 包含 10.0.0.0/8
▶ 8. 测试 217 经 exit node 访问 GitHub
✓ 217 → GitHub: HTTP 200 (经 Mac exit node + Clash)
▶ 9. 测试 217 经 exit node 访问 Google
✓ 217 → Google: HTTP 200 (经 Mac exit node + Clash)
▶ 10. 测试 217 纯 IP 经 exit node（隧道连通性）
✓ 217 → 1.1.1.1: HTTP 301 (exit node 隧道正常)

═══════════════════════════════════════════════════════════
  验证完成
═══════════════════════════════════════════════════════════
```

---

## 手动验证步骤

如果不想用脚本，可以逐项手动验证：

### 1. Mac daemon 状态

```sh
/Users/aresnasa/.tailscale/bin/tailscale --socket=/Users/aresnasa/.tailscale/tailscaled.sock status
```

**预期**：显示 `mac-mini` 在线，且另一行显示 `offers exit node`。

### 2. Mac Clash 代理

```sh
curl -sS -o /dev/null -w "%{http_code}" -x http://127.0.0.1:7890 https://github.com
```

**预期**：`200`。

### 3. Mac 控制面代理进程环境

```sh
PID=$(pgrep -f 'tailscaled.*userspace' | head -1)
ps -p "$PID" -wwwE | tr ' ' '\n' | grep -E "HTTP_PROXY|HTTPS_PROXY"
```

**预期**：
```
HTTPS_PROXY=http://127.0.0.1:7890
HTTP_PROXY=http://127.0.0.1:7890
```

### 4. 217 tailscale 状态

```sh
ssh root@10.9.202.217 'tailscale --socket=/var/run/tailscale/tailscaled.sock status'
```

**预期**：显示 `mac-mini` 行末尾有 `exit node`。

### 5. 217 内网直连

```sh
ssh root@10.9.202.217 'ping -c 2 10.9.202.1'
```

**预期**：`0% packet loss`。

### 6. 217 ip rule 5260

```sh
ssh root@10.9.202.217 'ip rule show | grep "^5260:"'
```

**预期**：
```
5260:	from all to 10.0.0.0/8 lookup main
5260:	from all to 172.16.0.0/12 lookup main
5260:	from all to 192.168.0.0/16 lookup main
```

### 7. 217 table 52（Tailscale 路由表）

```sh
ssh root@10.9.202.217 'ip route show table 52 | grep -E "^(throw|default)"'
```

**预期**：
```
default dev tailscale0
throw 10.9.202.0/24
throw 127.0.0.0/8
```

### 8. 217 内网绕过配置（lan-routes.conf）

```sh
ssh root@10.9.202.217 'cat /etc/tailscale/lan-routes.conf'
```

**预期**：
```
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
```

### 9. 217 经 exit node 访问外网

```sh
# GitHub（用 --resolve 绕过 DNS 污染）
ssh root@10.9.202.217 'curl -4 -sS -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" --resolve github.com:443:20.205.243.166 https://github.com'

# Google
ssh root@10.9.202.217 'curl -4 -sS -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" --resolve www.google.com:443:142.250.80.46 https://www.google.com'

# 纯 IP 测试隧道（不涉及 DNS）
ssh root@10.9.202.217 'curl -4 -sS -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" https://1.1.1.1'
```

**预期**：全部 `HTTP 200` 或 `HTTP 301`。

---

## 常见问题排查

### 问题：217 curl 超时（HTTP 000）

**检查 exit node 隧道是否通**：
```sh
ssh root@10.9.202.217 'curl -4 -sS -o /dev/null -w "%{http_code}" https://1.1.1.1'
```

- 如果也超时 → exit node 隧道不通，检查 Mac 是否在线 + Clash 是否在跑
- 如果通 → DNS 问题，用 `--resolve` 绕过

### 问题：DNS 解析超时

GFW 环境下 UDP 53 被 Wall，Mac 的 Clash TUN 模式也只代理 TCP。

**临时绕过**：用 `--resolve` 指定 IP：
```sh
ssh root@10.9.202.217 'curl --resolve github.com:443:20.205.243.166 https://github.com'
```

### 问题：Mac 显示 `Logged out`

```sh
# 重启 daemon
launchctl kickstart -k gui/$(id -u)/com.tailscale.tailscaled

# 重新 up（会输出登录 URL）
/Users/aresnasa/.tailscale/bin/tailscale --socket=/Users/aresnasa/.tailscale/tailscaled.sock up --hostname=mac-mini --advertise-exit-node
```

浏览器打开输出的 URL 完成认证。

### 问题：`invalid value "mac-mini" for --exit-node`

inventory 里的 `ts_exit_node` 需要用 IP 而非主机名。更新 `inventory/hosts.ini`：
```
ts_exit_node=100.112.144.72
```

获取当前 IP：
```sh
/Users/aresnasa/.tailscale/bin/tailscale --socket=/Users/aresnasa/.tailscale/tailscaled.sock ip -4
```

### 问题：exit node 未审批

Mac `up --advertise-exit-node` 后需要去管理后台批准：

1. https://login.tailscale.com/admin/machines
2. 找到 `mac-mini` → `⋯` → **Edit route settings**
3. 勾选 **Use as exit node** → **Save**

### 问题：217 内网不可达

检查 ip rule 5260 是否存在：
```sh
ssh root@10.9.202.217 'ip rule show | grep 5260'
```

如果不存在，手动应用：
```sh
ssh root@10.9.202.217 '/usr/local/sbin/tailscale-lan-rules.sh up'
```

或重跑 playbook：
```sh
./.venv/bin/ansible-playbook playbooks/deploy.yml --tags lan
```

### 问题：Mac 上两个 Tailscale 冲突

如果 Mac 上同时跑着 GUI 版和自建 CLI 版：

```sh
# 退出 GUI 版
osascript -e 'quit app "Tailscale"'

# 确认只有自建 CLI 版在跑
pgrep -fl tailscaled
```

如果系统扩展（network-extension）还在跑，需要重启 Mac 彻底清除。

---

## 目录结构

```
ansible/
├── ansible.cfg                              # Ansible 配置
├── .venv/                                   # ansible-core 2.18
├── inventory/
│   ├── hosts.ini                            # mac-mini + box-217
│   └── host_vars/box-217.yml               # 217 主机变量
├── playbooks/
│   ├── group_vars/all.yml                   # 共用变量
│   ├── acl/acl.json                         # ACL 策略
│   ├── templates/
│   │   ├── tailscaled.env.j2               # /etc/default/tailscaled
│   │   ├── tailscaled.service.j2           # Linux systemd
│   │   ├── com.tailscale.tailscaled.plist.j2  # Mac LaunchAgent
│   │   ├── detect-lan-cidrs.sh.j2          # 内网网段检测脚本
│   │   ├── tailscale-lan-rules.sh.j2       # ip rule 管理脚本
│   │   └── tailscale-lan-rules.service.j2  # lan-access systemd
│   ├── deploy.yml                           # 主部署（分阶段: build→install→detect→up→lan→verify）
│   ├── verify.yml                           # 专门验证
│   ├── lan-access.yml                       # 内网双向可达
│   ├── reset.yml                            # 重置节点
│   ├── bypass.yml                           # 直连白名单
│   ├── force-tunnel.yml                     # 强制走隧道
│   └── control.yml                          # ACL + 用户管理
├── tests/
│   ├── mock_tailscale_api.py
│   └── mock-vars.yml
├── verify-all.sh                            # 一键验证脚本
└── README_zhCN.md                           # 本文档
```

---

## 关键配置说明

### 代理配置（Mac 专用）

| 变量 | 作用 | 影响范围 |
|---|---|---|
| `ts_control_proxy` | tailscaled 连控制面走 Clash（`HTTP_PROXY`/`HTTPS_PROXY`） | 仅 Mac（`ts_platform=darwin`） |

> Linux 客户端不加这个变量，避免连本地不存在的代理。

### 路由优先级

```
force-tunnel(5050) < bypass(5100) < lan-access(5260) < Tailscale(5270)
```

| 优先级 | 规则 | 作用 |
|---|---|---|
| 5050 | `to <IP> lookup 52` | 强制走隧道（覆盖 bypass 和 lan-access） |
| 5100 | `to <IP> lookup main` | 直连白名单（绕过 exit node） |
| 5260 | `to <CIDR> lookup main` | 内网双向可达（绕过 table 52） |
| 5270 | `from all lookup 52` | Tailscale 默认（exit node 路由） |

### 内网网段（RFC1918 三大段）

| 网段 | 覆盖场景 |
|---|---|
| `10.0.0.0/8` | 物理网卡 LAN、K8s pod/service、Cilium |
| `172.16.0.0/12` | Docker bridge（172.17/16）、Docker 自定义网络 |
| `192.168.0.0/16` | 家庭/办公 LAN、Flannel/Calico CNI |

### 已知限制

- **DNS 污染**：GFW 环境下 UDP 53 被 Wall。验证时用 `--resolve` 绕过。生产环境需配 DoH/TCP DNS。
- **ICMP 不转发**：Mac `userspace-networking` 模式不支持 ICMP 转发，Mac ping 217 会超时，属正常现象。
- **exit node 需审批**：Mac `up --advertise-exit-node` 后需在管理后台一次性批准。
