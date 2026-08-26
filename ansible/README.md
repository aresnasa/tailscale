# Ansible 自动部署 tailscaled/tailscale（两机联通测试）

在**本机 macOS** 上作为 Ansible 控制节点，向两台目标机部署 headless 版 `tailscaled` + `tailscale`：

| 节点 | 地址 | 平台 | 二进制产物 | 守护方式 |
| --- | --- | --- | --- | --- |
| mac-mini（本机） | localhost | darwin/arm64 | `dist/*-darwin-arm64` | launchd (`com.tailscale.tailscaled`) |
| box-217（远端） | 10.9.202.217 (root) | linux/amd64 | `dist/*-linux-amd64` | systemd (`tailscaled.service`) |

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
# 1. 全量：构建 -> 部署 -> 验证（两机）
./.venv/bin/ansible-playbook playbooks/deploy.yml -K

# 2. 带 auth key 一键 tailscale up 加入 tailnet（真正打通两机互访）
./.venv/bin/ansible-playbook playbooks/deploy.yml -K -e ts_authkey=tskey-auth-xxxxxxxx

# 3. 随时验证两机状态 & mac -> box-217 ping
./.venv/bin/ansible-playbook playbooks/verify.yml
```

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
