#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ne 2 || "$1" != --config || ! "$2" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo '用法：kato.sh up --config <名称>（例如 ruizhe，不带 .yaml）' >&2
    exit 1
fi

PROFILE="$(dirname "$HERE")/config/$2.yaml"
if [[ ! -f "$PROFILE" ]]; then
    printf '找不到配置：%s\n' "$PROFILE" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' 2>/dev/null; then
    echo '请先安装 Python 3 和 PyYAML。' >&2
    exit 1
fi

export CLASH_HOME="${CLASH_HOME:-$HOME/.local/share/clash}"
umask 077
mkdir -p "$CLASH_HOME"
CONFIG="$CLASH_HOME/config.yaml"
TEMP_CONFIG="$(mktemp "$CLASH_HOME/.kato-config.XXXXXXXX")"
trap 'rm -f -- "$TEMP_CONFIG"' EXIT

PROXY_PORT="$(python3 - "$PROFILE" "$TEMP_CONFIG" <<'PY'
import sys
import yaml

def fail(message):
    sys.exit(message)

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        profile = yaml.safe_load(source)
except (OSError, UnicodeError, yaml.YAMLError):
    fail("无法读取 YAML 配置，请检查文件权限和格式。")

if not isinstance(profile, dict):
    fail("配置必须是 YAML 键值映射。")

def string(key, default=None):
    value = profile.get(key, default)
    if not isinstance(value, str) or not value.strip():
        fail(f"{key} 必须是非空字符串。")
    return value

def port(key, default=None):
    value = profile.get(key, default)
    if type(value) is not int or not 1 <= value <= 65535:
        fail(f"{key} 必须是 1 到 65535 之间的整数。")
    return value

server = string("server")
server_port = port("port")
password = string("password")
proxy_port = port("proxy_port", 7897)
name = string("name", "anytls")
skip_cert_verify = profile.get("skip_cert_verify", False)
if type(skip_cert_verify) is not bool:
    fail("skip_cert_verify 必须是 true 或 false。")

config = {
    "mixed-port": proxy_port,
    "allow-lan": False,
    "bind-address": "127.0.0.1",
    "mode": "rule",
    "log-level": "info",
    "proxies": [{
        "name": name,
        "type": "anytls",
        "server": server,
        "port": server_port,
        "password": password,
        "client-fingerprint": "chrome",
        "udp": True,
        "alpn": ["h2", "http/1.1"],
        "sni": string("sni", server),
        "skip-cert-verify": skip_cert_verify,
        "idle-session-check-interval": 30,
        "idle-session-timeout": 30,
        "min-idle-session": 0,
    }],
    "proxy-groups": [{"name": "PROXY", "type": "select", "proxies": [name]}],
    "rules": ["MATCH,PROXY"],
}
with open(sys.argv[2], "w", encoding="utf-8") as output:
    yaml.safe_dump(config, output, allow_unicode=True, sort_keys=False)
print(proxy_port)
PY
)"

"$HERE/kato.sh" install

if [[ -f "$CONFIG" ]]; then
    backup="$(mktemp "$CONFIG.bak.XXXXXXXX")"
    cat "$CONFIG" > "$backup"
fi
mv -f -- "$TEMP_CONFIG" "$CONFIG"
"$HERE/kato.sh" restart

if ! (exec 3<>"/dev/tcp/127.0.0.1/${PROXY_PORT}") 2>/dev/null; then
    printf '本地代理 127.0.0.1:%s 未监听，请检查日志。\n' "$PROXY_PORT" >&2
    exit 1
fi
printf 'Kato 已启动，本地 HTTP / SOCKS5 代理：127.0.0.1:%s\n' "$PROXY_PORT"
