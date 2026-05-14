#!/bin/bash
#
# Snell 交互式管理脚本(Ubuntu / Debian)
# 功能:安装 / 查看配置 / 重启 / 修改端口/PSK/IPv6/DNS / 卸载
#

set -e
set -u

# ==================== 配置区 ====================
SNELL_VERSION="v5.0.1"
SNELL_MAJOR_VERSION=$(echo "$SNELL_VERSION" | grep -oE '^v[0-9]+')
SNELL_DIR="/etc/snell"
SNELL_CONF="${SNELL_DIR}/snell-server.conf"
SNELL_BIN="${SNELL_DIR}/snell-server"
SNELL_SERVICE="/etc/systemd/system/snell.service"
# =================================================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_err "请使用 root 用户或 sudo 执行此脚本"
    exit 1
fi

# ==================== 工具函数 ====================

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        echo "unknown"
        return
    fi
    
    local os_id
    os_id=$(grep -E '^ID=' /etc/os-release | sed 's/ID=//; s/"//g')
    
    case "$os_id" in
        ubuntu) echo "ubuntu" ;;
        debian) echo "debian" ;;
        linuxmint|pop|kali|raspbian|deepin|elementary)
            local id_like
            id_like=$(grep -E '^ID_LIKE=' /etc/os-release | sed 's/ID_LIKE=//; s/"//g')
            if [[ "$id_like" =~ ubuntu ]]; then
                echo "ubuntu"
            elif [[ "$id_like" =~ debian ]]; then
                echo "debian"
            else
                echo "unknown"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

get_os_pretty_name() {
    if [[ -f /etc/os-release ]]; then
        grep -E '^PRETTY_NAME=' /etc/os-release | sed 's/PRETTY_NAME=//; s/"//g'
    else
        echo "Unknown"
    fi
}

is_snell_installed() {
    [[ -f "$SNELL_BIN" && -f "$SNELL_CONF" ]]
}

# 按 snell-server wizard 的规则生成 PSK
# 规则:31 位,字符集 [A-Za-z0-9],读取 /dev/urandom 作为随机源
generate_psk() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 31
}

# 读取端口:取最后一个 ':' 之后的内容(兼容 IPv4/IPv6 监听)
get_snell_port() {
    if [[ -f "$SNELL_CONF" ]]; then
        awk '/^listen[[:space:]]*=/ {
            n = split($0, parts, ":")
            gsub(/[[:space:]]/, "", parts[n])
            print parts[n]
        }' "$SNELL_CONF"
    fi
}

# 读取 PSK:只在第一个 '=' 处切分
get_snell_psk() {
    if [[ -f "$SNELL_CONF" ]]; then
        awk '/^psk[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            print
        }' "$SNELL_CONF"
    fi
}

# 读取配置中的任意键值(只匹配未注释的行)
get_snell_config_value() {
    local key=$1
    if [[ -f "$SNELL_CONF" ]]; then
        awk -v key="$key" '
            $0 ~ "^"key"[[:space:]]*=" {
                sub(/^[^=]*=[[:space:]]*/, "")
                sub(/[[:space:]]+$/, "")
                print
                exit
            }
        ' "$SNELL_CONF"
    fi
}

# 判断配置中是否存在某个键(未被注释)
has_snell_config_key() {
    local key=$1
    [[ -f "$SNELL_CONF" ]] && grep -qE "^${key}[[:space:]]*=" "$SNELL_CONF"
}

# 根据 ipv6 设置返回对应的 listen 监听地址前缀
# - ipv6 = true  → 用 ::0 (双栈监听,Linux 默认同时接受 IPv4)
# - ipv6 = false → 用 0.0.0.0 (仅 IPv4)
get_listen_prefix() {
    local ipv6=$1
    if [[ "$ipv6" == "true" ]]; then
        echo "::0"
    else
        echo "0.0.0.0"
    fi
}

get_public_ip() {
    curl -s -m 5 ifconfig.me 2>/dev/null || \
    curl -s -m 5 ipinfo.io/ip 2>/dev/null || \
    echo "无法获取"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)   echo "amd64" ;;
        aarch64)  echo "aarch64" ;;
        i386|i686) echo "i386" ;;
        armv7l)   echo "armv7l" ;;
        *)        echo "" ;;
    esac
}

validate_port() {
    local port=$1
    local check_occupied=${2:-yes}
    
    if [[ -z "$port" ]]; then
        log_err "端口不能为空"
        return 1
    fi
    
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log_err "端口必须是数字"
        return 1
    fi
    
    if (( port < 1024 || port > 65535 )); then
        log_err "端口必须在 1024-65535 范围内"
        return 1
    fi
    
    if [[ "$check_occupied" == "yes" ]]; then
        if ss -tunlp 2>/dev/null | grep -q ":${port} "; then
            log_warn "端口 ${port} 已被占用:"
            ss -tunlp | grep ":${port} " || true
            return 2
        fi
    fi
    
    return 0
}

ask_yes_no() {
    local prompt=$1
    local default=${2:-n}
    local hint
    
    if [[ "$default" == "y" ]]; then
        hint="(Y/n)"
    else
        hint="(y/N)"
    fi
    
    local input
    read -p "${prompt} ${hint}: " input
    
    if [[ -z "$input" ]]; then
        input="$default"
    fi
    
    case "$input" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

backup_conf() {
    cp "$SNELL_CONF" "${SNELL_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    log_ok "配置文件已备份"
}

# 设置/更新某个键
set_snell_config_key() {
    local key=$1
    local value=$2
    
    if has_snell_config_key "$key"; then
        awk -v key="$key" -v value="$value" '
            $0 ~ "^"key"[[:space:]]*=" {
                print key " = " value
                next
            }
            { print }
        ' "$SNELL_CONF" > "${SNELL_CONF}.tmp" && mv "${SNELL_CONF}.tmp" "$SNELL_CONF"
    else
        echo "${key} = ${value}" >> "$SNELL_CONF"
    fi
}

# 注释掉某个键(把 "key = value" 改成 "# key = value")
# 如果当前没有该键的有效行,但有注释行,保留注释不动
# 如果都没有,什么都不做
comment_snell_config_key() {
    local key=$1
    
    # 如果存在未注释的键,把它注释掉
    if has_snell_config_key "$key"; then
        awk -v key="$key" '
            $0 ~ "^"key"[[:space:]]*=" {
                print "# " $0
                next
            }
            { print }
        ' "$SNELL_CONF" > "${SNELL_CONF}.tmp" && mv "${SNELL_CONF}.tmp" "$SNELL_CONF"
    fi
}

# 取消注释某个键(注释行 → 未注释)
# 如果未找到注释行,但传入了 fallback_value,则追加一行
uncomment_snell_config_key() {
    local key=$1
    local fallback_value=${2:-}
    
    # 已经有未注释的有效行,直接返回
    if has_snell_config_key "$key"; then
        return
    fi
    
    # 查找注释行(以 # 开头,后面跟该键)
    if grep -qE "^#[[:space:]]*${key}[[:space:]]*=" "$SNELL_CONF"; then
        # 把注释行取消注释(只取消第一个匹配)
        awk -v key="$key" '
            !done && $0 ~ "^#[[:space:]]*"key"[[:space:]]*=" {
                sub(/^#[[:space:]]*/, "")
                done = 1
            }
            { print }
        ' "$SNELL_CONF" > "${SNELL_CONF}.tmp" && mv "${SNELL_CONF}.tmp" "$SNELL_CONF"
    elif [[ -n "$fallback_value" ]]; then
        # 没注释行也没有效行,追加
        echo "${key} = ${fallback_value}" >> "$SNELL_CONF"
    fi
}

# 生成 Snell 配置文件
write_snell_conf() {
    local port=$1
    local psk=$2
    local ipv6=$3       # true / false
    local dns=$4        # 空字符串表示注释掉
    
    local listen_prefix
    listen_prefix=$(get_listen_prefix "$ipv6")
    
    {
        echo "[snell-server]"
        echo "listen = ${listen_prefix}:${port}"
        echo "psk = ${psk}"
        echo "ipv6 = ${ipv6}"
        if [[ -n "$dns" ]]; then
            echo "dns = ${dns}"
        else
            echo "# dns = 1.1.1.1, 8.8.8.8"
        fi
        echo "# egress-interface = eth0"
    } > "$SNELL_CONF"
}

# 根据 ipv6 设置更新 listen 行的监听地址前缀,保留端口
update_listen_for_ipv6() {
    local ipv6=$1
    local port
    port=$(get_snell_port)
    
    local listen_prefix
    listen_prefix=$(get_listen_prefix "$ipv6")
    
    awk -v line="listen = ${listen_prefix}:${port}" '
        /^listen[[:space:]]*=/ { print line; next }
        { print }
    ' "$SNELL_CONF" > "${SNELL_CONF}.tmp" && mv "${SNELL_CONF}.tmp" "$SNELL_CONF"
}

# 更新端口(保持当前的监听协议格式)
update_listen_port() {
    local new_port=$1
    local current_ipv6
    current_ipv6=$(get_snell_config_value "ipv6")
    
    local listen_prefix
    listen_prefix=$(get_listen_prefix "$current_ipv6")
    
    awk -v line="listen = ${listen_prefix}:${new_port}" '
        /^listen[[:space:]]*=/ { print line; next }
        { print }
    ' "$SNELL_CONF" > "${SNELL_CONF}.tmp" && mv "${SNELL_CONF}.tmp" "$SNELL_CONF"
}

# ==================== 功能模块 ====================

show_config() {
    echo
    echo "============================================"
    echo -e "${CYAN}Snell 配置信息${NC}"
    echo "============================================"
    
    local port psk public_ip ipv6 dns
    port=$(get_snell_port)
    psk=$(get_snell_psk)
    public_ip=$(get_public_ip)
    ipv6=$(get_snell_config_value "ipv6")
    dns=$(get_snell_config_value "dns")
    
    echo
    echo -e "${GREEN}文件路径:${NC}"
    echo "  二进制文件:    $SNELL_BIN"
    echo "  配置文件:      $SNELL_CONF"
    echo "  systemd 服务:  $SNELL_SERVICE"
    echo
    echo -e "${GREEN}连接信息:${NC}"
    echo "  IP 地址:    $public_ip"
    echo "  端口:       $port"
    echo "  PSK:        $psk"
    echo "  协议版本:    ${SNELL_MAJOR_VERSION}"
    echo
    echo -e "${GREEN}其他配置:${NC}"
    echo "  IPv6:       ${ipv6:-未配置}"
    echo "  DNS:        ${dns:-未配置(使用系统默认)}"
    echo
    echo -e "${GREEN}配置文件内容:${NC}"
    echo "  --------------------------------"
    sed 's/^/  /' "$SNELL_CONF"
    echo "  --------------------------------"
    echo
    echo "============================================"
}

show_commands() {
    echo
    echo "============================================"
    echo -e "${CYAN}Snell 服务管理命令${NC}"
    echo "============================================"
    echo
    echo -e "${GREEN}基础操作:${NC}"
    echo "  启动服务:        systemctl start snell"
    echo "  停止服务:        systemctl stop snell"
    echo "  重启服务:        systemctl restart snell"
    echo "  查看状态:        systemctl status snell"
    echo
    echo -e "${GREEN}开机自启:${NC}"
    echo "  启用开机自启:    systemctl enable snell"
    echo "  禁用开机自启:    systemctl disable snell"
    echo
    echo -e "${GREEN}日志查看:${NC}"
    echo "  实时日志:        journalctl -u snell -f"
    echo "  最近 50 行:      journalctl -u snell -n 50 --no-pager"
    echo "  今天的日志:      journalctl -u snell --since today"
    echo
    echo -e "${GREEN}诊断命令:${NC}"
    echo "  查看端口监听:    ss -tunlp | grep snell"
    echo "  检查 BBR 状态:   sysctl net.ipv4.tcp_congestion_control"
    echo "  查看进程:        ps aux | grep snell"
    echo
    echo -e "${GREEN}TCP Fast Open (内核 sysctl):${NC}"
    echo "  查看 TFO 状态:   sysctl net.ipv4.tcp_fastopen"
    echo "    返回值含义:"
    echo "      0  = 完全禁用 TFO"
    echo "      1  = 仅作为客户端启用(系统默认)"
    echo "      2  = 仅作为服务端启用"
    echo "      3  = 客户端和服务端都启用(Snell 服务端推荐)"
    local current_tfo
    current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "?")
    echo "    当前值:        ${current_tfo}"
    echo "  临时启用 (重启失效):   sysctl -w net.ipv4.tcp_fastopen=3"
    echo "  永久启用 (写入配置):"
    echo "    echo 'net.ipv4.tcp_fastopen=3' > /etc/sysctl.d/99-snell-tfo.conf"
    echo "    sysctl --system"
    echo "  注:Snell 服务端 TFO 由内核 sysctl 控制"
    echo
    echo -e "${GREEN}配置修改:${NC}"
    echo "  编辑配置:        vi $SNELL_CONF"
    echo "  修改后需重启:    systemctl restart snell"
    echo
    echo -e "${YELLOW}当前服务状态:${NC}"
    if systemctl is-active --quiet snell; then
        echo -e "  ${GREEN}● 运行中${NC}"
    else
        echo -e "  ${RED}● 未运行${NC}"
    fi
    echo
    echo "============================================"
}

restart_snell() {
    echo
    echo "============================================"
    echo -e "${CYAN}重启 Snell 服务${NC}"
    echo "============================================"
    echo
    log_info "正在重启 Snell..."
    systemctl restart snell
    sleep 2
    
    if systemctl is-active --quiet snell; then
        log_ok "Snell 已成功重启,当前运行中"
        echo
        echo "最近 10 行启动日志:"
        echo "  --------------------------------"
        journalctl -u snell -n 10 --no-pager | sed 's/^/  /'
        echo "  --------------------------------"
    else
        log_err "Snell 重启失败,查看日志:"
        journalctl -u snell -n 20 --no-pager
    fi
    echo
}

change_port() {
    local old_port new_port
    old_port=$(get_snell_port)
    
    echo
    echo "============================================"
    echo -e "${CYAN}修改 Snell 监听端口${NC}"
    echo "============================================"
    echo
    echo -e "当前端口: ${YELLOW}${old_port}${NC}"
    echo
    
    while true; do
        read -p "请输入新端口(1024-65535,直接回车取消): " new_port
        
        if [[ -z "$new_port" ]]; then
            log_info "已取消修改"
            return
        fi
        
        if [[ "$new_port" == "$old_port" ]]; then
            log_warn "新端口与当前端口相同,无需修改"
            return
        fi
        
        validate_port "$new_port" "no" || continue
        
        if ss -tunlp 2>/dev/null | grep ":${new_port} " | grep -qv snell-server; then
            log_warn "端口 ${new_port} 已被其他进程占用:"
            ss -tunlp | grep ":${new_port} " | grep -v snell-server || true
            if ! ask_yes_no "仍要使用此端口吗?" "n"; then
                continue
            fi
        fi
        
        break
    done
    
    echo
    echo "即将执行:"
    echo "  - 修改配置文件中的端口: ${old_port} → ${new_port}"
    echo "  - 重启 Snell 服务"
    echo
    log_warn "云厂商安全组规则需要你自己手动更新"
    echo
    if ! ask_yes_no "确认修改?" "n"; then
        log_info "已取消"
        return
    fi
    
    backup_conf
    update_listen_port "$new_port"
    log_ok "配置文件已更新"
    
    log_info "重启 Snell 服务..."
    systemctl restart snell
    sleep 2
    
    if systemctl is-active --quiet snell && ss -tunlp | grep -q ":${new_port} "; then
        echo
        log_ok "端口已成功修改为 ${new_port}"
        echo
        echo -e "${YELLOW}重要提醒:${NC}"
        echo "  1. 云厂商安全组需手动放行 ${new_port}/tcp 和 ${new_port}/udp"
        echo "  2. 旧端口 ${old_port} 的云安全组规则建议删除"
        echo
    else
        log_err "端口修改后服务异常,正在恢复..."
        update_listen_port "$old_port"
        systemctl restart snell
        log_warn "已回滚到原端口 ${old_port},请查看日志: journalctl -u snell -n 30"
    fi
}

change_psk() {
    local old_psk new_psk
    old_psk=$(get_snell_psk)
    
    echo
    echo "============================================"
    echo -e "${CYAN}修改 Snell PSK${NC}"
    echo "============================================"
    echo
    echo -e "当前 PSK: ${YELLOW}${old_psk}${NC}"
    echo
    echo "请输入新 PSK:"
    echo "  - 直接回车将自动生成 31 位随机 PSK"
    echo "  - 输入 'q' 取消"
    read -p "新 PSK: " new_psk
    
    if [[ "$new_psk" == "q" || "$new_psk" == "Q" ]]; then
        log_info "已取消修改"
        return
    fi
    
    if [[ -z "$new_psk" ]]; then
        new_psk=$(generate_psk)
        log_ok "已生成新 PSK: $new_psk"
    fi
    
    if [[ "$new_psk" == "$old_psk" ]]; then
        log_warn "新 PSK 与当前相同,无需修改"
        return
    fi
    
    echo
    echo "即将执行:"
    echo "  - 修改配置文件中的 PSK"
    echo "  - 重启 Snell 服务"
    echo
    if ! ask_yes_no "确认修改?" "n"; then
        log_info "已取消"
        return
    fi
    
    backup_conf
    
    awk -v new_psk="$new_psk" '
        /^psk[[:space:]]*=/ { print "psk = " new_psk; next }
        { print }
    ' "$SNELL_CONF" > "${SNELL_CONF}.tmp" && mv "${SNELL_CONF}.tmp" "$SNELL_CONF"
    log_ok "配置文件已更新"
    
    log_info "重启 Snell 服务..."
    systemctl restart snell
    sleep 2
    
    if systemctl is-active --quiet snell; then
        echo
        log_ok "PSK 已成功修改"
        echo
    else
        log_err "PSK 修改后服务异常,查看日志:"
        journalctl -u snell -n 20 --no-pager
    fi
}

change_ipv6() {
    local old_ipv6
    old_ipv6=$(get_snell_config_value "ipv6")
    
    echo
    echo "============================================"
    echo -e "${CYAN}修改 IPv6 设置${NC}"
    echo "============================================"
    echo
    echo -e "当前 IPv6: ${YELLOW}${old_ipv6:-未配置}${NC}"
    echo
    echo "说明:控制 Snell 是否启用 IPv6"
    echo "  - 启用后 listen 地址会变为 ::0(双栈监听)"
    echo "  - 启用前请确保 VPS 支持 IPv6"
    echo
    
    local new_ipv6
    if ask_yes_no "启用 IPv6?" "n"; then
        new_ipv6="true"
    else
        new_ipv6="false"
    fi
    
    if [[ "$new_ipv6" == "$old_ipv6" ]]; then
        log_warn "新设置与当前相同,无需修改"
        return
    fi
    
    local current_port
    current_port=$(get_snell_port)
    local new_listen_prefix
    new_listen_prefix=$(get_listen_prefix "$new_ipv6")
    
    echo
    echo "即将执行:"
    echo "  - 设置 ipv6 = ${new_ipv6}"
    echo "  - 更新 listen = ${new_listen_prefix}:${current_port}"
    echo "  - 重启 Snell 服务"
    echo
    if ! ask_yes_no "确认修改?" "n"; then
        log_info "已取消"
        return
    fi
    
    backup_conf
    set_snell_config_key "ipv6" "$new_ipv6"
    update_listen_for_ipv6 "$new_ipv6"
    log_ok "配置文件已更新"
    
    log_info "重启 Snell 服务..."
    systemctl restart snell
    sleep 2
    
    if systemctl is-active --quiet snell; then
        log_ok "IPv6 已设置为 ${new_ipv6}"
        log_ok "监听地址已更新为 ${new_listen_prefix}:${current_port}"
    else
        log_err "服务异常,正在回滚..."
        set_snell_config_key "ipv6" "$old_ipv6"
        update_listen_for_ipv6 "$old_ipv6"
        systemctl restart snell
        log_warn "已回滚到原配置,请查看日志: journalctl -u snell -n 30"
    fi
    echo
}

change_dns() {
    local old_dns
    old_dns=$(get_snell_config_value "dns")
    
    echo
    echo "============================================"
    echo -e "${CYAN}修改 DNS 设置${NC}"
    echo "============================================"
    echo
    echo -e "当前 DNS: ${YELLOW}${old_dns:-未配置(使用系统默认)}${NC}"
    echo
    echo "请输入新的 DNS 服务器:"
    echo "  - 多个 DNS 用逗号分隔(如: 1.1.1.1, 8.8.8.8)"
    echo "  - 输入 'clear' 清除 DNS 配置"
    echo "  - 直接回车取消"
    read -p "新 DNS: " new_dns
    
    if [[ -z "$new_dns" ]]; then
        log_info "已取消修改"
        return
    fi
    
    backup_conf
    
    if [[ "$new_dns" == "clear" ]]; then
        comment_snell_config_key "dns"
        # 如果之前没有 dns 行,也确保有一行注释
        if ! grep -qE "^#[[:space:]]*dns[[:space:]]*=" "$SNELL_CONF"; then
            echo "# dns = 1.1.1.1, 8.8.8.8" >> "$SNELL_CONF"
        fi
        log_ok "已注释 DNS 配置,Snell 将使用系统默认 DNS"
    else
        new_dns=$(echo "$new_dns" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        
        if [[ "$new_dns" == "$old_dns" ]]; then
            log_warn "新 DNS 与当前相同,无需修改"
            return
        fi
        
        # 如果原本是注释状态,先取消注释,然后赋值
        uncomment_snell_config_key "dns" "$new_dns"
        # 再确保值正确
        set_snell_config_key "dns" "$new_dns"
        log_ok "DNS 已设置为: $new_dns"
    fi
    
    log_info "重启 Snell 服务..."
    systemctl restart snell
    sleep 2
    
    if systemctl is-active --quiet snell; then
        log_ok "DNS 修改完成"
    else
        log_err "服务异常,查看日志:"
        journalctl -u snell -n 20 --no-pager
    fi
    echo
}

uninstall_snell() {
    echo
    log_warn "即将卸载 Snell"
    echo "将执行以下操作:"
    echo "  - 停止并禁用 snell 服务"
    echo "  - 删除 $SNELL_DIR"
    echo "  - 删除 $SNELL_SERVICE"
    echo
    echo "以下内容会保留:"
    echo "  - BBR 内核参数(对系统其他服务也有益)"
    echo "  - 云厂商安全组规则(需自行删除)"
    echo
    read -p "确认卸载?(输入 yes 确认): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log_info "已取消卸载"
        return
    fi
    
    local port
    port=$(get_snell_port)
    
    log_info "停止服务..."
    systemctl stop snell 2>/dev/null || true
    systemctl disable snell 2>/dev/null || true
    
    log_info "删除文件..."
    rm -f "$SNELL_SERVICE"
    rm -rf "$SNELL_DIR"
    systemctl daemon-reload
    
    echo
    log_ok "Snell 已成功卸载"
    log_warn "请记得手动删除云厂商安全组里的 ${port:-端口} 入站规则"
    echo
}

install_snell() {
    echo
    echo "============================================"
    echo -e "${CYAN}开始安装 Snell ${SNELL_MAJOR_VERSION}${NC}"
    echo "============================================"
    
    local os_type
    os_type=$(detect_os)
    local os_name
    os_name=$(get_os_pretty_name)
    
    if [[ "$os_type" == "ubuntu" || "$os_type" == "debian" ]]; then
        log_ok "检测到系统: ${os_name}(${os_type})"
    else
        log_warn "本脚本针对 Ubuntu / Debian 设计"
        log_warn "当前系统: ${os_name}"
        if ! ask_yes_no "继续吗?" "n"; then
            exit 0
        fi
    fi
    
    local snell_arch
    snell_arch=$(detect_arch)
    if [[ -z "$snell_arch" ]]; then
        log_err "不支持的系统架构: $(uname -m)"
        exit 1
    fi
    log_ok "检测到架构: $(uname -m) → 使用 $snell_arch 安装包"
    
    # 端口(必填)
    local port=""
    while true; do
        echo
        read -p "请输入 Snell 监听端口(1024-65535): " port
        
        validate_port "$port" "yes"
        local result=$?
        
        if [[ $result -eq 0 ]]; then
            break
        elif [[ $result -eq 2 ]]; then
            if ask_yes_no "仍要使用此端口吗?" "n"; then
                break
            fi
        fi
    done
    log_ok "使用端口: $port"
    
    # PSK
    echo
    echo "请输入 PSK(预共享密钥)"
    echo "  - 直接回车将自动生成 31 位随机 PSK"
    echo "  - 也可以输入自定义 PSK(建议至少 16 字符)"
    read -p "PSK: " psk
    
    if [[ -z "$psk" ]]; then
        log_info "自动生成 PSK..."
        psk=$(generate_psk)
        log_ok "PSK 已生成: $psk"
    else
        log_ok "使用自定义 PSK"
    fi
    
    # IPv6
    echo
    echo "是否启用 IPv6?"
    echo "  - 启用后 listen 地址使用 ::0(双栈监听)"
    echo "  - 启用前请确保 VPS 支持 IPv6"
    local ipv6
    if ask_yes_no "启用 IPv6?" "n"; then
        ipv6="true"
        log_ok "IPv6: 已启用(listen 将使用 ::0)"
    else
        ipv6="false"
        log_ok "IPv6: 已禁用(listen 将使用 0.0.0.0)"
    fi
    
    # DNS
    echo
    echo "是否配置自定义 DNS?"
    echo "  - 推荐使用 1.1.1.1, 8.8.8.8 等稳定 DNS"
    echo "  - 不配置则使用系统默认 DNS"
    local dns
    if ask_yes_no "配置自定义 DNS?" "n"; then
        echo
        echo "请输入 DNS 服务器(多个用逗号分隔,直接回车使用默认: 1.1.1.1, 8.8.8.8)"
        read -p "DNS: " dns
        if [[ -z "$dns" ]]; then
            dns="1.1.1.1, 8.8.8.8"
        else
            dns=$(echo "$dns" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        fi
        log_ok "DNS: $dns"
    else
        dns=""
        log_ok "DNS: 已注释(使用系统默认)"
    fi
    
    # 依赖
    echo
    log_info "安装依赖工具..."
    export DEBIAN_FRONTEND=noninteractive
    apt update -qq
    apt install -y -qq wget unzip curl ca-certificates iproute2 >/dev/null
    log_ok "依赖已就绪"
    
    # 下载
    log_info "下载 Snell ${SNELL_VERSION}..."
    mkdir -p "$SNELL_DIR"
    cd "$SNELL_DIR"
    local download_url="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${snell_arch}.zip"
    local zip_file="snell-server-${SNELL_VERSION}-linux-${snell_arch}.zip"
    
    if ! wget -q --show-progress "$download_url"; then
        log_err "下载失败,请检查网络: $download_url"
        exit 1
    fi
    
    unzip -oq "$zip_file"
    chmod +x snell-server
    rm "$zip_file"
    log_ok "Snell 已安装到 $SNELL_BIN"
    
    # 配置文件
    log_info "创建配置文件..."
    write_snell_conf "$port" "$psk" "$ipv6" "$dns"
    log_ok "配置文件已创建: $SNELL_CONF"
    
    # systemd
    log_info "创建 systemd 服务..."
    cat > "$SNELL_SERVICE" <<EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=${SNELL_BIN} -c ${SNELL_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
    log_ok "systemd 服务已创建"
    
    # BBR
    echo
    log_info "检查 BBR 状态..."
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [[ "$current_cc" == "bbr" ]]; then
        log_ok "BBR 已启用,跳过"
    else
        log_info "启用 BBR..."
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null
        
        local new_cc
        new_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
        if [[ "$new_cc" == "bbr" ]]; then
            log_ok "BBR 已启用"
        else
            log_warn "BBR 启用失败,当前算法: $new_cc (可能内核版本过低)"
        fi
    fi
    
    # 启动
    log_info "启动 Snell 服务..."
    systemctl daemon-reload
    systemctl enable snell >/dev/null 2>&1
    systemctl restart snell
    
    sleep 2
    
    if ! systemctl is-active --quiet snell; then
        log_err "Snell 服务启动失败,查看日志:"
        journalctl -u snell -n 20 --no-pager
        exit 1
    fi
    log_ok "Snell 服务运行中"
    
    if ! ss -tunlp | grep -q ":${port} "; then
        log_err "端口 ${port} 未监听"
        exit 1
    fi
    log_ok "端口 ${port} 正在监听"
    
    local public_ip listen_prefix
    public_ip=$(get_public_ip)
    listen_prefix=$(get_listen_prefix "$ipv6")
    
    echo
    echo "============================================"
    log_ok "Snell ${SNELL_MAJOR_VERSION} 部署成功 🎉"
    echo "============================================"
    echo
    echo -e "${GREEN}服务器信息:${NC}"
    echo "  IP 地址:    ${public_ip}"
    echo "  端口:       ${port}"
    echo "  PSK:        ${psk}"
    echo "  协议版本:    ${SNELL_MAJOR_VERSION}"
    echo
    echo -e "${GREEN}其他配置:${NC}"
    echo "  监听地址:    ${listen_prefix}:${port}"
    echo "  IPv6:       ${ipv6}"
    echo "  DNS:        ${dns:-(已注释,使用系统默认)}"
    echo
    echo -e "${YELLOW}重要提醒:${NC}"
    echo "  1. 请在云厂商控制台的安全组中放行 ${port} 端口的 TCP 和 UDP"
    echo "  2. 配置文件位置: ${SNELL_CONF}"
    echo
    echo "============================================"
}

# ==================== 主流程 ====================

main() {
    echo
    echo "============================================"
    echo -e "${CYAN}     Snell ${SNELL_MAJOR_VERSION} 管理脚本(Ubuntu / Debian)${NC}"
    echo "============================================"
    
    if is_snell_installed; then
        local status_text
        if systemctl is-active --quiet snell 2>/dev/null; then
            status_text="${GREEN}● 运行中${NC}"
        else
            status_text="${RED}● 未运行${NC}"
        fi
        
        echo
        echo -e "检测到 Snell 已安装  状态: ${status_text}"
        echo
        echo "请选择操作:"
        echo "  1) 查看配置信息"
        echo "  2) 查看管理命令"
        echo "  3) 重启 Snell 服务"
        echo "  4) 修改监听端口"
        echo "  5) 修改 PSK"
        echo "  6) 修改 IPv6 设置"
        echo "  7) 修改 DNS 设置"
        echo "  8) 卸载 Snell"
        echo "  0) 退出"
        echo
        
        local choice
        read -p "请输入选项 [0-8]: " choice
        
        case "$choice" in
            1) show_config ;;
            2) show_commands ;;
            3) restart_snell ;;
            4) change_port ;;
            5) change_psk ;;
            6) change_ipv6 ;;
            7) change_dns ;;
            8) uninstall_snell ;;
            0) log_info "已退出" ;;
            *) log_err "无效选项: $choice"; exit 1 ;;
        esac
    else
        echo
        log_info "检测到 Snell 尚未安装"
        echo
        if ask_yes_no "是否开始安装?" "n"; then
            install_snell
        else
            log_info "已取消安装"
        fi
    fi
}

main "$@"
