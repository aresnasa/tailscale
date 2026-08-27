#!/usr/bin/env bash
# 交互式验证：可选提示 Mac sudo 密码（供 become 场景），再跑 playbooks/verify.yml
#
# 用法:
#   ./scripts/verify-interactive.sh                                  # 逐项提示
#   MAC_SUDO=xxx ./scripts/verify-interactive.sh                     # 带 become 密码
#   TEST_URLS='["https://github.com","https://google.com"]' \
#       ./scripts/verify-interactive.sh                              # 覆盖默认测试 URL
set -euo pipefail

cd "$(dirname "$0")/.."
ANSIBLE=./.venv/bin/ansible-playbook
PLAYBOOK=playbooks/verify.yml

# ---- Mac sudo 密码（可选，仅若 Mac 上有 become:true 的任务才用）----
MAC_SUDO="${MAC_SUDO:-}"
if [[ -z "$MAC_SUDO" ]]; then
  read -rsp "输入本机 Mac sudo 密码（直接回车跳过，verify 默认不需要）: " MAC_SUDO
  echo
fi

EXTRA=()
if [[ -n "$MAC_SUDO" ]]; then
  if ! printf '%s\n' "$MAC_SUDO" | sudo -S -k -v 2>/dev/null; then
    echo "✗ Mac sudo 密码校验失败" >&2
    exit 1
  fi
  EXTRA+=(-e "ansible_become_password=${MAC_SUDO}")
fi

# ---- 可选：自定义测试 URL ----
[[ -n "${TEST_URLS:-}" ]] && EXTRA+=(-e "{\"test_urls\": ${TEST_URLS}}")

echo "════════ 运行 verify.yml ════════"
"$ANSIBLE" "$PLAYBOOK" "${EXTRA[@]}"
