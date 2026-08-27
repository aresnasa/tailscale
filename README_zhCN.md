1. 检查所有 playbook 我先在要尝试测试一次 tailscale，需要按照
2. 先部署（输出用户如何登录 tailscale），
3. 然后根据登录信息自动回填配置的逻辑，
4. 最终测试，这里避免用户输入太多配置，同时保证 tailscale 不要影响本地的 dns，只做添加动作不要调整系统配置，同时需要保证路由不被影响，
5. 这里由于本项目代码已经被改造过，还需要检查是否强需求改造这些代码
6. 将当前的 go 代码和v1.102.3进行比对，如果非必需可以将代码进行还原，避免代码修改过多和上游社区产生差异。



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
