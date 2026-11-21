# Kato

在 Linux 上运行 AnyTLS 代理，无需 root 权限。

## 配置

在仓库目录下复制配置模板：

```bash
cp .env.example .env
chmod 600 .env
```

编辑 `.env`，填写服务商提供的 `ANYTLS_SERVER`（服务器地址）、`ANYTLS_PORT`（端口）和 `ANYTLS_PASSWORD`（密码）。如果服务商另有指定，填写 `ANYTLS_SNI`。

`.env` 已被 Git 忽略。请只在本机填写密码。

## 启动

```bash
./kato-anytls-up.sh
source ./kato-tmux.sh
```

修改配置后，重新运行 `./kato-anytls-up.sh`。每个需要使用代理的 shell 或 tmux 窗格都要执行 `source ./kato-tmux.sh`。在当前 shell 中取消代理：

```bash
source ./kato-tmux.sh off
```
