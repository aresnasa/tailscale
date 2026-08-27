#!/usr/bin/env bash
# 两阶段交互式部署:
#
#   Phase 1: 构建 + 安装 + 启动 daemon + tailscale up（用 TS_AUTHKEY 注册）
#   Phase 2: discover 查询 Mac tailnet IP → 回填 inventory → 重跑 up/lan/dns/verify
#
# 用法:
#   TS_AUTHKEY=tskey-auth-xxx MAC_SUDO=xxx ./scripts/deploy-interactive.sh
#   ./scripts/deploy-interactive.sh        # 会依次提示输入 authkey 和 Mac sudo 密码
set -euo pipefail

cd "$(dirname "$0")/.."
ANSIBLE=./.venv/bin/ansible-playbook
PLAYBOOK=playbooks/deploy.yml

echo "════════════════════════════════════════════════════════"
echo "  Tailscale 两阶段交互式部署"
echo "════════════════════════════════════════════════════════"

# ---- 1. 获取 Tailscale authkey ----
TS_AUTHKEY="${TS_AUTHKEY:-}"
if [[ -z "$TS_AUTHKEY" ]]; then
  read -rsp "输入 ts_authkey（tskey-auth-...，留空则稍后手动浏览器登录）: " TS_AUTHKEY
  echo
fi

# ---- 2. 获取本机 Mac sudo 密码 ----
# Mac (mac-mini) 是本机 ansible_connection=local，若需要 become 提权
# （如安装系统级目录、刷新 sudo 缓存），通过 ansible_become_password 透传。
# box-217 以 root 直连 SSH，不会用到此密码。
MAC_SUDO="${MAC_SUDO:-}"
if [[ -z "$MAC_SUDO" ]]; then
  read -rsp "输入本机 Mac sudo 密码（不回显）: " MAC_SUDO
  echo
fi

# 提前校验 sudo 密码，避免部署到一半才失败
if ! printf '%s\n' "$MAC_SUDO" | sudo -S -k -v 2>/dev/null; then
  echo "✗ Mac sudo 密码校验失败，请重试" >&2
  exit 1
fi
echo "✓ Mac sudo 密码校验通过"

# ---- 组装 ansible 公共参数 ----
EXTRA_ARGS=(-e ts_interactive=true)
[[ -n "$TS_AUTHKEY" ]] && EXTRA_ARGS+=(-e "ts_authkey=${TS_AUTHKEY}")
# 注意: 密码经 -e 传入会出现在本机 ansible-playbook 进程 argv 中；
# mac-mini 与本机同机(box-217 为 root 直连)，风险面可控。
EXTRA_ARGS+=(-e "ansible_become_password=${MAC_SUDO}")

echo
echo "════════ Phase 1: build + install + detect + up ════════"
"$ANSIBLE" "$PLAYBOOK" --tags build,install,detect,up "${EXTRA_ARGS[@]}"

echo
echo "─────────────────────────────────────────────────────────"
echo " Phase 1 完成。请确认："
echo "   1) Mac (exit node) 已上线（上面日志会打印 tailnet IP）"
echo "   2) 已在管理后台批准 Mac 作为 exit node:"
echo "      https://login.tailscale.com/admin/machines"
echo "      → 找到 mac-mini → ⋯ → Edit route settings → 勾选 'Use as exit node' → Save"
echo "─────────────────────────────────────────────────────────"
read -rp "已确认？(Y/n) " ok
case "$ok" in
  n|N) echo "已中止。待 Mac 审批完后重跑本脚本即可。"; exit 0 ;;
esac

echo
echo "════════ Phase 2: discover + up + lan + dns + verify ════════"
"$ANSIBLE" "$PLAYBOOK" --tags discover,up,lan,dns,verify "${EXTRA_ARGS[@]}"

echo
echo "════════════════════════════════════════════════════════"
echo " 部署完成。连通性复核可随时再跑："
echo "   ./.venv/bin/ansible-playbook playbooks/verify.yml"
echo "════════════════════════════════════════════════════════"
