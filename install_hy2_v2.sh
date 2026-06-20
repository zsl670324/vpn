#!/usr/bin/env bash
set -e
# ============================================================
# Hysteria2 一键安装脚本 (基于 sing-box) - 修复版 v2
# 修复了 nginx 配置目录不存在的问题
# ============================================================
# ---- 颜色定义 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
# ---- 全局变量 ----
SING_BOX_VERSION="${SING_BOX_VERSION:-v1.13.0}"
HY2_PORT=""
HY2_PASSWORD=""
HY2_OBFS_PASSWORD=""
HY2_SNI=""
SERVER_IP=""
INSTALL_DIR="/etc/sing-box"
CONFIG_FILE="${INSTALL_DIR}/config.json"
CERT_FILE="${INSTALL_DIR}/cert.pem"
KEY_FILE="${INSTALL_DIR}/key.pem"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
BINARY="/usr/local/bin/sing-box"
DOMAIN=""
USE_LE_CERT=false
INSECURE_FLAG=1
# ---- 打印函数 ----
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header(){ echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
safe_read() {
    if ! read -p "$1" "$2"; then
        echo ""
        error "用户中断输入"
    fi
}
# ---- 检查 root ----
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 用户运行此脚本"
    fi
}
# ---- 获取公网 IP ----
get_server_ip() {
    SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -s4 --max-time 5 https://icanhazip.com 2>/dev/null || \
                curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || \
                curl -s4 --max-time 5 https://checkip.amazonaws.com 2>/dev/null || \
                hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(ip route get 1 | awk '{print $NF;exit}' 2>/dev/null)
    fi
    if [[ -z "$SERVER_IP" ]]; then
        error "无法获取服务器 IP 地址，请手动设置"
    fi
}
# ---- 检测系统 ----
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION="${VERSION_ID:-}"
    else
        OS=$(uname -s)
    fi
    info "检测到系统: ${OS} ${OS_VERSION}"
}
# ---- 安装依赖 ----
install_deps() {
    info "安装系统依赖..."
    case "$OS" in
        ubuntu|debian|kali)
            apt-get update -qq
            apt-get install -y -qq curl wget openssl qrencode tar gzip systemd iproute2 jq nginx
            ;;
        centos|rhel|fedora|almalinux|rocky)
            if command -v dnf &>/dev/null; then
                dnf install -y curl wget openssl qrencode tar gzip systemd iproute jq nginx
            else
                yum install -y curl wget openssl qrencode tar gzip systemd net-tools jq nginx
            fi
            ;;
        arch|manjaro)
            pacman -Syu --noconfirm curl wget openssl qrencode tar gzip systemd iproute2 jq nginx
            ;;
        alpine)
            apk add curl wget openssl qrencode tar gzip iproute2 jq nginx
            ;;
        *)
            warn "未知系统: $OS，尝试使用 apt-get 安装依赖..."
            apt-get update -qq && apt-get install -y -qq curl wget openssl qrencode tar gzip systemd jq nginx || true
            ;;
    esac
    info "依赖安装完成"
}
# ---- 确保 nginx 目录存在 ----
ensure_nginx_dirs() {
    info "检查并创建 nginx 目录..."
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled

    # 检查主配置文件是否包含 sites-enabled
    if ! grep -q "include /etc/nginx/sites-enabled/\*" /etc/nginx/nginx.conf 2>/dev/null; then
        info "添加 sites-enabled 包含到 nginx 主配置..."
        sed -i '/http {/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf 2>/dev/null || true
    fi
    info "nginx 目录检查完成"
}
# ---- 确保 python3 可用 ----
ensure_python3() {
    if ! command -v python3 &>/dev/null; then
        info "安装 python3..."
        case "$OS" in
            ubuntu|debian|kali)
                apt-get install -y -qq python3
                ;;
            centos|rhel|fedora|almalinux|rocky)
                if command -v dnf &>/dev/null; then
                    dnf install -y python3
                else
                    yum install -y python3
                fi
                ;;
            arch|manjaro)
                pacman -Syu --noconfirm python3
                ;;
            alpine)
                apk add python3
                ;;
            *)
                apt-get install -y -qq python3 || true
                ;;
        esac
    fi
    if ! command -v python3 &>/dev/null; then
        error "python3 安装失败，无法继续"
    fi
}
# ---- 开启 BBR ----
enable_bbr() {
    info "优化网络参数 (开启 BBR + QUIC/UDP 游戏加速)..."
    sed -i '/# Hysteria2 网络优化/,+14d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/# Hysteria2 QUIC 优化/,+8d' /etc/sysctl.conf 2>/dev/null || true

    cat >> /etc/sysctl.conf <<-EOF
# Hysteria2 网络优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.netdev_max_backlog = 20000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
# Hysteria2 QUIC 优化
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.core.rmem_default = 26214400
net.core.wmem_default = 26214400
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ipfrag_high_thresh = 5242880
net.ipv4.ipfrag_low_thresh = 3145728
net.ipv4.ipfrag_time = 30
fs.file-max = 1048576
EOF

    sysctl -p 2>/dev/null || true
    info "网络优化参数已写入"
}
# ---- 安装 sing-box ----
install_sing_box() {
    if [[ -x "$BINARY" ]]; then
        local current_ver
        current_ver=$("${BINARY}" version 2>&1 | head -n1)
        info "sing-box 已安装: ${current_ver}"
        safe_read "$(echo -e "${YELLOW}是否重新安装? [y/N]: ${NC}")" reinstall
        if [[ ! "$reinstall" =~ ^[yY]$ ]]; then
            info "跳过安装，使用现有版本"
            return
        fi
        info "正在重新安装..."
    fi

    local VER="${SING_BOX_VERSION}"
    info "使用 sing-box 版本: ${VER}"
    local ARCH
    case $(uname -m) in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv8l) ARCH="armv7" ;;
        i386|i686)     ARCH="386" ;;
        *) error "不支持的架构: $(uname -m)" ;;
    esac
    local VER_NO_V="${VER#v}"
    local TAR_FILE="sing-box-${VER_NO_V}-linux-${ARCH}.tar.gz"
    local DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${VER}/${TAR_FILE}"

    local orig_dir
    orig_dir=$(pwd)

    (
        cd /tmp || error "无法进入 /tmp 目录"
        if wget -q --timeout=30 --tries=3 -O "${TAR_FILE}" "${DOWNLOAD_URL}"; then
            info "GitHub 直连下载成功"
        elif wget -q --timeout=30 --tries=3 -O "${TAR_FILE}" "https://ghproxy.net/${DOWNLOAD_URL}"; then
            info "通过 ghproxy.net 代理下载成功"
        else
            error "sing-box 下载失败"
        fi

        local EXTRACTED_DIR
        EXTRACTED_DIR=$(tar tzf "${TAR_FILE}" 2>/dev/null | head -1 | cut -d/ -f1)
        if [[ -z "$EXTRACTED_DIR" ]]; then
            error "无法从 tar 文件中提取目录信息"
        fi

        tar xzf "${TAR_FILE}" || error "解压 tar 文件失败"
        cp "${EXTRACTED_DIR}/sing-box" "${BINARY}" || error "复制二进制文件失败"
        chmod +x "${BINARY}"
        rm -rf "${EXTRACTED_DIR}" "${TAR_FILE}"
    )

    if [[ ! -x "${BINARY}" ]]; then
        error "sing-box 安装失败，二进制文件不存在"
    fi

    info "sing-box 安装完成: $(${BINARY} version 2>&1 | head -n1)"
}
# ---- 生成自签名证书 ----
generate_cert() {
    mkdir -p "$INSTALL_DIR"
    if [[ "$USE_LE_CERT" == "true" && -n "$DOMAIN" ]]; then
        request_le_cert
        return
    fi
    info "生成自签名 TLS 证书..."
    local CERT_CN="${DOMAIN:-$SERVER_IP}"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${KEY_FILE}" \
        -out "${CERT_FILE}" \
        -subj "/CN=${CERT_CN}/O=Hysteria2" \
        -days 825 || error "自签名证书生成失败"
    chmod 600 "${KEY_FILE}"
    chmod 644 "${CERT_FILE}"
    info "自签名证书已生成 (CN=${CERT_CN})"
}
# ---- 申请 Let's Encrypt 证书 ----
request_le_cert() {
    info "开始申请 Let's Encrypt 证书 (域名: ${DOMAIN})..."
    # 检查端口占用
    local port80_in_use=false
    local stopped_services=""
    if ss -tlnp 2>/dev/null | grep -qE ':80\s'; then
        port80_in_use=true
    fi
    if [[ "$port80_in_use" == "true" ]]; then
        warn "端口 80 被占用"
        safe_read "$(echo -e "${YELLOW}是否自动停止占用 80 端口的服务? [y/N]: ${NC}")" stop_services
        if [[ "$stop_services" =~ ^[yY]$ ]]; then
            for svc in nginx apache2 httpd caddy; do
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    systemctl stop "$svc" 2>/dev/null || true
                    stopped_services="${stopped_services} ${svc}"
                fi
            done
        fi
    fi

    # 安装 acme.sh
    if ! command -v acme.sh &>/dev/null; then
        info "安装 acme.sh..."
        curl -sSL https://get.acme.sh | sh -s -- --accountemail "admin@${DOMAIN}" 2>/dev/null || \
            error "acme.sh 安装失败"
        export PATH="$HOME/.acme.sh:$PATH"
    fi

    info "正在申请证书..."
    local acme_bin="$HOME/.acme.sh/acme.sh"
    [[ ! -x "$acme_bin" ]] && acme_bin="/root/.acme.sh/acme.sh"
    [[ ! -x "$acme_bin" ]] && acme_bin="$(which acme.sh 2>/dev/null)"

    if [[ ! -x "$acme_bin" ]]; then
        error "找不到 acme.sh 可执行文件"
    fi

    if "$acme_bin" --issue -d "$DOMAIN" --standalone --keylength ec-256 --force 2>/dev/null; then
        info "Let's Encrypt 证书申请成功!"
        "$acme_bin" --install-cert -d "$DOMAIN" \
            --cert-file "${CERT_FILE}" \
            --key-file "${KEY_FILE}" \
            --fullchain-file "${CERT_FILE}" \
            --reloadcmd "systemctl restart sing-box" 2>/dev/null || true
        chmod 600 "${KEY_FILE}"
        chmod 644 "${CERT_FILE}"
        info "证书已安装到: ${CERT_FILE}"
    else
        warn "Let's Encrypt 证书申请失败，回退到自签名证书..."
        USE_LE_CERT=false
        INSECURE_FLAG=1
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "${KEY_FILE}" \
            -out "${CERT_FILE}" \
            -subj "/CN=${DOMAIN}/O=Hysteria2" \
            -days 825 || error "回退自签名证书生成失败"
        chmod 600 "${KEY_FILE}"
        chmod 644 "${CERT_FILE}"
        info "自签名证书已生成"
    fi

    # 恢复服务
    for svc in $stopped_services; do
        systemctl start "$svc" 2>/dev/null || true
    done
}
# ---- 生成随机密码 ----
gen_password() {
    while true; do
        local pwd
        pwd=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)
        if [[ ${#pwd} -eq 32 ]]; then
            echo "$pwd"
            return
        fi
    done
}
# ---- JSON 转义 ----
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$/\\\$}"
    s="${s//\`/\\\`}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    echo "$s"
}
# ---- 交互式配置 ----
interactive_config() {
    header
    echo -e "${BLUE}  Hysteria2 一键安装脚本 (修复版 v2)${NC}"
    echo -e "${BLUE}  基于 sing-box | 支持游戏加速${NC}"
    header
    echo ""
    safe_read "$(echo -e "${YELLOW}请输入 Hysteria2 监听端口 [默认: 443]: ${NC}")" input_port
    HY2_PORT="${input_port:-443}"
    if [[ ! "$HY2_PORT" =~ ^[0-9]+$ || "$HY2_PORT" -lt 1 || "$HY2_PORT" -gt 65535 ]]; then
        error "端口无效"
    fi
    if ss -ulnp 2>/dev/null | grep -qE ":${HY2_PORT}\s"; then
        warn "端口 ${HY2_PORT} 已被其他服务占用!"
        safe_read "$(echo -e "${YELLOW}是否继续? (可能导致冲突) [y/N]: ${NC}")" port_continue
        if [[ ! "$port_continue" =~ ^[yY]$ ]]; then
            error "安装已取消"
        fi
    fi

    local default_pwd
    default_pwd=$(gen_password)
    safe_read "$(echo -e "${YELLOW}请输入认证密码 [默认随机: ${default_pwd}]: ${NC}")" input_pwd
    HY2_PASSWORD="${input_pwd:-$default_pwd}"

    local default_obfs
    default_obfs=$(gen_password)
    safe_read "$(echo -e "${YELLOW}请输入 Salamander 混淆密码 [默认随机: ${default_obfs}]: ${NC}")" input_obfs
    HY2_OBFS_PASSWORD="${input_obfs:-$default_obfs}"

    safe_read "$(echo -e "${YELLOW}请输入伪装域名/SNI [默认: www.apple.com]: ${NC}")" input_sni
    HY2_SNI="${input_sni:-www.apple.com}"

    safe_read "$(echo -e "${YELLOW}是否拥有域名并已解析到本机? [y/N]: ${NC}")" use_domain
    if [[ "$use_domain" =~ ^[yY] ]]; then
        safe_read "$(echo -e "${YELLOW}请输入您的域名: ${NC}")" DOMAIN
        if [[ -n "$DOMAIN" ]]; then
            if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$ ]]; then
                error "域名格式无效"
            fi
            safe_read "$(echo -e "${YELLOW}是否一键申请 Let's Encrypt 免费证书? [Y/n]: ${NC}")" use_le
            if [[ "$use_le" =~ ^[nN]$ ]]; then
                USE_LE_CERT=false
                INSECURE_FLAG=1
            else
                USE_LE_CERT=true
                INSECURE_FLAG=0
            fi
            if [[ "$HY2_SNI" == "www.apple.com" ]]; then
                HY2_SNI="$DOMAIN"
            fi
        else
            DOMAIN=""
        fi
    fi

    header
    echo -e "${GREEN}配置摘要:${NC}"
    echo -e "  端口:        ${HY2_PORT}"
    echo -e "  密码:        ${HY2_PASSWORD}"
    echo -e "  混淆密码:    ${HY2_OBFS_PASSWORD}"
    echo -e "  SNI:         ${HY2_SNI}"
    echo -e "  证书域名:    ${DOMAIN:-自签名 (IP: ${SERVER_IP})}"
    local cert_type="自签名"
    if [[ "$USE_LE_CERT" == "true" ]]; then cert_type="Let's Encrypt"; fi
    echo -e "  证书类型:    ${cert_type}"
    header
    echo ""
}
# ---- 生成 sing-box 配置文件 ----
generate_config() {
    info "生成 sing-box 配置文件..."
    mkdir -p "$INSTALL_DIR"
    local json_pwd
    local json_obfs_pwd
    local json_sni
    json_pwd=$(json_escape "${HY2_PASSWORD}")
    json_obfs_pwd=$(json_escape "${HY2_OBFS_PASSWORD}")
    json_sni=$(json_escape "${HY2_SNI}")

    jq -n \
        --arg pwd "$json_pwd" \
        --arg obfs "$json_obfs_pwd" \
        --arg cert "$CERT_FILE" \
        --arg key "$KEY_FILE" \
        --argjson port "$HY2_PORT" \
        --arg sni "$json_sni" \
        '{
            log: { level: "warn", output: "/etc/sing-box/sing-box.log", timestamp: true },
            inbounds: [{
                type: "hysteria2",
                tag: "hy2-in",
                listen: "::",
                listen_port: $port,
                users: [{ name: "game", password: $pwd }],
                ignore_client_bandwidth: true,
                obfs: { type: "salamander", password: $obfs },
                tls: { enabled: true, alpn: ["h3"], certificate_path: $cert, key_path: $key }
            }],
            outbounds: [{ type: "direct", tag: "direct" }]
        }' > "$CONFIG_FILE" || error "生成配置文件失败"

    info "配置文件生成完毕: ${CONFIG_FILE}"
}
# ---- 创建 systemd 服务 ----
create_service() {
    if [[ "$OS" == "alpine" ]]; then
        warn "Alpine 使用 OpenRC, 跳过 systemd 服务创建"
        return
    fi
    info "创建 systemd 服务..."
    cat > "$SERVICE_FILE" <<-EOF
[Unit]
Description=sing-box (Hysteria2) - Universal Proxy Platform
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart=${BINARY} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
LimitNPROC=65536
LimitAS=infinity
LimitMEMLOCK=infinity
TasksMax=infinity
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sing-box
Nice=-10
CPUSchedulingPolicy=rr
CPUSchedulingPriority=50
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    info "systemd 服务创建完毕"
}
# ---- 配置防火墙 ----
config_firewall() {
    info "配置防火墙规则..."
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${HY2_PORT}/udp"
        info "ufw: 已开放端口 ${HY2_PORT}/udp"
        if [[ -n "$DOMAIN" ]]; then
            ufw allow 80/tcp 2>/dev/null || true
            ufw allow 443/tcp 2>/dev/null || true
        fi
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        firewall-cmd --zone=public --add-port="${HY2_PORT}/udp" --permanent
        if [[ -n "$DOMAIN" ]]; then
            firewall-cmd --zone=public --add-port="80/tcp" --permanent 2>/dev/null || true
            firewall-cmd --zone=public --add-port="443/tcp" --permanent 2>/dev/null || true
        fi
        firewall-cmd --reload
    fi
    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p udp --dport "$HY2_PORT" -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p udp --dport "$HY2_PORT" -j ACCEPT
        if [[ -n "$DOMAIN" ]]; then
            iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
                iptables -A INPUT -p tcp --dport 80 -j ACCEPT
            iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
                iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        fi
    fi
}
# ---- 生成客户端 URI ----
generate_uri() {
    local domain_part="${DOMAIN:-$SERVER_IP}"
    local encoded_pwd
    local encoded_obfs_pwd
    encoded_pwd=$(HY2_PWD="${HY2_PASSWORD}" python3 -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['HY2_PWD'], safe=''))" 2>/dev/null || echo "${HY2_PASSWORD}")
    encoded_obfs_pwd=$(HY2_PWD="${HY2_OBFS_PASSWORD}" python3 -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['HY2_PWD'], safe=''))" 2>/dev/null || echo "${HY2_OBFS_PASSWORD}")
    local encoded_sni
    encoded_sni=$(HY2_SNI="${HY2_SNI}" python3 -c "import os,urllib.parse; print(urllib.parse.quote(os.environ['HY2_SNI'], safe=''))" 2>/dev/null || echo "${HY2_SNI}")
    CLIENT_URI="hysteria2://${encoded_pwd}@${domain_part}:${HY2_PORT}?obfs=salamander&obfs-password=${encoded_obfs_pwd}&sni=${encoded_sni}&insecure=${INSECURE_FLAG}#Hy2-Game-${SERVER_IP}"
    echo "$CLIENT_URI" > "${INSTALL_DIR}/client_uri.txt"
    info "客户端 URI 已保存: ${INSTALL_DIR}/client_uri.txt"
}
# ---- 生成二维码 ----
generate_qrcode() {
    info "生成客户端二维码..."
    echo ""
    header
    echo -e "${GREEN}  客户端连接 URI:${NC}"
    echo -e "${CYAN}  ${CLIENT_URI}${NC}"
    header
    echo ""
    if command -v qrencode &>/dev/null; then
        echo -e "${GREEN}  扫描以下二维码导入客户端:${NC}"
        echo ""
        qrencode -t ANSIUTF8 "${CLIENT_URI}"
        echo ""
        qrencode -o "${INSTALL_DIR}/hy2_qrcode.png" "${CLIENT_URI}" 2>/dev/null || true
        info "二维码图片已保存: ${INSTALL_DIR}/hy2_qrcode.png"
    else
        warn "未安装 qrencode，无法显示二维码"
        info "请手动复制上面的 URI 到客户端中使用"
    fi
}
# ---- 启动服务 ----
start_service() {
    info "启动 sing-box 服务..."
    ${BINARY} check -c "$CONFIG_FILE" || error "配置文件检查失败!"
    if [[ "$OS" == "alpine" ]]; then
        nohup ${BINARY} run -c "$CONFIG_FILE" > "${INSTALL_DIR}/sing-box.log" 2>&1 &
        info "sing-box 已在后台启动 (Alpine/OpenRC)"
        return
    fi
    systemctl enable sing-box
    systemctl restart sing-box
    sleep 2
    if systemctl is-active --quiet sing-box; then
        info "sing-box 服务运行正常"
    else
        warn "服务状态异常，检查日志: journalctl -u sing-box -n 50 --no-pager"
    fi
}
# ---- 配置客户端 sing-box ----
generate_client_config() {
    local client_dir="${INSTALL_DIR}/client"
    mkdir -p "$client_dir"
    local domain_part="${DOMAIN:-$SERVER_IP}"
    local json_pwd
    local json_obfs_pwd
    local json_sni
    json_pwd=$(json_escape "${HY2_PASSWORD}")
    json_obfs_pwd=$(json_escape "${HY2_OBFS_PASSWORD}")
    json_sni=$(json_escape "${HY2_SNI}")

    jq -n \
        --arg pwd "$json_pwd" \
        --arg obfs "$json_obfs_pwd" \
        --arg server "$domain_part" \
        --argjson port "$HY2_PORT" \
        --arg sni "$json_sni" \
        --argjson insecure "$INSECURE_FLAG" \
        '{
            log: { level: "info" },
            inbounds: [
                { type: "tun", tag: "tun-in", interface_name: "sing-tun", inet4_address: "172.19.0.1/30", mtu: 1420, auto_route: true, strict_route: false },
                { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 1080 }
            ],
            outbounds: [
                {
                    type: "hysteria2",
                    tag: "hy2-out",
                    server: $server,
                    server_port: $port,
                    password: $pwd,
                    obfs: { type: "salamander", password: $obfs },
                    tls: { enabled: true, server_name: $sni, insecure: $insecure, alpn: ["h3"] }
                }
            ],
            route: { final: "hy2-out", auto_detect_interface: true }
        }' > "${client_dir}/client-config.json" || error "生成客户端配置失败"

    info "客户端配置已生成: ${client_dir}/client-config.json"
}
# ---- 搭建伪装网站 ----
setup_camouflage_site() {
    if [[ -z "$DOMAIN" ]]; then
        info "未使用域名，跳过伪装网站搭建"
        return
    fi
    info "搭建伪装网站 (域名: ${DOMAIN})..."
    local WEB_DIR="/var/www/camouflage"
    local NGINX_CONF="/etc/nginx/sites-available/camouflage"

    # 确保 nginx 目录存在
    ensure_nginx_dirs

    # 创建网站目录
    mkdir -p "$WEB_DIR"

    # 创建默认页面
    cat > "${WEB_DIR}/index.html" <<-'DEFAULTHTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f7fa; color: #333; }
        .hero { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 100px 20px; text-align: center; }
        .hero h1 { font-size: 2.5em; margin-bottom: 20px; }
        .hero p { font-size: 1.2em; opacity: 0.9; max-width: 600px; margin: 0 auto; }
        .features { max-width: 1000px; margin: 60px auto; padding: 0 20px; display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 30px; }
        .feature { background: white; border-radius: 12px; padding: 30px; box-shadow: 0 2px 10px rgba(0,0,0,0.08); }
        .feature h3 { margin-bottom: 15px; color: #667eea; }
        .feature p { line-height: 1.6; color: #666; }
        .footer { text-align: center; padding: 40px 20px; color: #999; font-size: 0.9em; }
    </style>
</head>
<body>
    <div class="hero">
        <h1>Welcome</h1>
        <p>A modern web experience built with passion and precision.</p>
    </div>
    <div class="features">
        <div class="feature">
            <h3>Fast & Reliable</h3>
            <p>Optimized for performance with cutting-edge technology stack.</p>
        </div>
        <div class="feature">
            <h3>Secure</h3>
            <p>Built with security best practices to protect your data.</p>
        </div>
        <div class="feature">
            <h3>Beautiful Design</h3>
            <p>Clean, modern interface designed for the best user experience.</p>
        </div>
    </div>
    <div class="footer">
        <p>&copy; 2025 All rights reserved.</p>
    </div>
</body>
</html>
DEFAULTHTML

    # 生成 nginx 配置
    cat > "$NGINX_CONF" <<-NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEB_DIR};
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
}
NGINXEOF

    # 如果使用 HTTPS，添加 443 配置
    if [[ "$USE_LE_CERT" == "true" && -f "$CERT_FILE" ]]; then
        cat >> "$NGINX_CONF" <<-NGINXSSL
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    root ${WEB_DIR};
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
}
NGINXSSL
        info "已配置 HTTPS (使用 Let's Encrypt 证书)"
    fi

    # 启用站点
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/camouflage
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    # 测试并启动 nginx
    if nginx -t 2>/dev/null; then
        systemctl enable nginx 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
        info "伪装网站搭建完成: http://${DOMAIN}"
        if [[ "$USE_LE_CERT" == "true" ]]; then
            info "HTTPS: https://${DOMAIN}"
        fi
    else
        warn "nginx 配置测试失败，跳过启动"
    fi
}
# ---- 安装 hy2 管理命令 ----
install_management_tool() {
    info "安装 hy2 管理命令..."
    cat > /usr/local/bin/hy2 << 'MGMT'
#!/usr/bin/env bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
INSTALL_DIR="/etc/sing-box"
CONFIG_FILE="${INSTALL_DIR}/config.json"
BINARY="/usr/local/bin/sing-box"
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header(){ echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
show_menu() {
    clear 2>/dev/null || true
    header
    echo -e "${CYAN}  Hysteria2 管理工具${NC}"
    header
    echo ""
    echo -e "  ${BLUE}1)${NC} 启动服务"
    echo -e "  ${BLUE}2)${NC} 停止服务"
    echo -e "  ${BLUE}3)${NC} 重启服务"
    echo -e "  ${BLUE}4)${NC} 查看状态"
    echo -e "  ${BLUE}5)${NC} 查看日志"
    echo -e "  ${BLUE}6)${NC} 查看配置"
    echo -e "  ${BLUE}7)${NC} 查看客户端 URI"
    echo -e "  ${BLUE}8)${NC} 显示二维码"
    echo -e "  ${BLUE}9)${NC} 显示帮助"
    echo -e "  ${BLUE}0)${NC} 卸载 Hysteria2"
    echo -e "  ${RED}q)${NC} 退出"
    echo ""
}
do_start() {
    if ! [[ -f "$BINARY" ]]; then error "sing-box 未安装"; fi
    if systemctl is-active --quiet sing-box 2>/dev/null; then warn "服务已在运行中"; return; fi
    systemctl start sing-box 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet sing-box; then info "服务启动成功"; else error "服务启动失败"; fi
}
do_stop() {
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then warn "服务未运行"; return; fi
    systemctl stop sing-box 2>/dev/null || true
    sleep 1
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then info "服务已停止"; else error "停止服务失败"; fi
}
do_restart() {
    if ! [[ -f "$BINARY" ]]; then error "sing-box 未安装"; fi
    info "重启 sing-box 服务..."
    systemctl restart sing-box 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet sing-box; then info "服务重启成功"; else error "服务重启失败"; fi
}
do_status() {
    echo ""
    echo -e "${BLUE}  sing-box 服务状态:${NC}"
    systemctl status sing-box 2>/dev/null || echo "  服务未安装"
    echo ""
}
do_log() {
    echo ""
    echo -e "${BLUE}  最近 30 条日志:${NC}"
    echo ""
    journalctl -u sing-box -n 30 --no-pager 2>/dev/null || tail -30 "${INSTALL_DIR}/sing-box.log" 2>/dev/null || warn "无法读取日志"
    echo ""
}
do_show_config() {
    if ! [[ -f "$CONFIG_FILE" ]]; then error "配置文件不存在"; fi
    echo ""
    echo -e "${BLUE}  当前配置:${NC}"
    echo ""
    cat "$CONFIG_FILE"
    echo ""
}
do_show_uri() {
    local uri_file="${INSTALL_DIR}/client_uri.txt"
    if ! [[ -f "$uri_file" ]]; then error "客户端 URI 不存在"; fi
    echo ""
    echo -e "${BLUE}  客户端连接 URI:${NC}"
    echo ""
    echo -e "  ${CYAN}$(cat "$uri_file")${NC}"
    echo ""
}
do_show_qrcode() {
    local uri_file="${INSTALL_DIR}/client_uri.txt"
    if ! [[ -f "$uri_file" ]]; then error "客户端 URI 不存在"; fi
    if ! command -v qrencode &>/dev/null; then
        warn "qrencode 未安装，显示 URI:"
        echo -e "  ${CYAN}$(cat "$uri_file")${NC}"
        return
    fi
    echo ""
    echo -e "${BLUE}  客户端二维码:${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$(cat "$uri_file")"
    echo ""
}
do_show_help() {
    echo ""
    echo -e "${BLUE}  hy2 命令用法:${NC}"
    echo ""
    echo -e "  ${GREEN}hy2${NC}              显示管理菜单"
    echo -e "  ${GREEN}hy2 start${NC}        启动服务"
    echo -e "  ${GREEN}hy2 stop${NC}         停止服务"
    echo -e "  ${GREEN}hy2 restart${NC}      重启服务"
    echo -e "  ${GREEN}hy2 status${NC}       查看服务状态"
    echo -e "  ${GREEN}hy2 log${NC}          查看最近日志"
    echo -e "  ${GREEN}hy2 config${NC}       查看配置文件"
    echo -e "  ${GREEN}hy2 uri${NC}          查看客户端连接 URI"
    echo -e "  ${GREEN}hy2 qr${NC}           显示客户端二维码"
    echo -e "  ${GREEN}hy2 uninstall${NC}    卸载 Hysteria2"
    echo -e "  ${GREEN}hy2 help${NC}         显示此帮助"
    echo ""
}
do_uninstall() {
    echo ""
    echo -e "${RED}  即将卸载 Hysteria2 / sing-box${NC}"
    echo ""
    read -p "确认卸载? 输入 YES: " confirm
    if [[ "$confirm" != "YES" ]]; then info "已取消卸载"; return; fi
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    killall sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$BINARY"
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/hy2
    sed -i '/# Hysteria2 网络优化/,+14d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/# Hysteria2 QUIC 优化/,+8d' /etc/sysctl.conf 2>/dev/null || true
    sysctl -p 2>/dev/null || true
    echo ""
    header
    echo -e "${GREEN}  Hysteria2 已彻底移除!${NC}"
    header
    echo ""
}
interactive_menu() {
    while true; do
        show_menu
        read -p "  请选择 [0-9/q]: " choice
        case "$choice" in
            1) do_start ;;
            2) do_stop ;;
            3) do_restart ;;
            4) do_status ;;
            5) do_log ;;
            6) do_show_config ;;
            7) do_show_uri ;;
            8) do_show_qrcode ;;
            9) do_show_help ;;
            0) do_uninstall; return ;;
            q|Q) echo -e "${GREEN}  再见!${NC}"; exit 0 ;;
            *) warn "无效选择" ;;
        esac
        echo ""
        read -p "  按 Enter 返回菜单..." _
    done
}
case "${1:-}" in
    start)    do_start ;;
    stop)     do_stop ;;
    restart)  do_restart ;;
    status)   do_status ;;
    log)      do_log ;;
    config)   do_show_config ;;
    uri)      do_show_uri ;;
    qr)       do_show_qrcode ;;
    uninstall) do_uninstall ;;
    help|-h|--help) do_show_help ;;
    *)        interactive_menu ;;
esac
MGMT
    chmod +x /usr/local/bin/hy2
    info "hy2 管理命令已安装: /usr/local/bin/hy2"
    info "输入 hy2 即可打开管理菜单"
}
# ---- 显示完成信息 ----
show_summary() {
    echo ""
    header
    echo -e "${GREEN}  Hysteria2 安装完成!${NC}"
    header
    echo ""
    echo -e "  ${BLUE}服务端信息:${NC}"
    echo -e "    协议:     Hysteria2"
    echo -e "    地址:     ${DOMAIN:-$SERVER_IP}"
    echo -e "    端口:     ${HY2_PORT}/UDP"
    echo -e "    密码:     ${HY2_PASSWORD}"
    echo -e "    混淆:     Salamander"
    echo -e "    混淆密钥: ${HY2_OBFS_PASSWORD}"
    echo -e "    SNI:      ${HY2_SNI}"
    echo ""
    echo -e "  ${BLUE}管理命令:${NC}"
    echo -e "    启动:   systemctl start sing-box"
    echo -e "    停止:   systemctl stop sing-box"
    echo -e "    重启:   systemctl restart sing-box"
    echo -e "    状态:   systemctl status sing-box"
    echo -e "    日志:   journalctl -u sing-box -n 50 -f"
    echo ""
    echo -e "  ${BLUE}文件路径:${NC}"
    echo -e "    配置:       ${CONFIG_FILE}"
    echo -e "    证书:       ${CERT_FILE}"
    echo -e "    客户端 URI: ${INSTALL_DIR}/client_uri.txt"
    echo -e "    客户端配置: ${INSTALL_DIR}/client/"
    if [[ -n "$DOMAIN" ]]; then
        echo -e "    伪装网站:   /var/www/camouflage/"
    fi
    echo ""
    if [[ -n "$DOMAIN" ]]; then
        echo -e "  ${BLUE}伪装网站:${NC}"
        echo -e "    访问:   http://${DOMAIN}"
        if [[ "$USE_LE_CERT" == "true" ]]; then
            echo -e "    HTTPS:  https://${DOMAIN}"
        fi
        echo -e "    目录:   /var/www/camouflage/"
        echo ""
    fi
    echo -e "  ${YELLOW}推荐客户端:${NC}"
    echo -e "    Windows:  v2rayN / Sing-box / Clash.Meta"
    echo -e "    Android:  NekoBox / Hiddify / Sing-box"
    echo -e "    iOS:      Shadowrocket / Stash / Sing-box"
    echo -e "    macOS:    Clash.Meta / Sing-box"
    echo ""
    echo -e "  ${RED}注意:${NC}"
    if [[ "$USE_LE_CERT" == "true" ]]; then
        echo -e "    使用 Let's Encrypt 证书，客户端无需开启不安全证书"
    else
        echo -e "    使用自签名证书，客户端需开启 ${YELLOW}允许不安全证书${NC}"
    fi
    echo ""
}
# ---- 彻底移除 Hysteria2 ----
uninstall() {
    header
    echo -e "${RED}  彻底移除 Hysteria2 / sing-box${NC}"
    header
    echo ""
    safe_read "$(echo -e "${RED}确认彻底移除? 输入 YES 确认: ${NC}")" confirm
    if [[ "$confirm" != "YES" ]]; then info "已取消移除"; return; fi
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    killall sing-box 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$BINARY"
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/hy2
    sed -i '/# Hysteria2 网络优化/,+14d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/# Hysteria2 QUIC 优化/,+8d' /etc/sysctl.conf 2>/dev/null || true
    sysctl -p 2>/dev/null || true
    echo ""
    header
    echo -e "${GREEN}  Hysteria2 已彻底移除!${NC}"
    header
    echo ""
}
main() {
    case "${1:-}" in
        --uninstall|-u)
            check_root
            uninstall
            return
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  (无参数)    交互式安装 Hysteria2"
            echo "  -u, --uninstall  彻底移除 Hysteria2"
            echo "  -h, --help       显示此帮助信息"
            return
            ;;
    esac
    clear 2>/dev/null || true
    check_root
    detect_os
    get_server_ip
    install_deps
    ensure_nginx_dirs
    ensure_python3
    enable_bbr
    interactive_config
    install_sing_box
    generate_cert
    generate_config
    setup_camouflage_site
    create_service
    config_firewall
    generate_uri
    generate_qrcode
    generate_client_config
    install_management_tool
    start_service
    show_summary
}
main "$@"
