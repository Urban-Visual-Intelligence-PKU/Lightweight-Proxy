# Kato

在 Linux 上运行 AnyTLS 代理，无需 root 权限。启动脚本需要 Python 3 和 PyYAML。

## 配置

在仓库根目录复制 `config/template.yaml`，将副本重命名为 `<姓名>.yaml`，并按文件中的注释填写。

```bash
(umask 077 && cp config/template.yaml "config/<姓名>.yaml")
```

把命令里的 `<姓名>` 替换成自己的姓名拼音。文件名支持英文字母、数字、下划线和连字符。个人配置文件由 Git 忽略。

## 启动

```bash
./bin/kato.sh up --config "<姓名>"
source ./bin/kato-tmux.sh
```

`--config` 填写文件名去掉 `.yaml` 后的名称。启动成功后，终端会打印本地代理地址，例如 `127.0.0.1:7897`。修改配置后，重新执行启动命令。

在当前 shell 中关闭代理：

```bash
source ./bin/kato-tmux.sh off
```
