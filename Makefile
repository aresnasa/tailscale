# Makefile —— 通过 ./build_dist.sh 交叉编译 Tailscale 二进制（tailscale + tailscaled）
# 并生成样例部署配置，保证 tailscaled 与 tailscale CLI 正确连通
# 产物统一输出到 $(BIN_DIR)/（默认 .bin/），命名: <bin>-<os>-<arch>[.exe]

.DEFAULT_GOAL := build

GOOS   ?= linux
GOARCH ?= amd64

# 交叉编译统一禁用 cgo，无需安装交叉 C 工具链
CGO_ENABLED ?= 0

PKGS    ?= tailscale.com/cmd/tailscale tailscale.com/cmd/tailscaled
BIN_DIR ?= .bin

# ---- 样例配置相关（make config）----
CONF_DIR       ?= config
TS_STATE_DIR   ?= /var/lib/tailscale
TS_SOCKET      ?= /var/run/tailscale/tailscaled.sock
TS_PORT        ?= 41641
TS_INSTALL_DIR ?= /usr/local/bin

# 平台矩阵：linux/amd64 为主要目标，其余按需增删
PLATFORMS := linux/amd64 linux/arm64 linux/arm \
             darwin/amd64 darwin/arm64 \
             windows/amd64

ifeq ($(GOOS),windows)
EXT := .exe
else
EXT :=
endif

.PHONY: all build list clean help config config-dir

all: $(foreach p,$(PLATFORMS),build-$(subst /,-,$(p))) ## 构建全部平台矩阵（建议 make all -j 并行）

# 构建 $(GOOS)/$(GOARCH)（默认 linux/amd64）上 PKGS 列表中的所有二进制
build: ## 构建 $(GOOS)/$(GOARCH)（默认 linux/amd64）的 tailscale + tailscaled
	@mkdir -p $(BIN_DIR)
	@set -e; for pkg in $(PKGS); do \
		bin=$$(basename $$pkg); \
		GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=$(CGO_ENABLED) \
			./build_dist.sh -o $(BIN_DIR)/$$bin-$(GOOS)-$(GOARCH)$(EXT) $$pkg; \
		echo "==> $(BIN_DIR)/$$bin-$(GOOS)-$(GOARCH)$(EXT)"; \
	done

build-%: ## 构建指定平台，如 make build-linux-arm64（平台见 make list）
	@$(MAKE) --no-print-directory build \
		GOOS=$(word 1,$(subst -, ,$*)) GOARCH=$(word 2,$(subst -, ,$*))

list: ## 列出平台矩阵与构建的包
	@echo "平台矩阵:"
	@for p in $(PLATFORMS); do echo "  $$p"; done
	@echo "构建的包（PKGS）:"
	@for pkg in $(PKGS); do echo "  $$pkg"; done

clean: ## 删除产物目录 $(BIN_DIR)/
	rm -rf $(BIN_DIR)

# ---- 样例配置模板 ----
# 说明: 模板中的 $$ 转义为生成文件内的 $（运行期变量展开）

define config_env
# Tailscale 部署配置 —— tailscaled 与 tailscale CLI 共享
# 连通关键: 两个进程必须使用同一个 TS_SOCKET 与 TS_STATE_DIR
TS_STATE_DIR=$(TS_STATE_DIR)
TS_SOCKET=$(TS_SOCKET)
TS_PORT=$(TS_PORT)
# 追加给 tailscaled 的额外参数（tailscaled.service 的 ExecStart 会展开 $$FLAGS）
FLAGS=
endef

define config_service
[Unit]
Description=Tailscale node agent
Documentation=https://tailscale.com/docs/
Wants=network-pre.target
After=network-pre.target NetworkManager.service systemd-resolved.service

[Service]
EnvironmentFile=/etc/default/tailscaled
ExecStart=$(TS_INSTALL_DIR)/tailscaled --statedir=$${TS_STATE_DIR} --socket=$${TS_SOCKET} --port=$${TS_PORT} $$FLAGS
ExecStopPost=$(TS_INSTALL_DIR)/tailscaled --cleanup --statedir=$${TS_STATE_DIR}
Restart=on-failure
RuntimeDirectory=tailscale
RuntimeDirectoryMode=0755
StateDirectory=tailscale
StateDirectoryMode=0700
CacheDirectory=tailscale
CacheDirectoryMode=0750
Type=notify

[Install]
WantedBy=multi-user.target
endef

define config_run_sh
#!/bin/sh
# 手动运行 tailscaled（生产环境建议 systemd，见 tailscaled.service）
# 需要 root（TUN 权限）; 无 root 测试可追加: --tun=userspace-networking
set -eu
CONF_DIR=$$(cd "$$(dirname "$$0")" && pwd)
. "$$CONF_DIR/tailscaled.env"
mkdir -p "$$TS_STATE_DIR"
exec tailscaled \
	--statedir="$$TS_STATE_DIR" \
	--socket="$$TS_SOCKET" \
	--port="$$TS_PORT" \
	"$$@"
endef

define config_cli_sh
#!/bin/sh
# tailscale CLI 包装: 自动使用与 tailscaled 相同的 socket，保证连通
# 用法: ./tailscale.sh status | up --authkey=tskey-xxx | netcheck | ...
set -eu
CONF_DIR=$$(cd "$$(dirname "$$0")" && pwd)
. "$$CONF_DIR/tailscaled.env"
exec tailscale --socket="$$TS_SOCKET" "$$@"
endef

define config_readme
# Tailscale 部署样例配置（由 make config 生成）

本目录供部署 linux/amd64 使用（二进制在 .bin/ 目录）。文件说明:

- tailscaled.env     tailscaled 与 CLI 的共享配置（连通核心: TS_SOCKET 必须一致）
- tailscaled.service systemd 服务样例（参考上游 cmd/tailscaled/tailscaled.service）
- run-tailscaled.sh  无 systemd 时手动运行 tailscaled
- tailscale.sh       tailscale CLI 包装，自动携带 --socket 参数
- README.md          本说明

## Linux 部署步骤（root，目标机）

1. 复制二进制并按平台改名:
   scp .bin/tailscale-linux-amd64  root@HOST:$(TS_INSTALL_DIR)/tailscale
   scp .bin/tailscaled-linux-amd64 root@HOST:$(TS_INSTALL_DIR)/tailscaled
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
endef

config-dir:
	@mkdir -p $(CONF_DIR)

config: | config-dir ## 生成样例部署配置到 $(CONF_DIR)/（env + systemd + 连通脚本 + README）
	@$(file >$(CONF_DIR)/tailscaled.env,$(config_env))
	@printf '\n' >> $(CONF_DIR)/tailscaled.env
	@$(file >$(CONF_DIR)/tailscaled.service,$(config_service))
	@printf '\n' >> $(CONF_DIR)/tailscaled.service
	@$(file >$(CONF_DIR)/run-tailscaled.sh,$(config_run_sh))
	@printf '\n' >> $(CONF_DIR)/run-tailscaled.sh
	@$(file >$(CONF_DIR)/tailscale.sh,$(config_cli_sh))
	@printf '\n' >> $(CONF_DIR)/tailscale.sh
	@$(file >$(CONF_DIR)/README.md,$(config_readme))
	@printf '\n' >> $(CONF_DIR)/README.md
	@chmod +x $(CONF_DIR)/run-tailscaled.sh $(CONF_DIR)/tailscale.sh
	@echo "==> $(CONF_DIR)/: tailscaled.env tailscaled.service run-tailscaled.sh tailscale.sh README.md"
	@echo "    部署说明见 $(CONF_DIR)/README.md"

help: ## 显示此帮助
	@echo "Tailscale 交叉编译（产物: $(BIN_DIR)/<bin>-<os>-<arch>）"
	@echo
	@echo "常用目标:"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_%-]+:.*##/ {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "构建 linux/amd64（主要目标）:"
	@echo "  make          # 即 make build: 构建 linux/amd64 的 tailscale + tailscaled → $(BIN_DIR)/"
	@echo
	@echo "其他示例:"
	@echo "  make config                            # 生成样例配置（tailscaled/CLI 连通所需）→ $(CONF_DIR)/"
	@echo "  make config TS_SOCKET=/tmp/t.sock TS_STATE_DIR=/tmp/state  # 自定义路径"
	@echo "  make build-linux-arm64                # 单独构建某平台（平台见 make list）"
	@echo "  make build GOOS=windows GOARCH=amd64  # 任意指定平台"
	@echo "  make all -j                           # 并行构建全部平台矩阵"
	@echo
	@echo "可覆盖变量: GOOS GOARCH PKGS PLATFORMS BIN_DIR"
	@echo "配置变量:   CONF_DIR TS_STATE_DIR TS_SOCKET TS_PORT TS_INSTALL_DIR"
