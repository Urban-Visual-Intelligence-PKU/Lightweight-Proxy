# CLAUDE.md

给 Claude Code / 后续维护者的项目说明。

## 这是什么
在 **Linux 上无 root 安装并运行 Clash 代理** 的脚本。核心内核用
**mihomo（Clash.Meta）**——原版 `Dreamacro/clash` 已归档，mihomo 是维护中的兼容内核。
纯用户态 HTTP/SOCKS 代理：不装 systemd 服务、不开 TUN、不改 iptables，普通用户即可运行。

## 文件
- `bin/kato.sh` —— 内核安装、进程管理和订阅。子命令：`install / subscribe / start / stop / restart / status / env /
  proxies / nodes / select / test / diag / log / setup`。
- `bin/kato-anytls-up.sh` —— 读取 `config/<名称>.yaml`，生成 AnyTLS 配置并启动代理。
- `bin/kato-tmux.sh` —— 在当前 Bash 会话中启用或关闭代理。
- `config/template.yaml` —— 本地配置模板。
- `README.md` —— 面向使用者的说明。
- `.gitignore` —— 屏蔽运行时产物（内核二进制、`config.yaml`、日志、GeoIP 等）。

运行时数据默认在 `~/.local/share/clash/`（可用 `CLASH_HOME` 覆盖），**不在仓库目录内**。

## 关键约定（改代码时务必遵守）
- **订阅地址 `SUB_URL` 必须由环境变量传入，绝不写死在代码/仓库里**（它含私密令牌）。
  只有 `subscribe` / `setup` 需要它；未设置时 `cmd_subscribe` 会直接报错退出。
  同理，任何机场令牌、`config.yaml`、订阅返回内容都不要提交到仓库。
- 端口不要写死：从生成的 `config.yaml` 里用 `get_port` / `http_port` / `socks_port` / `api_base`
  读取。`subscribe` 会把端口改成 `HTTP_PORT/SOCKS_PORT/CTRL_PORT`（默认 7897/7898/9097），
  且用 `pick_port` 自动避开被占端口——**因为目标机常已有另一个 clash 占用 7890/9090**，
  端口冲突会导致 API 打到别的实例、返回 `Unauthorized`。控制面板端口用 `api_base`（读配置），
  切勿再硬编码 9090。排查用 `cmd_diag`。
- `subscribe` 会做安全加固：把 `external-controller` 强制改成 `127.0.0.1:9090`，
  `allow-lan` 置 `false`。改动订阅处理逻辑时保留这些加固。
- 下载走 GitHub，直连失败自动回退 `GH_MIRRORS` 镜像；API 拿不到版本时用 `FALLBACK_VER`
  构造直链。升级默认版本时改 `FALLBACK_VER`。
- 保持无 root：不要引入需要 root 的特性（TUN、透明代理、systemd、iptables）。
- 选节点走控制面板 REST API（`proxies/nodes/select/test` 子命令）：所有代理组都是
  `select` 手动类型，主组 `🔰国外流量`。JSON 用 grep/sed/awk 解析，**不依赖 jq/python**；
  组名（含 emoji/中文但无空格）直接放 URL 路径，节点名（含空格）放 PUT 的 JSON body，
  以此避开 URL 编码。`select` 支持按序号或按节点名。改这块时保持无外部依赖。

## 环境变量
| 变量 | 说明 |
|------|------|
| `SUB_URL` | **必填**，订阅地址（含令牌，环境变量传入） |
| `CLASH_HOME` | 运行目录，默认 `~/.local/share/clash` |
| `SUB_UA` | 拉订阅的 UA，默认 `clash-verge/v1.6.0`（需含 clash 关键字才返回 yaml） |
| `GH_MIRRORS` | GitHub 下载镜像前缀（空格分隔） |
| `NO_MIRROR=1` | 只走直连 |

## 改完怎么验证（本机可能无法真正跑 clash）
- `for script in bin/*.sh; do bash -n "$script"; done` 语法检查。
- 端口解析：造一个含 `port:`/`socks-port:` 的 `config.yaml`，`CLASH_HOME=... ./bin/kato.sh env` 看输出。
- 内核 URL 解析：`resolve_core_url` 应返回 `mihomo-linux-<arch>-...gz` 直链且可下载。
- 不要在"仅用于打包"的机器上真正 `install`/`start`。

## 仓库
私有仓库 `Norman-Ou/kato`（用 `gh`，账号 `Norman-Ou`，https + token 推送）。
