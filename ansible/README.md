# Ansible 自动部署 tailscaled/tailscale（两机联通测试）

在**本机 macOS** 上作为 Ansible 控制节点，向两台目标机部署 headless 版 `tailscaled` + `tailscale`：

| 节点 | 地址 | 角色 | 平台 | 二进制产物 | 守护方式 |
| --- | --- | --- | --- | --- | --- |
| mac-mini（本机） | localhost | **exit node**（出口网关） | darwin/arm64 | `dist/*-darwin-arm64` | 用户级 LaunchAgent（非 root，userspace-networking） |
| box-217（远端） | 10.9.202.217 (root) | **exit node client**（经 Mac 出网） | linux/amd64 | `dist/*-linux-amd64` | systemd (`tailscaled.service`) |

拓扑意图：217 的出网流量（含访问 GitHub）经 Tailscale 隧道送到 Mac，由 Mac 转发到公网。
Mac 即 Tailscale 出口节点（exit node），217 用 `--exit-node=mac-mini` 指向它。

## 前置条件

1. **控制节点 (Mac)**: ansible-core **≤2.18**——brew 装的 ansible (core 2.21+)
   要求目标机 python ≥3.9，而远端 box-217 是 Ubuntu 20.04 / python3.8，会报
   `Ansible requires Python 3.9 or newer on the target`。用仓库自带的 venv：

   ```sh
   # 首次创建（已提交在 .gitignore，不在仓库内）
   /opt/homebrew/bin/python3.13 -m venv .venv
   ./.venv/bin/pip install 'ansible-core>=2.18,<2.19'

   # 之后统一用 ./.venv/bin/ansible-playbook 代替 ansible-playbook
   ```

2. 远端 10.9.202.217 可免密 ssh（root），由 `~/.ssh` 现有配置提供。
3. 如 Mac 上装过 Tailscale GUI 客户端，**先退出它**，避免抢占 UDP 41641 / utun。

## 使用

以下命令都在 `ansible/` 目录下执行（Mac 非 root 部署，无需 `-K`）：

### 分阶段部署（推荐）

```sh
# 阶段 1: 构建并安装二进制 + 启动 daemon（不涉及登录/配置，最快）
./.venv/bin/ansible-playbook playbooks/deploy.yml --tags build,install

# 阶段 2: 检测内网网段 + 配置 exit node + lan-access（需先完成登录）
./.venv/bin/ansible-playbook playbooks/deploy.yml --tags detect,up,lan

# 阶段 3: 验证连通性（tailscale status + 内网 ping + 外网 curl）
./.venv/bin/ansible-playbook playbooks/deploy.yml --tags verify
# 或用专门的验证 playbook
./.venv/bin/ansible-playbook playbooks/verify.yml
```

### 全量一键

```sh
# 全量部署（build → install → detect → up → lan → verify）
./.venv/bin/ansible-playbook playbooks/deploy.yml

# 带 auth key 自动注册（无需手动浏览器认证）
./.venv/bin/ansible-playbook playbooks/deploy.yml -e ts_authkey=tskey-auth-xxxxxxxx
```

### Tag 说明

| Tag | 阶段 | 说明 |
|---|---|---|
| `build` | 1a | 交叉编译 darwin/arm64 + linux/amd64 二进制 |
| `install` | 1b | 分发二进制 + 生成配置 + 启动 daemon |
| `detect` | 2 | 检测远程节点物理网卡私有 IP → 填充 ts_ignore_routes |
| `up` | 3 | tailscale up（Mac 广播 exit node，客户端指向 Mac）|
| `lan` | 3 | 配置 ip rule 5260 绕过 table 52（内网双向可达）|
| `verify` | 4 | 验证：tailscale status + 内网 ping + 外网 curl |

### 出口节点（exit node）注意事项

- **Mac 侧无需 sudo**：二进制装 `/opt/homebrew/bin`（brew 用户可写），状态/socket 放
  `~/.tailscale/`，tailscaled 用 `--tun=userspace-networking` 跑成用户级 LaunchAgent
  （`~/Library/LaunchAgents`）。出口转发走 netstack 用户态并自带 NAT，仍支持 exit node。
  因此 **`ansible-playbook` 不再需要 `-K`**（远端是 root 直连，也不需要）。
- **Mac 侧无需手动 sysctl / pf**：userspace-networking 在用户态完成转发与 NAT。
- **exit node 必须在管理后台一次性审批**：Tailscale 没有为 exit node 提供 ACL
  授权属性（源码确认仅有 `funnel`/`ssh-aggregator` 等），所以 Mac `up --advertise-exit-node`
  后，需到 [管理后台](https://login.tailscale.com/admin/machines) → mac-mini →
  *Edit route settings* → 勾选 *Use as exit node* → Save。217 的 `--exit-node=mac-mini`
  在审批完成前会失败，playbook 会打印提示；审批后重跑 `--tags up` 即可。
- **路由全部流量**：`--exit-node` 会把 217 的全部出网流量经 Mac 转发（含 GitHub）。
  若只想放行 GitHub 而保留其余直连，Tailscale 原生不支持按域名分流出口；可改为在 Mac
  上用子网路由 + 217 侧 `--accept-routes`，但 GitHub IP 段多变，不推荐。测试场景用
  exit node 最简单。
- 若 Mac 上装过 Tailscale GUI 客户端，**先退出它**，避免抢占 UDP 41641 / utun。

常用子集：

```sh
./.venv/bin/ansible-playbook playbooks/deploy.yml --limit local  --tags deploy,verify  # 只部署本机
./.venv/bin/ansible-playbook playbooks/deploy.yml -e ts_authkey=... --tags up          # 只执行 tailscale up
```

## 路由忽略（fork 原生：--ignore-routes）

**首选方案（CIDR 级）**。本仓库 fork 给 tailscale 增加了 `--ignore-routes` 参数（上游官方版没有）：
指定网段永远不走 Tailscale 隧道，始终用主机自身路由直连，即使在用 exit node。

### 自动检测（推荐）

`deploy.yml` 的 `detect` 阶段会自动扫描远程节点的**物理网卡** IP，
映射到 RFC1918 三大私有网段，无需手动维护 `ts_ignore_routes`：

```
物理网卡 enp1s0: 10.9.202.217/24  →  自动推导 10.0.0.0/8
物理网卡 eth1:   192.168.1.100/24 →  自动推导 192.168.0.0/16
```

排除的虚拟接口：`lo`, `tailscale*`, `cilium*`, `kube-ipvs*`, `lxc*`, `docker*`,
`br-*`, `veth*`, `virbr*`, `vnet*`, `tun*`, `tap*`, `flannel*`, `cni*`, `cali*` 等。

### 手动指定（覆盖自动检测）

在 `inventory/host_vars/<主机>.yml` 设置 `ts_ignore_routes` 即可覆盖自动检测：

```yaml
# 只忽略精确子网，不忽略整个 10/8
ts_ignore_routes:
  - 10.9.202.0/24
  - 172.16.0.0/12
```

### 原理

随 `deploy.yml --tags up` 自动下发（首次 up 带参数，后续变更用 `tailscale set --ignore-routes=...` 幂等更新，无需重新登录）。

**原理**（fork 源码实现，见 `net/routemanager`）：
- 被 CIDR 覆盖的 accept-routes 子网路由直接不安装
- exit node 的 `0.0.0.0/0` 不再整体下发，改为拆成“补集路由”写入 table 52；
  被忽略网段在 table 52 无匹配 → 落回 main 表 → 物理网关直连
- tailnet 自身地址（100.64/10）不受影响

## 内网双向可达（lan-access）

**`--ignore-routes` 的不足与补充**。调试中发现：`--ignore-routes` 只处理**出方向**路由
（让发往内网的包走 main 表），但**入方向回包**仍会命中 `ip rule` 第 5270 条
`from all lookup 52` → 查 table 52 → 命中 `throw <本机网段>` 或 `default dev tailscale0`
→ 丢弃或走隧道 → **内网不可达**（外部客户端连不上本机物理 IP）。

`deploy.yml --tags up` 在 `tailscale up` 后自动运行 lan-access 步骤：

1. 写入 `/etc/tailscale/lan-routes.conf`（与 `ts_ignore_routes` 同一份 CIDR 列表）
2. 安装 `/usr/local/sbin/tailscale-lan-rules.sh` + `tailscale-lan-rules.service`
3. 在 `ip rule` priority **5260**（< Tailscale 5270）插入 `to <CIDR> lookup main` 规则
   → 内核在 Tailscale 规则之前命中 main 表 → 内网流量双向直连

```sh
# 单独运行（不重新 up，只刷新 ip rule）
./.venv/bin/ansible-playbook playbooks/lan-access.yml

# 验证内网可达
./.venv/bin/ansible-playbook playbooks/verify.yml           # 含内网网关 ping 测试
```

优先级关系：`force-tunnel(5050) < bypass(5100) < lan-access(5260) < tailscale(5270)`

幂等：shell 脚本用 grep 跳过已存在的规则；CIDR 列表变化时更新 conf 后重启 service。
持久化：`tailscale-lan-rules.service` 在 `tailscaled.service` 之后启动，重启自动恢复 ip rule。

## 直连白名单（bypass.yml）

**按域名补充方案（/32 级）**：适合没有固定网段、只能给域名的少量主机。
若目标 IP 已落在 `ts_ignore_routes` 网段内，则无需再配这里。

指定主机的流量不走 exit node 隧道，直接从 217 本机出网。适合需要直连的内部网关、
仓库等（如 `ssh.gate.yicloud.com.cn`）。

```sh
# 1. 编辑白名单列表
$EDITOR playbooks/group_vars/all.yml   # 修改 ts_bypass_hosts

# 2. 应用（在 tailscale up --exit-node 之后运行）
./.venv/bin/ansible-playbook playbooks/bypass.yml

# 临时覆盖（不改文件）
./.venv/bin/ansible-playbook playbooks/bypass.yml -e '{"ts_bypass_hosts":["ssh.gate.yicloud.com.cn","github.com"]}'
```

**原理**（Tailscale Linux 路由架构，源码 `wgengine/router/osrouter/router_linux.go` 确认）:
- Tailscale `ipPolicyPrefBase=5200`，实际 ip rule 优先级：5210/5230/5250（fwmark 出口）
  + **5270**（from all → table 52），exit node 流量在 table 52 走 `tailscale0`
- bypass 在 main 表加 `<IP>/32 via <物理网关>` + `ip rule` 优先级 5100（< 5270）→ `to <IP> lookup main`
- 内核在 Tailscale 规则(5270) 之前命中 5100 → main 表 /32 → 直连

幂等：`/etc/tailscale-bypass.conf` 追踪已管理 IP，列表变更时自动清理过期条目。

## 强制走隧道白名单（force-tunnel.yml）

**与 bypass.yml 对称**：让指定域名的流量**强制经 Tailscale 隧道**（exit node）传输，
即使该域名解析的 IP 落在 `ts_ignore_routes` 网段内（默认直连不走隧道），
或之前被 bypass.yml 加入了直连白名单。

公网 IP（如 `www.google.com`）不在 ignore-routes 网段内时，默认已走 exit node，
配置 force-tunnel 可确保即使未来 ignore-routes/bypass 变更也不受影响。

```sh
# 1. 编辑白名单列表
$EDITOR playbooks/group_vars/all.yml   # 修改 ts_force_tunnel_hosts

# 2. 应用（在 tailscale up --exit-node 之后运行）
./.venv/bin/ansible-playbook playbooks/force-tunnel.yml

# 临时覆盖（不改文件）
./.venv/bin/ansible-playbook playbooks/force-tunnel.yml -e '{"ts_force_tunnel_hosts":["www.google.com","github.com"]}'
```

**原理**（与 bypass 对称，优先级更高）:
- `ip rule` 优先级 **5050**（< bypass 5100 < tailscale 5270）→ `to <IP> lookup 52`
- 对 ignore-routes 网段内的 IP，在 table 52 补 `<IP>/32 dev tailscale0` 路由
  （公网 IP 已被 table 52 的 `0.0.0.0/1 + 128.0.0.0/1` 覆盖，无需补）
- 内核在 bypass(5100) 和 tailscale(5270) 之前命中 5050 → 查 table 52 → 走 `tailscale0`

优先级关系：`force-tunnel(5050) < bypass(5100) < tailscale(5270)`，三者互不冲突。

幂等：`/etc/tailscale-force-tunnel.conf` 追踪已管理 IP，列表变更时自动清理过期条目。
注意：tailscaled 重启会重建 table 52，手动补的 /32 路由会丢失，需重跑此 playbook。

## 透传本地代理给 tailscale exit node（fork 功能：TS_FORWARD_PROXY）

**问题背景**：Mac 作为 exit node（userspace-networking 模式），netstack 转发流量用标准 `net.Dialer` 直接连目标地址（源码 `wgengine/netstack/netstack.go` 的 `forwardTCP`），不走本地代理。因此当 Mac 本身无法直连目标（如 GFW 拦截 google.com）时，217 经 Mac 访问也会失败。

**解决方案**：fork 给 netstack 增加了 `TS_FORWARD_PROXY` 环境变量，让 exit node 的 TCP 转发走指定的本地代理（如 Clash Verge）。

```yaml
# playbooks/group_vars/all.yml
# 支持 socks5:// 和 http:// 两种协议
# Clash Verge 默认 mixed-port=7890（同时支持 HTTP 和 SOCKS5）
ts_forward_proxy: "socks5://127.0.0.1:7890"
```

```sh
# 1. 确保 Clash Verge 已启动且代理可用
#    验证：curl --socks5 127.0.0.1:7890 https://www.google.com

# 2. 重新部署（重启 tailscaled 使环境变量生效）
./.venv/bin/ansible-playbook playbooks/deploy.yml --tags deploy --limit local

# 3. 验证：217 经 Mac exit node -> Clash Verge 访问 google
ssh root@10.9.202.217 'curl -sS -o /dev/null -w "HTTP %{http_code}\n" https://www.google.com'
```

**原理**（fork 源码 `wgengine/netstack/forwardproxy.go`）:
- `netstack.Create` 时读 `TS_FORWARD_PROXY` 环境变量，构造代理 dialer
- `forwardTCP` 优先用代理 dialer（socks5/http CONNECT），其次 `forwardDialFunc`（测试用），最后默认 `net.Dialer`
- socks5 用 `golang.org/x/net/proxy`（和 `net/netns/socks.go` 同一依赖），http 用手写 CONNECT 隧道
- 环境变量留空则不启用（默认行为不变）

**限制**：
- 仅支持 TCP 转发（exit node 的 TCP 流量），UDP 转发暂不走代理（`forwardUDP` 用 `net.ListenUDP`）
- 仅对 exit node（Mac）生效，客户端无需配置
- 改变代理地址需重启 tailscaled（launchd 重载 plist 生效）

## 重置节点（清空状态、重新开始）

`reset.yml` 停止 daemon → 删除 state/socket → 重启为全新未登录节点。
适合测试中途换 auth key、状态变脏、或想从头来过：

```sh
./.venv/bin/ansible-playbook playbooks/reset.yml                # 重置两机
./.venv/bin/ansible-playbook playbooks/reset.yml --limit local   # 仅 Mac

# 重置后重新 up：
./.venv/bin/ansible-playbook playbooks/deploy.yml -e ts_authkey=tskey-auth-xxx --tags up
```

重置只清本地身份/密钥状态，不删除二进制；旧节点在管理后台显示 offline，可手动删或等过期。

## 控制面管理：ACL 策略 + 用户增删（playbooks/control.yml）

ACL 和 tailnet 用户都托管在协调服务器（api.tailscale.com），不通过节点管理；
本 playbook 仅在本机调用 Tailnet API v2。

```sh
# 1. 在 tailnet 控制台 Settings > Keys 生成 API access token
export TS_API_KEY=tskey-api-xxxxxxxx

# 2. 编辑策略文件（严格 JSON，用于幂等对比）
$EDITOR playbooks/acl/acl.json

# 3. 对比 + 校验 + 推送 ACL；增删用户
./.venv/bin/ansible-playbook playbooks/control.yml               # ACL + 用户
./.venv/bin/ansible-playbook playbooks/control.yml --tags acl    # 仅 ACL
./.venv/bin/ansible-playbook playbooks/control.yml --tags users  # 仅用户
```

行为保证：
- **ACL 幂等**：GET 远端与本地文件按 JSON 语义对比，一致则跳过；有差异先 `POST .../acl/validate`
  服务端校验，再 `PUT`（携带 `If-Match` ETag 防止并发覆盖）。
- **用户幂等**：`ts_users` 中已存在的邮箱跳过创建，缺失的 POST 创建（发送邀请）；
  `ts_users_absent` 中的邮箱按 loginName 找到 id 后 DELETE，不存在则提示跳过。
- **密钥不落盘**：只从环境变量 `TS_API_KEY` 读取；未设置时整个 playbook 优雅跳过，
  可安全地在没有 API 凭据的机器上执行。

用户管理示例（写在 `playbooks/group_vars/all.yml` 或用 `-e @file.yml` 覆盖）:

```yaml
ts_users:
  - email: alice@example.com
    role: member
ts_users_absent:
  - bob@example.com
```

## 已验证的行为

- 远端 box-217：`systemd tailscaled` 运行中，`tailscale --socket=... status` 返回
  `Logged out.`（表示 CLI↔daemon socket 连通了，仅差登录）。
- control.yml（控制面）：已用本地 mock API（`tests/mock_tailscale_api.py`）完整跑通
  ACL 对比/校验/推送、用户创建/去重/删除、二次运行幂等跳过。复现方式：

  ```sh
  nohup /opt/homebrew/bin/python3.13 tests/mock_tailscale_api.py &
  ./.venv/bin/ansible-playbook playbooks/control.yml -e @tests/mock-vars.yml
  ```
- 两机各自 `tailscale up`（auth key 或浏览器登录 URL）之后，`verify.yml` 的
  ping 步骤即为绿色；不 up 则 ping 段提示失败属正常。

## 手工排错入口

```sh
tailscale --socket=/var/run/tailscale/tailscaled.sock status
tailscale --socket=/var/run/tailscale/tailscaled.sock up        # 打印登录 URL 时浏览器打开
tailscale --socket=/var/run/tailscale/tailscaled.sock ip -4
```

- Mac 守护: `sudo launchctl print system/com.tailscale.tailscaled`、日志 `/var/log/tailscaled.{out,err}.log`
- Linux 守护: `journalctl -u tailscaled -f`
- 连通原理: CLI 与 daemon 必须使用同一个 `--socket`，共享配置在 `/etc/default/tailscaled`

## 目录

```
ansible/
├── ansible.cfg                       # 免 host key 确认、静默 python 探测
├── .venv/                            # ansible-core 2.18（远端 python3.8 兼容）
├── inventory/hosts.ini               # mac-mini(local) + box-217(10.9.202.217)
├── playbooks/
│   ├── group_vars/all.yml            # socket/statedir/端口/authkey/API 凭据等变量
│   ├── acl/acl.json                  # tailnet ACL 策略文件（严格 JSON）
│   ├── templates/
│   │   ├── tailscaled.env.j2         # /etc/default/tailscaled
│   │   ├── tailscaled.service.j2     # linux systemd 单元
│   │   ├── com.tailscale.tailscaled.plist.j2  # mac launchd daemon
│   │   ├── tailscale-lan-rules.sh.j2        # 内网绕过 table 52 脚本
│   │   ├── tailscale-lan-rules.service.j2   # 内网规则 systemd service
│   │   └── detect-lan-cidrs.sh.j2           # 内网网段自动检测脚本
│   ├── deploy.yml                    # build -> deploy -> up -> lan-access -> verify
│   ├── verify.yml                    # status + 互 ping + 217 经 Mac 访问 + 内网可达
│   ├── lan-access.yml                # 内网双向可达（ip rule 5260 绕过 table 52）
│   ├── reset.yml                     # 清空节点状态，重启为全新未登录节点
│   ├── bypass.yml                    # 直连白名单（绕过 exit node）
│   ├── force-tunnel.yml              # 强制走隧道白名单（与 bypass 对称）
│   └── control.yml                   # 控制面：ACL 推送 + 用户增删
├── tests/
│   ├── mock_tailscale_api.py         # 本地 mock Tailscale API（离线验证 control.yml）
│   └── mock-vars.yml                 # mock 测试用变量覆盖
└── README.md
```
