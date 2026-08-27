sudo tailscale up --reset --advertise-exit-node

./dist/tailscale-darwin-arm64  --socket=/Users/aresnasa/.tailscale/tailscaled.sock status

./.venv/bin/ansible-playbook playbooks/reset.yml

TS_AUTHKEY=tskey-auth-TzhyOeE6C8rpAA04VkEnGTM8LpwTmTpk1XUIUpoR0g93vfd7Ih3xedzVotLeD47O  ./.venv/bin/ansible-playbook playbooks/deploy.yml -e ts_authkey=$TS_AUTHKEY

cd ansible

# 交互验证（可选 sudo / 自定义测试 URL）
./scripts/verify-interactive.sh

# 非交互
./.venv/bin/ansible-playbook playbooks/verify.yml

# 带自定义测试 URL
TEST_URLS='["https://github.com","https://www.google.com","https://youtube.com"]' \
  ./scripts/verify-interactive.sh
