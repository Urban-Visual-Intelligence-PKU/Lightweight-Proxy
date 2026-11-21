#!/usr/bin/env bash

# Kato tmux/session proxy switch
#
# 开启：
#   source ~/kato/kato-tmux.sh
#   source ~/kato/kato-tmux.sh on
#
# 关闭：
#   source ~/kato/kato-tmux.sh off
#
# 推荐在 ~/.bashrc 中添加：
#   alias kato='source ~/kato/kato-tmux.sh'
#   alias katooff='source ~/kato/kato-tmux.sh off'
#
# 注意：
#   - 本脚本必须使用 source 运行
#   - 本地代理端口读取 config.yaml 中的 mixed-port
#   - 不会误读远端节点（proxies 里）的 port:
#   - mixed-port 同时提供 HTTP 和 SOCKS5
#
# 本脚本刻意不使用 set -e，避免 source 时退出交互 shell。

# 必须使用 source
if [ "${BASH_SOURCE[0]:-x}" = "${0}" ]; then
    echo "[!] 请使用 source 运行："
    echo "    source ${0} [on|off]"
    exit 1
fi

_gp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_gp_action="${1:-on}"
_gp_home="${CLASH_HOME:-$HOME/.local/share/clash}"
_gp_config="${_gp_home}/config.yaml"

_gp_vars="
http_proxy
https_proxy
all_proxy
no_proxy
HTTP_PROXY
HTTPS_PROXY
ALL_PROXY
NO_PROXY
"

_gp_cleanup() {
    unset _gp_dir
    unset _gp_action
    unset _gp_home
    unset _gp_config
    unset _gp_vars
    unset _gp_port
    unset _gp_http_proxy
    unset _gp_https_proxy
    unset _gp_all_proxy
    unset _gp_no_proxy
    unset _gp_v
}

# ============================================================
# OFF
# ============================================================

if [ "$_gp_action" = "off" ]; then

    unset http_proxy
    unset https_proxy
    unset all_proxy
    unset no_proxy

    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset ALL_PROXY
    unset NO_PROXY

    if [ -n "${TMUX:-}" ]; then
        for _gp_v in $_gp_vars; do
            tmux set-environment -u "$_gp_v" 2>/dev/null || true
        done

        echo "[✓] 本 tmux session 已取消代理"
        echo "    当前 pane 已取消代理"
        echo "    新开的 pane / window 不再继承代理"
    else
        echo "[✓] 当前 shell 已取消代理"
    fi

    _gp_cleanup
    unset -f _gp_cleanup

    return 0 2>/dev/null || true
fi

# ============================================================
# ON
# ============================================================

if [ ! -f "$_gp_config" ]; then
    echo "[!] 找不到 Mihomo 配置："
    echo "    $_gp_config"
    echo
    echo "[!] 请先运行："
    echo "    $_gp_dir/kato-anytls-up.sh"

    _gp_cleanup
    unset -f _gp_cleanup
    return 1 2>/dev/null || true
fi

# 只读取本地 mixed-port，例如：
#   mixed-port: 7897
#
# 不会读取 proxies 里远端节点的：
#   port: <远端端口>
_gp_port="$(
    awk '
        /^[[:space:]]*mixed-port:[[:space:]]*[0-9]+/ {
            print $2
            exit
        }
    ' "$_gp_config" 2>/dev/null
)"

_gp_port="${_gp_port:-7897}"

# 检查 Mihomo 本地端口是否正在监听
if ! (exec 3<>"/dev/tcp/127.0.0.1/${_gp_port}") 2>/dev/null; then
    echo "[!] Mihomo 未在 127.0.0.1:${_gp_port} 监听"
    echo
    echo "[!] 请先运行："
    echo "    $_gp_dir/kato-anytls-up.sh"
    echo
    echo "[!] 或检查："
    echo "    ss -lntp | grep ${_gp_port}"

    _gp_cleanup
    unset -f _gp_cleanup
    return 1 2>/dev/null || true
fi

exec 3>&-

# ============================================================
# 设置代理
# ============================================================

_gp_http_proxy="http://127.0.0.1:${_gp_port}"
_gp_https_proxy="http://127.0.0.1:${_gp_port}"
_gp_all_proxy="socks5h://127.0.0.1:${_gp_port}"
_gp_no_proxy="127.0.0.1,localhost,::1"

export http_proxy="$_gp_http_proxy"
export https_proxy="$_gp_https_proxy"
export all_proxy="$_gp_all_proxy"
export no_proxy="$_gp_no_proxy"

export HTTP_PROXY="$_gp_http_proxy"
export HTTPS_PROXY="$_gp_https_proxy"
export ALL_PROXY="$_gp_all_proxy"
export NO_PROXY="$_gp_no_proxy"

# ============================================================
# tmux session 环境
# ============================================================

if [ -n "${TMUX:-}" ]; then

    for _gp_v in $_gp_vars; do
        tmux set-environment "$_gp_v" "${!_gp_v}"
    done

    echo "[✓] 本 tmux session 已走 Kato"
    echo "    HTTP/HTTPS : http://127.0.0.1:${_gp_port}"
    echo "    SOCKS5     : socks5h://127.0.0.1:${_gp_port}"
    echo "    当前 pane 已生效"
    echo "    新开的 pane / window 会自动继承"
else
    echo "[✓] 当前 shell 已走 Kato"
    echo "    HTTP/HTTPS : http://127.0.0.1:${_gp_port}"
    echo "    SOCKS5     : socks5h://127.0.0.1:${_gp_port}"
    echo "    当前不在 tmux 中，仅当前 shell 生效"
fi

_gp_cleanup
unset -f _gp_cleanup

return 0 2>/dev/null || true
