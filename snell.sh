#!/bin/bash
#
# Snell 交互式管理脚本(Ubuntu / Debian)
# 功能:安装 / 查看配置 / 查看管理命令 / 修改端口 / 修改 PSK / 卸载
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

# 必须 root
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

# 读取端口:取最后一个 ':' 之后的内容(兼容 IPv6 监听地址)
get_snell_port() {
    if [[ -f "$SNELL_CONF" ]]; then
        awk '/^listen[[:space:]]*=/ {
            # 找最后一个冒号的位置,取其后内容
            n = split($0, parts, ":")
            gsub(/[[:space:]]/, "", parts[n])
            print parts[n]
        }' "$SNELL_CONF"
    fi
}

# 读取 PSK:只在第一个 '=' 处切分,保留 PSK 中的所有 '='
get_snell_psk() {
    if [[ -f "$SNELL_CONF" ]]; then
        awk '/^psk[[:space:]]*=/ {
            # 移除行首的 "psk" + 任意空格 + 第一个 = + 任意空格
            sub(/^[^=]*=[[:space:]]*/, "")
            # 移除末尾的空白
            sub(/[[:space:]]+$/, "")
            print
        }' "$SNELL_CONF"
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

# ==================== 功能模块 ====================

show_config() {
    echo
    echo "============================================"
    echo -e "${CYAN}Snell 配置信息${NC}"
    echo "============================================"
    
    local port psk public_ip
    port=$(get_snell_port)
    psk=$(get_snell_psk)
    public_ip=$(get_public_ip)
    
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
    echo -e "${GREEN}配置修改:${NC}"
    echo "  编辑配置:        nano $SNELL_CONF"
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
            read -p "仍要使用此端口吗?(y/N): " confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && continue
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
    read -p "确认修改?(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { log_info "已取消"; return; }
    
    cp "$SNELL_CONF" "${SNELL_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    log_ok "配置文件已备份"
    
    sed -i "s/^listen\s*=.*/listen = 0.0.0.0:${new_port}/" "$SNELL_CONF"
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
        sed -i "s/^listen\s*=.*/listen = 0.0.0.0:${old_port}/" "$SNELL_CONF"
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
    echo "  - 直接回车将自动生成 64 位强随机 PSK(推荐)"
    echo "  - 输入 'q' 取消"
    read -p "新 PSK: " new_psk
    
    if [[ "$new_psk" == "q" || "$new_psk" == "Q" ]]; then
        log_info "已取消修改"
        return
    fi
    
    if [[ -z "$new_psk" ]]; then
        new_psk=$(openssl rand -hex 32)
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
    read -p "确认修改?(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { log_info "已取消"; return; }
    
    cp "$SNELL_CONF" "${SNELL_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    log_ok "配置文件已备份"
    
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
        read -p "继续吗?(y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0
    fi
    
    local snell_arch
    snell_arch=$(detect_arch)
    if [[ -z "$snell_arch" ]]; then
        log_err "不支持的系统架构: $(uname -m)"
        exit 1
    fi
    log_ok "检测到架构: $(uname -m) → 使用 $snell_arch 安装包"
    
    # 端口
    local port=""
    while true; do
        echo
        read -p "请输入 Snell 监听端口(1024-65535): " port
        
        validate_port "$port" "yes"
        local result=$?
        
        if [[ $result -eq 0 ]]; then
            break
        elif [[ $result -eq 2 ]]; then
            read -p "仍要使用此端口吗?(y/N): " confirm
            [[ "$confirm" == "y" || "$confirm" == "Y" ]] && break
        fi
    done
    log_ok "使用端口: $port"
    
    # PSK
    echo
    echo "请输入 PSK(预共享密钥)"
    echo "  - 直接回车将自动生成 64 位强随机 PSK(推荐)"
    echo "  - 也可以输入自定义 PSK(建议至少 16 字符)"
    read -p "PSK: " psk
    
    if [[ -z "$psk" ]]; then
        log_info "自动生成 PSK..."
        psk=$(openssl rand -hex 32)
        log_ok "PSK 已生成: $psk"
    else
        log_ok "使用自定义 PSK"
    fi
    
    # 依赖
    echo
    log_info "安装依赖工具..."
    export DEBIAN_FRONTEND=noninteractive
    apt update -qq
    apt install -y -qq wget unzip openssl curl ca-certificates iproute2 >/dev/null
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
    cat > "$SNELL_CONF" <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = false
EOF
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
StandardOutput=syslog
StandardError=syslog
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
    
    local public_ip
    public_ip=$(get_public_ip)
    
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
    echo -e "${YELLOW}重要提醒:${NC}"
    echo "  1. 请在云厂商控制台的安全组中放行 ${port} 端口的 TCP 和 UDP"
    echo "  2. 配置文件位置: ${SNELL_CONF}"
    echo "  3. 重新运行本脚本可管理服务"
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
        echo "  1) 查看配置文件路径和连接信息"
        echo "  2) 查看服务管理命令"
        echo "  3) 修改监听端口"
        echo "  4) 修改 PSK"
        echo "  5) 卸载 Snell"
        echo "  0) 退出"
        echo
        
        local choice
        read -p "请输入选项 [0-5]: " choice
        
        case "$choice" in
            1) show_config ;;
            2) show_commands ;;
            3) change_port ;;
            4) change_psk ;;
            5) uninstall_snell ;;
            0) log_info "已退出" ;;
            *) log_err "无效选项: $choice"; exit 1 ;;
        esac
    else
        echo
        log_info "检测到 Snell 尚未安装"
        echo
        read -p "是否开始安装?(y/N): " confirm
        
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            install_snell
        else
            log_info "已取消安装"
        fi
    fi
}

main "$@"