#!/usr/bin/env bash
#
# kato.sh —— 在 Linux 上「从零」安装并运行 Clash 内核（mihomo / Clash.Meta），
#             使用指定订阅，全程无需 root 权限。
#
# 用法：
#   ./bin/kato.sh up --config ruizhe  # 使用 config/ruizhe.yaml 启动 AnyTLS
#   ./bin/kato.sh install      # 下载内核 + GeoIP 数据（可用 GitHub 镜像加速）
#   ./bin/kato.sh subscribe    # 拉取订阅并生成 config.yaml（会自动做安全加固）
#   ./bin/kato.sh start        # 后台启动代理
#   ./bin/kato.sh status       # 查看运行状态，并通过代理做一次连通性测试
#   ./bin/kato.sh proxies      # 列出所有代理组和当前选中的节点
#   ./bin/kato.sh nodes [组名] # 列出某组可选节点（带序号；默认 🔰国外流量）
#   ./bin/kato.sh select 组名 序号|节点名   # 选择该组走哪个节点
#   ./bin/kato.sh test [组名]  # 测试组内各节点延迟，挑快的
#   ./bin/kato.sh stop         # 停止代理
#   ./bin/kato.sh restart      # 重启
#   ./bin/kato.sh env          # 打印代理环境变量（配合 eval 使用）
#   ./bin/kato.sh setup        # = install + subscribe + start 一条龙
#   ./bin/kato.sh log          # 跟踪日志
#
# 让当前 shell 走代理：   eval "$(./bin/kato.sh env)"
# 取消代理：             eval "$(./bin/kato.sh env off)"
#
# 环境变量：
#   SUB_URL      订阅地址（必填，含私密令牌，不写死在代码里）
#   CLASH_HOME   运行目录（放二进制/配置/日志），默认 ~/.local/share/clash
#   SUB_UA       拉订阅时用的 User-Agent（默认伪装成 clash 客户端，才能拿到 yaml）
#   GH_MIRRORS   GitHub 下载镜像前缀列表（空格分隔），国内网络加速用
#   NO_MIRROR=1  只走 GitHub 直连，不使用镜像
#
set -eu

# ------------------------------------------------------------------ 配置区 ---

# 订阅地址（必填，含私密令牌，不写死在代码里）：
#   export SUB_URL="https://机场域名/.../你的订阅路径"
# 只有 subscribe / setup 需要它；install/start/stop/status/env 不需要。
SUB_URL="${SUB_URL:-}"

# 拉订阅用的 UA：很多机场只有识别到 clash 客户端才返回 clash 格式的 yaml
SUB_UA="${SUB_UA:-clash-verge/v1.6.0}"

# 运行目录：默认放用户目录下，非 root 也能读写
CLASH_HOME="${CLASH_HOME:-$HOME/.local/share/clash}"

# 端口：默认用一套不常见的端口，避开机器上已有的 clash（常占 7890/7891/9090）。
# subscribe 时会把这些端口写进 config，且若被占用会自动 +1 递增到空闲端口。
HTTP_PORT="${HTTP_PORT:-7897}"     # HTTP 代理
SOCKS_PORT="${SOCKS_PORT:-7898}"   # SOCKS5 代理
CTRL_PORT="${CTRL_PORT:-9097}"     # 控制面板 API（仅监听本机）

# mihomo（Clash.Meta）—— 当前维护的 Clash 内核，兼容 clash 订阅
CORE_REPO="MetaCubeX/mihomo"
# API 拉不到时的兜底版本（构造直链下载）
FALLBACK_VER="v1.19.28"

# GeoIP 数据库（GEOIP,CN 规则需要）
GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"

# GitHub 下载镜像（国内加速）。直连失败会依次尝试这些镜像。
GH_MIRRORS="${GH_MIRRORS:-https://ghfast.top/ https://gh-proxy.com/ https://mirror.ghproxy.com/}"

# 运行时文件路径
CORE_BIN="$CLASH_HOME/mihomo"
CONFIG="$CLASH_HOME/config.yaml"
GEOIP_DB="$CLASH_HOME/geoip.metadb"
PID_FILE="$CLASH_HOME/clash.pid"
LOG_FILE="$CLASH_HOME/clash.log"

# --------------------------------------------------------------- 工具函数 ---

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()   { printf '\033[33m%s\033[0m\n' "$*" >&2; }
info()    { printf '\033[36m[*]\033[0m %s\n' "$*" >&2; }
ok()      { printf '\033[32m[+]\033[0m %s\n' "$*" >&2; }
warn()    { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die()     { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# 通过（可选镜像）从 GitHub 下载文件；先直连，失败再逐个试镜像
download_gh() {
    local url="$1" out="$2" name="${3:-文件}"
    local prefixes=("")
    if [ "${NO_MIRROR:-0}" != "1" ]; then
        # shellcheck disable=SC2206
        prefixes+=($GH_MIRRORS)
    fi
    local p full
    for p in "${prefixes[@]}"; do
        full="${p}${url}"
        [ -z "$p" ] && info "下载 $name（直连）..." || info "下载 $name（镜像 ${p%/}）..."
        if curl -fL --connect-timeout 15 --retry 2 --retry-delay 1 \
                -A "$SUB_UA" -o "$out.part" "$full"; then
            mv -f "$out.part" "$out"
            return 0
        fi
        rm -f "$out.part"
    done
    return 1
}

# 从形如 x86_64 的 uname -m 推断 mihomo 资产的匹配片段
core_arch_pattern() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "linux-amd64-compatible-" ;;   # compatible 版兼容性最好
        aarch64|arm64)  echo "linux-arm64-" ;;
        armv7l|armv7)   echo "linux-armv7-" ;;
        armv6l)         echo "linux-armv6-" ;;
        i386|i686)      echo "linux-386-" ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac
}

# 构造兜底直链（API 不可用时）
core_fallback_url() {
    local file
    case "$(uname -m)" in
        x86_64|amd64)   file="mihomo-linux-amd64-compatible-$FALLBACK_VER.gz" ;;
        aarch64|arm64)  file="mihomo-linux-arm64-$FALLBACK_VER.gz" ;;
        armv7l|armv7)   file="mihomo-linux-armv7-$FALLBACK_VER.gz" ;;
        armv6l)         file="mihomo-linux-armv6-$FALLBACK_VER.gz" ;;
        i386|i686)      file="mihomo-linux-386-$FALLBACK_VER.gz" ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac
    echo "https://github.com/$CORE_REPO/releases/download/$FALLBACK_VER/$file"
}

# 查最新版下载直链；失败返回兜底直链
resolve_core_url() {
    local pat api url
    pat="$(core_arch_pattern)"
    api="$(curl -fsSL --connect-timeout 15 \
            "https://api.github.com/repos/$CORE_REPO/releases/latest" 2>/dev/null || true)"
    if [ -n "$api" ]; then
        url="$(printf '%s\n' "$api" \
            | grep -oE '"browser_download_url": *"[^"]+"' \
            | sed -E 's/.*"(https[^"]+)".*/\1/' \
            | grep -- "$pat" \
            | grep -E '\.gz$' \
            | grep -vE '\-go1' \
            | head -n1 || true)"
        if [ -n "$url" ]; then echo "$url"; return 0; fi
    fi
    warn "GitHub API 不可用，改用兜底版本 $FALLBACK_VER"
    core_fallback_url
}

# 从 config.yaml 读取端口号（arg 为 port / socks-port / mixed-port）
get_port() {
    [ -f "$CONFIG" ] || return 1
    grep -E "^${1}:" "$CONFIG" | head -n1 | grep -oE '[0-9]+' | head -n1
}

# 端口是否空闲（无人监听）。无 root 也能判断。
port_free() {
    local p="$1"
    if have ss; then
        ! ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
    elif have netstat; then
        ! netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
    else
        ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
    fi
}

# 从 base 起找一个空闲端口（最多向上找 50 个）
pick_port() {
    local p="$1" i=0
    while [ "$i" -lt 50 ]; do
        port_free "$p" && { echo "$p"; return 0; }
        p=$((p + 1)); i=$((i + 1))
    done
    echo "$1"   # 实在找不到就用原值，交给内核报错
}

# 设置或追加一个顶层 key（value 原样写入）
set_kv() {
    local key="$1" val="$2" f="$3"
    if grep -qE "^${key}:" "$f"; then
        sed -i -E "s#^${key}:.*#${key}: ${val}#" "$f"
    else
        printf '%s: %s\n' "$key" "$val" >> "$f"
    fi
}

# 计算 http / socks 代理端口（优先 mixed-port）
http_port() {
    local m; m="$(get_port mixed-port || true)"
    if [ -n "$m" ]; then echo "$m"; else get_port port; fi
}
socks_port() {
    local m; m="$(get_port mixed-port || true)"
    if [ -n "$m" ]; then echo "$m"; else get_port socks-port; fi
}

running_pid() {
    [ -f "$PID_FILE" ] || return 1
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "$pid"; return 0; }
    return 1
}

# ------------------------------------------------------------------ 子命令 ---

cmd_install() {
    have curl || die "需要 curl，请先安装（无 root 可用 conda/静态包，或让管理员装）"
    have gzip || die "需要 gzip"
    mkdir -p "$CLASH_HOME"

    if [ -x "$CORE_BIN" ]; then
        info "已存在内核：$("$CORE_BIN" -v 2>/dev/null | head -n1)"
    else
        local url
        url="$(resolve_core_url)"
        info "内核下载地址：$url"
        download_gh "$url" "$CORE_BIN.gz" "mihomo 内核" || die "内核下载失败（检查网络或设置 GH_MIRRORS）"
        gzip -df "$CORE_BIN.gz"
        chmod +x "$CORE_BIN"
        "$CORE_BIN" -v >/dev/null 2>&1 || die "内核无法执行（架构可能不匹配）"
        ok "内核安装完成：$("$CORE_BIN" -v 2>/dev/null | head -n1)"
    fi

    if [ -s "$GEOIP_DB" ]; then
        info "GeoIP 数据已存在，跳过"
    else
        download_gh "$GEOIP_URL" "$GEOIP_DB" "GeoIP 数据库" \
            || warn "GeoIP 下载失败，首次启动时 mihomo 会尝试自动下载"
        [ -s "$GEOIP_DB" ] && ok "GeoIP 数据就绪：$GEOIP_DB"
    fi
    ok "安装目录：$CLASH_HOME"
}

cmd_subscribe() {
    have curl || die "需要 curl"
    [ -n "$SUB_URL" ] || die "未设置订阅地址。请先：export SUB_URL=\"https://机场域名/你的订阅路径\"  再执行 $0 subscribe"
    mkdir -p "$CLASH_HOME"
    local tmp="$CONFIG.new"
    info "拉取订阅：$SUB_URL"
    curl -fL --connect-timeout 20 --retry 3 -A "$SUB_UA" -o "$tmp" "$SUB_URL" \
        || die "订阅拉取失败（检查网络 / 订阅是否有效）"

    # 校验是否为 clash 格式（应包含 proxies 与 proxy-groups）
    if ! grep -qE '^proxies:' "$tmp" || ! grep -qE '^proxy-groups:' "$tmp"; then
        c_ylw "订阅返回内容的前几行："
        head -n 5 "$tmp" >&2
        rm -f "$tmp"
        die "订阅未返回 clash 配置（可能被识别为其它客户端）。可尝试更换 SUB_UA 后重试。"
    fi

    # —— 选端口：避开机器上已有的 clash（自动跳过被占用端口）——
    local hp sp cp
    hp="$(pick_port "$HTTP_PORT")"
    sp="$(pick_port "$SOCKS_PORT")"; [ "$sp" = "$hp" ] && sp="$(pick_port $((sp + 1)))"
    cp="$(pick_port "$CTRL_PORT")"
    info "本实例端口 → HTTP:$hp  SOCKS:$sp  控制面板:$cp"

    # 写入端口（订阅若用 mixed-port 也一并改掉，避免与 port 冲突）
    set_kv port        "$hp" "$tmp"
    set_kv socks-port  "$sp" "$tmp"
    grep -qE '^mixed-port:' "$tmp" && set_kv mixed-port "$hp" "$tmp" || true

    # —— 安全加固：控制面板只监听本机，避免同机其他用户访问 ——
    set_kv external-controller "'127.0.0.1:$cp'" "$tmp"
    grep -qE '^allow-lan:' "$tmp" && sed -i -E 's#^allow-lan:.*#allow-lan: false#' "$tmp" || true

    mv -f "$tmp" "$CONFIG"
    ok "配置已生成：$CONFIG"
    info "HTTP 端口：$(http_port 2>/dev/null || echo '?')  SOCKS 端口：$(socks_port 2>/dev/null || echo '?')  控制面板：127.0.0.1:$cp"

    # 若已装内核，顺便做一次配置语法校验
    if [ -x "$CORE_BIN" ]; then
        if "$CORE_BIN" -t -d "$CLASH_HOME" -f "$CONFIG" >/dev/null 2>&1; then
            ok "配置语法校验通过"
        else
            warn "配置语法校验未通过，可运行以下命令查看详情："
            echo "    $CORE_BIN -t -d $CLASH_HOME -f $CONFIG" >&2
        fi
    fi
}

cmd_start() {
    [ -x "$CORE_BIN" ] || die "内核不存在，请先执行：$0 install"
    [ -f "$CONFIG" ]   || die "配置不存在，请先执行：$0 subscribe"

    if pid="$(running_pid)"; then
        info "已在运行 (pid=$pid)"
        # 若配置里的控制面板端口连不上，说明配置变了但进程还是旧的
        if ! curl -fsS --max-time 2 "$(api_base)/version" >/dev/null 2>&1; then
            warn "但控制面板 $(api_base) 无响应——配置可能已更新，运行的还是旧进程。"
            warn "请执行： $0 restart   让新配置/端口生效。"
        fi
        cmd_status; return 0
    fi

    info "启动 Clash（后台）..."
    nohup "$CORE_BIN" -d "$CLASH_HOME" -f "$CONFIG" >>"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    # 等待就绪（最多 ~5s）；用配置里真实的控制面板端口做探活
    local i pid
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        pid="$(running_pid || true)"
        [ -z "$pid" ] && break
        if curl -fsS --max-time 1 "$(api_base)/version" >/dev/null 2>&1; then
            break
        fi
    done

    if ! running_pid >/dev/null; then
        c_red "启动失败，日志末尾："
        tail -n 20 "$LOG_FILE" >&2
        die "请检查配置或日志：$LOG_FILE"
    fi
    # 探活控制面板；连不上多半是端口没绑上（被占用）
    if ! curl -fsS --max-time 2 "$(api_base)/version" >/dev/null 2>&1; then
        warn "控制面板 $(api_base) 未响应：可能端口被占用未绑上。"
        warn "可换端口后重来： CTRL_PORT=9099 $0 subscribe && $0 restart"
    fi
    ok "已启动 (pid=$(cat "$PID_FILE"))"
    cmd_status
}

cmd_stop() {
    if pid="$(running_pid)"; then
        kill "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
        ok "已停止"
    else
        info "未在运行"
        rm -f "$PID_FILE"
    fi
}

cmd_status() {
    local hp sp pid
    hp="$(http_port 2>/dev/null || echo '?')"
    sp="$(socks_port 2>/dev/null || echo '?')"
    if pid="$(running_pid)"; then
        c_grn "● 运行中 (pid=$pid)"
    else
        c_red "○ 未运行"; return 0
    fi
    echo "  版本      : $("$CORE_BIN" -v 2>/dev/null | head -n1)"
    echo "  HTTP 代理 : http://127.0.0.1:$hp"
    echo "  SOCKS 代理: socks5://127.0.0.1:$sp"
    echo "  控制面板  : $(api_base 2>/dev/null || echo 'http://127.0.0.1:9090')"
    echo "  日志      : $LOG_FILE"
    # 通过代理做一次连通性测试
    info "连通性测试（经代理访问 gstatic 204）..."
    if curl -fsS --max-time 8 -x "http://127.0.0.1:$hp" \
            "http://www.gstatic.com/generate_204" >/dev/null 2>&1; then
        ok "代理连通正常 ✔"
    else
        warn "经代理测试未通过（可能是节点选择/网络问题，可看日志或换节点）"
    fi
}

cmd_env() {
    if [ "${1:-on}" = "off" ]; then
        cat <<'EOF'
unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
EOF
        return 0
    fi
    local hp sp
    hp="$(http_port 2>/dev/null || echo 7890)"
    sp="$(socks_port 2>/dev/null || echo 7891)"
    cat <<EOF
export http_proxy="http://127.0.0.1:$hp"
export https_proxy="http://127.0.0.1:$hp"
export all_proxy="socks5://127.0.0.1:$sp"
export no_proxy="localhost,127.0.0.1,::1"
export HTTP_PROXY="http://127.0.0.1:$hp"
export HTTPS_PROXY="http://127.0.0.1:$hp"
export ALL_PROXY="socks5://127.0.0.1:$sp"
export NO_PROXY="localhost,127.0.0.1,::1"
EOF
}

# ---------------------------------------------- 选节点（走控制面板 API） ---
# 说明：所有代理组都是 select（手动）类型，需要自己指定组走哪个节点。
#       主组是 🔰国外流量（大部分规则都走它）。

# 控制面板地址（从 config 读取；0.0.0.0 视为本机）
api_base() {
    local ec
    ec="$(grep -E '^external-controller:' "$CONFIG" 2>/dev/null | head -n1 \
        | sed -E "s/^external-controller:[[:space:]]*//; s/^['\"]//; s/['\"].*$//")"
    [ -z "$ec" ] && ec="127.0.0.1:9090"
    echo "http://${ec/0.0.0.0/127.0.0.1}"
}
api_secret() {
    grep -E '^secret:' "$CONFIG" 2>/dev/null | head -n1 \
        | sed -E "s/^secret:[[:space:]]*//; s/^['\"]//; s/['\"]$//"
}
# api METHOD PATH [json-body]
api() {
    local method="$1" path="$2" data="${3:-}" sec
    sec="$(api_secret)"
    local args=(-s --max-time 12 -X "$method" "$(api_base)$path")
    [ -n "$sec" ] && args+=(-H "Authorization: Bearer $sec")
    [ -n "$data" ] && args+=(-H 'Content-Type: application/json' -d "$data")
    curl "${args[@]}"
}
# 从 config 的 proxy-groups 里取出所有组名
group_names() {
    [ -f "$CONFIG" ] || return 1
    awk '/^proxy-groups:/{f=1;next} /^rules:/{f=0} f' "$CONFIG" \
        | grep -E '(^|[[:space:]])name:' \
        | sed -E 's/^[[:space:]]*-?[[:space:]]*name:[[:space:]]*//; s/^['\''"]//; s/['\''"]$//'
}
_json_str() { grep -oE "\"$1\":\"[^\"]*\"" | head -n1 | sed -E "s/\"$1\":\"//; s/\"$//"; }
# 取某组的 all 列表（每行一个节点名）
_group_all() {
    api GET "/proxies/$1" \
        | grep -oE '"all":\[[^]]*\]' | sed -E 's/^"all":\[//; s/\]$//; s/^"//; s/"$//' \
        | awk -F'","' '{for(i=1;i<=NF;i++) print $i}'
}
# 控制面板是否可用；不可用给出明确指引后退出
require_api() {
    running_pid >/dev/null || die "未运行，先执行：$0 start"
    if ! curl -fsS --max-time 3 "$(api_base)/version" >/dev/null 2>&1; then
        die "控制面板 $(api_base) 无响应。常见原因：改了端口但没重启，或端口被占用未绑上。
    请执行： $0 restart      （或 $0 diag 排查端口占用）"
    fi
}

cmd_proxies() {
    require_api
    echo "代理组（带 → 的是当前选择）："
    local g resp now type
    while IFS= read -r g; do
        [ -z "$g" ] && continue
        resp="$(api GET "/proxies/$g" || true)"
        now="$(printf '%s' "$resp"  | _json_str now || true)"
        type="$(printf '%s' "$resp" | _json_str type || true)"
        printf '  %s  [%s]  →  %s\n' "$g" "${type:-?}" "${now:-?}"
    done < <(group_names)
    echo
    echo "看某组可选节点： $0 nodes '组名'"
    echo "选节点：         $0 select '组名' <序号或节点名>"
}

cmd_nodes() {
    local g="${1:-🔰国外流量}"
    require_api
    local resp now; resp="$(api GET "/proxies/$g" || true)"
    printf '%s' "$resp" | grep -q '"all"' || die "找不到组「$g」。用 $0 proxies 看有哪些组。"
    now="$(printf '%s' "$resp" | _json_str now || true)"
    echo "组「$g」的节点（* = 当前）："
    _group_all "$g" | awk -v now="$now" '{
        mark=($0==now?" *":"  "); printf "%4d%s %s\n", NR, mark, $0 }'
    echo
    echo "切换： $0 select '$g' <序号>    测速： $0 test '$g'"
}

cmd_select() {
    local g="${1:-}" sel="${2:-}"
    [ -n "$g" ] && [ -n "$sel" ] || die "用法：$0 select '组名' <序号或节点名>"
    require_api
    local name="$sel"
    if printf '%s' "$sel" | grep -qE '^[0-9]+$'; then
        name="$(_group_all "$g" | awk -v n="$sel" 'NR==n{print; exit}')"
        [ -n "$name" ] || die "序号 $sel 超出范围（用 $0 nodes '$g' 查看）"
    fi
    api PUT "/proxies/$g" "$(printf '{"name":"%s"}' "$name")" >/dev/null 2>&1 || true
    sleep 0.3
    local now2; now2="$(api GET "/proxies/$g" | _json_str now || true)"
    if [ "$now2" = "$name" ]; then ok "已切换：$g → $name"; else
        warn "切换未生效，当前为：${now2:-未知}（组名/节点名要和列表完全一致）"; fi
}

cmd_test() {
    local g="${1:-🔰国外流量}"
    require_api
    info "正在测速「$g」内各节点（约几秒）..."
    api GET "/group/$g/delay?url=http://www.gstatic.com/generate_204&timeout=5000" 2>/dev/null \
        | sed -E 's/^\{//; s/\}$//; s/,"/\n"/g' \
        | awk -F'":' 'NF>=2{name=$1; sub(/^"/,"",name); d=$2; printf "%6s ms  %s\n", d, name}' \
        | sort -n \
        || warn "测速失败（组名是否正确？）"
    echo "（延迟越小越快；选它： $0 select '$g' '节点名'）"
}

cmd_diag() {
    echo "== 运行目录 =="; echo "  $CLASH_HOME"
    echo "== 我们的进程 =="
    if pid="$(running_pid)"; then echo "  运行中 pid=$pid"; else echo "  未运行"; fi
    echo "== 配置端口 =="
    echo "  port(HTTP) : $(get_port port 2>/dev/null || echo -)"
    echo "  socks-port : $(get_port socks-port 2>/dev/null || echo -)"
    echo "  控制面板   : $(api_base 2>/dev/null || echo -)"
    echo "== 控制面板是否响应（我们的实例）=="
    if curl -fsS --max-time 3 "$(api_base)/version" 2>/dev/null; then echo; else echo "  无响应"; fi
    echo "== 本机 7890/7891/9090/$(get_port port 2>/dev/null)/$(get_port socks-port 2>/dev/null) 监听情况 =="
    { ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null; } \
        | grep -E ':(7890|7891|9090|9097|7897|7898)' || echo "  （无匹配）"
    echo "提示：若控制面板无响应而端口被别的进程占用，改端口重来："
    echo "     CTRL_PORT=9099 HTTP_PORT=7899 SOCKS_PORT=7900 $0 subscribe && $0 restart"
}

cmd_log()   { touch "$LOG_FILE"; tail -n 40 -f "$LOG_FILE"; }
cmd_setup() { cmd_install; cmd_subscribe; cmd_start; }

usage() {
    # 打印文件开头的注释块（去掉 # 前缀），遇到第一行非注释即停
    awk 'NR==1{next} /^#/{sub(/^#!?/,""); sub(/^ /,""); print; next} {exit}' "$0"
}

# --------------------------------------------------------------- 入口分发 ---

case "${1:-}" in
    up)        shift; exec "$(dirname "$0")/kato-anytls-up.sh" "$@" ;;
    install)   cmd_install ;;
    subscribe|sub) cmd_subscribe ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_stop; cmd_start ;;
    status)    cmd_status ;;
    env)       cmd_env "${2:-on}" ;;
    proxies|groups) cmd_proxies ;;
    nodes|ls)  cmd_nodes "${2:-}" ;;
    select|use) cmd_select "${2:-}" "${3:-}" ;;
    test|speed) cmd_test "${2:-}" ;;
    diag|debug) cmd_diag ;;
    log|logs)  cmd_log ;;
    setup)     cmd_setup ;;
    ""|help|-h|--help) usage ;;
    *) die "未知命令：$1（运行 $0 help 查看用法）" ;;
esac
