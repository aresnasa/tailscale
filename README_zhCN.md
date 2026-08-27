sudo tailscale up --reset --advertise-exit-node

./dist/tailscale-darwin-arm64  --socket=/Users/aresnasa/.tailscale/tailscaled.sock status

./.venv/bin/ansible-playbook playbooks/reset.yml

TS_AUTHKEY=tskey-auth-TzhyOeE6C8rpAA04VkEnGTM8LpwTmTpk1XUIUpoR0g93vfd7Ih3xedzVotLeD47O  ./.venv/bin/ansible-playbook playbooks/deploy.yml -e ts_authkey=$TS_AUTHKEY
