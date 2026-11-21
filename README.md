# Kato

在 Linux 上运行 AnyTLS 代理，无需 root 权限。启动脚本需要 Python 3 和 PyYAML。

## 配置

在仓库根目录复制模板，任选一个配置名：

```bash
(umask 077 && cp config/template.yaml config/ruizhe.yaml)
```

编辑 `config/ruizhe.yaml`，填写服务商提供的 `server`、`port` 和 `password`。密码请加引号。`proxy_port` 是本地 HTTP / SOCKS5 监听端口，默认是 `7897`。如有单独的 SNI，填写 `sni`。

个人配置文件已加入 Git 忽略规则。请将凭据填入个人配置。

## 启动

```bash
./bin/kato.sh up --config ruizhe
source ./bin/kato-tmux.sh
```

`--config` 填写文件名去掉 `.yaml` 后的名称。启动成功后，终端会打印本地代理地址，例如 `127.0.0.1:7897`。修改配置后，重新执行启动命令。

在当前 shell 中关闭代理：

```bash
source ./bin/kato-tmux.sh off
```
