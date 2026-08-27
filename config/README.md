# Tailscale 部署样例配置（由 make config 生成）

本目录供部署 linux/amd64 使用（二进制在 dist/ 目录）。文件说明:

- tailscaled.env     tailscaled 与 CLI 的共享配置（连通核心: TS_SOCKET 必须一致）
- tailscaled.service systemd 服务样例（参考上游 cmd/tailscaled/tailscaled.service）
- run-tailscaled.sh  无 systemd 时手动运行 tailscaled
- tailscale.sh       tailscale CLI 包装，自动携带 --socket 参数
- README.md          本说明

## Linux 部署步骤（root，目标机）

1. 复制二进制并按平台改名:
   scp dist/tailscale-linux-amd64  root@HOST:/usr/local/bin/tailscale
   scp dist/tailscaled-linux-amd64 root@HOST:/usr/local/bin/tailscaled
2. 复制配置:
   scp config/tailscaled.env      root@HOST:/etc/default/tailscaled
   scp config/tailscaled.service  root@HOST:/etc/systemd/system/tailscaled.service
3. 启动并登录:
   systemctl daemon-reload && systemctl enable --now tailscaled
   tailscale up --authkey=tskey-xxx --hostname=HOSTNAME

也可用本目录脚本代替第 3 步的 CLI 部分: ./tailscale.sh up --authkey=tskey-xxx

## 连通原理（tailscale 如何找到 tailscaled）

- tailscale CLI 通过 unix socket 与本机 tailscaled 通信;
  两者必须使用同一路径（tailscaled --socket 与 tailscale --socket）。
- tailscaled 需要对 statedir 有写权限; systemd 单元已用 StateDirectory 托管。
- WireGuard 流量走 UDP，注意防火墙放行 TS_PORT（默认 41641/udp）。

## 无 root 本地测试（如容器/开发机）

./run-tailscaled.sh --tun=userspace-networking   # 免 TUN 权限运行 daemon
./tailscale.sh status                             # 验证 CLI 与 daemon 连通

## 重新生成（路径可覆盖）

make config TS_SOCKET=/tmp/t.sock TS_STATE_DIR=/tmp/state CONF_DIR=/tmp/conf

