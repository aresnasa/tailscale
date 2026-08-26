# Ansible 自动部署 tailscaled/tailscale（两机联通测试）

在**本机 macOS** 上作为 Ansible 控制节点，向两台目标机部署 headless 版 `tailscaled` + `tailscale`：

| 节点 | 地址 | 角色 | 平台 | 二进制产物 | 守护方式 |
| --- | --- | --- | --- | --- | --- |
| mac-mini（本机） | localhost | **exit node**（出口网关） | darwin/arm64 | `dist/*-darwin-arm64` | launchd (`com.tailscale.tailscaled`) |
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

以下命令都在 `ansible/` 目录下执行，`-K` 会提示输入 Mac 本机 sudo 密码：

```sh
# 1. 全量：构建 -> 部署 -> up（Mac 先广播 exit node，217 再引用）-> 验证
./.venv/bin/ansible-playbook playbooks/deploy.yml -K

# 2. 带 auth key 一键 tailscale up（真正打通两机 + 出口路由）
./.venv/bin/ansible-playbook playbooks/deploy.yml -K -e ts_authkey=tskey-auth-xxxxxxxx

# 3. 随时验证两机状态 & mac -> box-217 ping
./.venv/bin/ansible-playbook playbooks/verify.yml
```

### 出口节点（exit node）注意事项

- **Mac 侧无需手动 sysctl / pf**：tailscaled-on-macOS 默认用 `utun` 且子网/出口转发走
  netstack 用户态并自带 NAT（源码 `cmd/tailscaled` 的 `handleSubnetsInNetstack`
  在 darwin 返回 true）。launchd plist 已以 root 运行，满足 `utun` 权限。
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
./.venv/bin/ansible-playbook playbooks/deploy.yml --limit remote --tags deploy,verify  # 只部署远端
./.venv/bin/ansible-playbook playbooks/deploy.yml -K --limit local  --tags deploy,verify  # 只部署本机
./.venv/bin/ansible-playbook playbooks/deploy.yml -K -e ts_authkey=... --tags up          # 只执行 tailscale up
```

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
│   │   └── com.tailscale.tailscaled.plist.j2  # mac launchd daemon
│   ├── deploy.yml                    # build -> deploy -> up -> verify
│   ├── verify.yml                    # status + 互 ping
│   └── control.yml                   # 控制面：ACL 推送 + 用户增删
├── tests/
│   ├── mock_tailscale_api.py         # 本地 mock Tailscale API（离线验证 control.yml）
│   └── mock-vars.yml                 # mock 测试用变量覆盖
└── README.md
```
