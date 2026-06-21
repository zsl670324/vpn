#!/bin/bash

# ==========================================
# 综合代理服务器管理脚本 v2.4
# 包含: SWAP + BBR + Xray (VLESS+Vision+Reality) + Hysteria2 + 证书 (Acme.sh/自带域名证书) + 伪装网站
# 特性: 自动检测安装依赖，支持查看连接信息、URL、二维码、服务管理
# 支持: 自定义 ShortId、使用自带域名证书模式
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

die() {
    echo -e "${RED}错误: $1${PLAIN}"
    exit 1
}

check_last_status() {
    local status=$1
    local message="$2"
    if [ "$status" -ne 0 ]; then
        die "$message"
    fi
}

open_port() {
    local port=$1
    local proto=$2
    echo -e "${YELLOW}正在尝试放行防火墙端口 ${port}/${proto}...${PLAIN}"
    if command -v ufw &> /dev/null; then
        ufw allow "$port/$proto" >/dev/null 2>&1
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --add-port="$port/$proto" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables &> /dev/null; then
        iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1
    fi
}

get_public_ip() {
    local ip=""
    local ip_services=(
        "https://ipv4.icanhazip.com"
        "https://ifconfig.me/ip"
        "https://api.ipify.org"
    )
    local service
    for service in "${ip_services[@]}"; do
        ip=$(curl -4 -fsSL --max-time 10 "$service" 2>/dev/null | tr -d '\r\n')
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

ensure_cert_files() {
    if [ -f /etc/certs/fullchain.crt ] && [ -f /etc/certs/private.key ]; then
        if openssl x509 -checkend 86400 -noout -in /etc/certs/fullchain.crt 2>/dev/null; then
            return 0
        fi
    fi
    echo -e "${YELLOW}未检测到 Hysteria2 所需证书，开始自动申请证书...${PLAIN}"
    apply_cert || return 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "必须使用 root 用户运行此脚本！"
    fi
}

# ========== 从配置文件读取连接信息 ==========

get_xray_config() {
    local cfg="/usr/local/etc/xray/config.json"
    if [ ! -f "$cfg" ]; then
        return 1
    fi
    XRAY_UUID=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$cfg" 2>/dev/null)
    XRAY_PORT=$(jq -r '.inbounds[0].port // empty' "$cfg" 2>/dev/null)
    XRAY_SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$cfg" 2>/dev/null)
    XRAY_SHORTID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$cfg" 2>/dev/null)

    local priv_key
    priv_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$cfg" 2>/dev/null)

    XRAY_PUBKEY=""
    if [ -n "$priv_key" ]; then
        local keys
        keys=$(/usr/local/bin/xray x25519 -i "$priv_key" 2>/dev/null)
        if [ $? -eq 0 ]; then
            XRAY_PUBKEY=$(echo "$keys" | grep "PublicKey" | sed 's/.*: //')
        fi
    fi
    if [ -z "$XRAY_PUBKEY" ]; then
        XRAY_PUBKEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey // empty' "$cfg" 2>/dev/null)
    fi

    [ -n "$XRAY_UUID" ] && [ -n "$XRAY_PORT" ]
}

get_hy2_config() {
    local cfg="/etc/hysteria/config.yaml"
    if [ ! -f "$cfg" ]; then
        return 1
    fi
    HY2_PORT=$(grep -m1 "^listen:" "$cfg" 2>/dev/null | sed 's/listen: *://')
    HY2_PASS=$(grep -m1 "password:" "$cfg" 2>/dev/null | sed 's/.*password: *//' | tr -d '"' | tr -d "'")
    HY2_OBFS=$(grep -A5 "^obfs:" "$cfg" 2>/dev/null | grep "password:" | head -1 | sed 's/.*password: *//' | tr -d '"' | tr -d "'")
    [ -n "$HY2_PORT" ] && [ -n "$HY2_PASS" ]
}

get_hy2_domain() {
    if [ -n "$DOMAIN" ]; then
        return
    fi
    local conf_dir
    for conf_dir in /root/.acme.sh/*_ecc; do
        [ -d "$conf_dir" ] || continue
        if [ -f "${conf_dir}/ca.conf" ]; then
            DOMAIN=$(grep "^DOMAIN=" "${conf_dir}/ca.conf" 2>/dev/null | head -1 | cut -d= -f2-)
            if [ -n "$DOMAIN" ]; then
                return
            fi
        fi
    done
}

show_xray_info() {
    if ! get_xray_config; then
        echo -e "${RED}未检测到 Xray 配置，请先安装 Xray (菜单 15)。${PLAIN}"
        return
    fi
    if [ -z "$XRAY_PUBKEY" ]; then
        echo -e "${RED}无法解析 Public Key，请检查 Xray 配置或重新安装。${PLAIN}"
        return
    fi

    SERVER_IP=$(get_public_ip)
    if [ -z "$SERVER_IP" ]; then
        echo -e "${RED}无法获取服务器公网 IP。${PLAIN}"
        return
    fi

    local VLESS_URL="vless://${XRAY_UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${XRAY_PUBKEY}&sid=${XRAY_SHORTID}&type=tcp#Xray-${SERVER_IP}"

    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "${GREEN}  Xray (VLESS+Vision+REALITY) 连接信息${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    if systemctl is-active --quiet xray 2>/dev/null; then
        echo -e "  服务状态: ${GREEN}运行中${PLAIN}"
    elif [ -f /usr/local/bin/xray ]; then
        echo -e "  服务状态: ${RED}已停止${PLAIN}"
    else
        echo -e "  服务状态: ${YELLOW}未安装${PLAIN}"
    fi
    echo -e "  服务器IP: ${YELLOW}${SERVER_IP}${PLAIN}"
    echo -e "  监听端口: ${YELLOW}${XRAY_PORT}${PLAIN}"
    echo -e "  UUID:     ${YELLOW}${XRAY_UUID}${PLAIN}"
    echo -e "  PubKey:   ${YELLOW}${XRAY_PUBKEY}${PLAIN}"
    echo -e "  SNI:      ${YELLOW}${XRAY_SNI}${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "  分享链接 (URL):"
    echo -e "${YELLOW}${VLESS_URL}${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "  二维码 (V2rayN / v2rayNG / NekoBox 扫描):"
    echo -n "${VLESS_URL}" | qrencode -t ANSIUTF8
    echo -e "${GREEN}===================================================${PLAIN}"
}

show_hy2_info() {
    get_hy2_domain

    if ! get_hy2_config; then
        echo -e "${RED}未检测到 Hysteria2 配置，请先安装 Hysteria2 (菜单 16)。${PLAIN}"
        return
    fi

    local SNI="${DOMAIN:-unknown}"
    local HY2_URL
    if [ -n "$HY2_OBFS" ]; then
        HY2_URL="hy2://${HY2_PASS}@${SNI}:${HY2_PORT}/?obfs=salamander&obfs-password=${HY2_OBFS}&sni=${SNI}&insecure=0#Hysteria2-${SNI}"
    else
        HY2_URL="hy2://${HY2_PASS}@${SNI}:${HY2_PORT}/?sni=${SNI}&insecure=0#Hysteria2-${SNI}"
    fi

    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "${GREEN}  Hysteria2 连接信息${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    if systemctl is-active --quiet hysteria-server.service 2>/dev/null; then
        echo -e "  服务状态: ${GREEN}运行中${PLAIN}"
    elif [ -f /usr/local/bin/hysteria ]; then
        echo -e "  服务状态: ${RED}已停止${PLAIN}"
    else
        echo -e "  服务状态: ${YELLOW}未安装${PLAIN}"
    fi
    echo -e "  域名:     ${YELLOW}${SNI}${PLAIN}"
    echo -e "  端口:     ${YELLOW}${HY2_PORT}${PLAIN}"
    echo -e "  密码:     ${YELLOW}${HY2_PASS}${PLAIN}"
    if [ -n "$HY2_OBFS" ]; then
        echo -e "  混淆密码: ${YELLOW}${HY2_OBFS}${PLAIN}"
    fi
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "  分享链接 (URL):"
    echo -e "${YELLOW}${HY2_URL}${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "  二维码 (v2rayN / NekoBox / Shadowrocket 扫描):"
    echo -n "${HY2_URL}" | qrencode -t ANSIUTF8
    echo -e "${GREEN}===================================================${PLAIN}"
}

show_all_info() {
    show_xray_info
    echo ""
    show_hy2_info
}

# ========== 服务管理 ==========

show_service_status() {
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "${GREEN}  服务运行状态${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"

    if systemctl is-active --quiet xray 2>/dev/null; then
        echo -e "  Xray:       ${GREEN}运行中${PLAIN}"
    elif [ -f /usr/local/bin/xray ]; then
        echo -e "  Xray:       ${RED}已停止${PLAIN}"
    else
        echo -e "  Xray:       ${YELLOW}未安装${PLAIN}"
    fi

    if systemctl is-active --quiet hysteria-server.service 2>/dev/null; then
        echo -e "  Hysteria2:  ${GREEN}运行中${PLAIN}"
    elif [ -f /usr/local/bin/hysteria ]; then
        echo -e "  Hysteria2:  ${RED}已停止${PLAIN}"
    else
        echo -e "  Hysteria2:  ${YELLOW}未安装${PLAIN}"
    fi

    if grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        echo -e "  BBR:        ${GREEN}已启用${PLAIN}"
    else
        echo -e "  BBR:        ${YELLOW}未启用${PLAIN}"
    fi

    echo -e "${GREEN}===================================================${PLAIN}"
}

restart_services() {
    echo -e "${GREEN}正在重启服务...${PLAIN}"
    if [ -f /usr/local/bin/xray ]; then
        systemctl restart xray 2>/dev/null
        if systemctl is-active --quiet xray; then
            echo -e "  Xray:       ${GREEN}重启成功${PLAIN}"
        else
            echo -e "  Xray:       ${RED}重启失败${PLAIN}"
        fi
    fi
    if [ -f /usr/local/bin/hysteria ]; then
        systemctl restart hysteria-server.service 2>/dev/null
        if systemctl is-active --quiet hysteria-server.service; then
            echo -e "  Hysteria2:  ${GREEN}重启成功${PLAIN}"
        else
            echo -e "  Hysteria2:  ${RED}重启失败${PLAIN}"
        fi
    fi
}

stop_services() {
    echo -e "${YELLOW}正在停止服务...${PLAIN}"
    if systemctl is-active --quiet xray 2>/dev/null; then
        systemctl stop xray
        echo -e "  Xray:       ${GREEN}已停止${PLAIN}"
    else
        echo -e "  Xray:       ${YELLOW}未在运行${PLAIN}"
    fi
    if systemctl is-active --quiet hysteria-server.service 2>/dev/null; then
        systemctl stop hysteria-server.service
        echo -e "  Hysteria2:  ${GREEN}已停止${PLAIN}"
    else
        echo -e "  Hysteria2:  ${YELLOW}未在运行${PLAIN}"
    fi
}

start_services() {
    echo -e "${GREEN}正在启动服务...${PLAIN}"
    if [ -f /usr/local/bin/xray ]; then
        systemctl start xray 2>/dev/null
        if systemctl is-active --quiet xray; then
            echo -e "  Xray:       ${GREEN}已启动${PLAIN}"
        else
            echo -e "  Xray:       ${RED}启动失败${PLAIN}"
        fi
    fi
    if [ -f /usr/local/bin/hysteria ]; then
        systemctl start hysteria-server.service 2>/dev/null
        if systemctl is-active --quiet hysteria-server.service; then
            echo -e "  Hysteria2:  ${GREEN}已启动${PLAIN}"
        else
            echo -e "  Hysteria2:  ${RED}启动失败${PLAIN}"
        fi
    fi
}

# ========== 安装 / 卸载 ==========

enable_bbr() {
    echo -e "${GREEN}正在配置并开启 BBR...${PLAIN}"
    if grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
        echo -e "${YELLOW}BBR 似乎已经配置过，跳过。${PLAIN}"
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        check_last_status $? "BBR 配置写入失败。"
        echo -e "${GREEN}BBR 开启成功！${PLAIN}"
    fi
}

add_swap() {
    echo -e "${GREEN}正在添加 2GB SWAP 虚拟内存...${PLAIN}"
    if grep -q "swap" /etc/fstab; then
        echo -e "${YELLOW}SWAP 已经存在，跳过。${PLAIN}"
    else
        fallocate -l 2G /swapfile
        check_last_status $? "创建 SWAP 文件失败。"
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        check_last_status $? "启用 SWAP 失败。"
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo -e "${GREEN}SWAP 添加成功！${PLAIN}"
    fi
}

install_base() {
    echo -e "${GREEN}正在检查并安装基础依赖...${PLAIN}"
    local deps=("curl" "wget" "git" "socat" "jq" "qrencode" "lsof")
    local to_install=""

    if command -v apt &> /dev/null; then
        PM="apt"
    elif command -v dnf &> /dev/null; then
        PM="dnf"
    elif command -v yum &> /dev/null; then
        PM="yum"
    else
        die "未找到支持的包管理器 (apt/dnf/yum)，请手动安装依赖。"
    fi

    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            to_install="$to_install $dep"
        fi
    done

    if [ -n "$to_install" ]; then
        echo -e "${YELLOW}缺少依赖: $to_install，正在安装...${PLAIN}"
        if [ "$PM" = "apt" ]; then
            apt update -y && apt install -y $to_install
            check_last_status $? "基础依赖安装失败。"
        elif [ "$PM" = "dnf" ]; then
            dnf install -y $to_install
            check_last_status $? "基础依赖安装失败。"
        elif [ "$PM" = "yum" ]; then
            yum install -y epel-release
            yum install -y $to_install
            check_last_status $? "基础依赖安装失败。"
        fi
    else
        echo -e "${GREEN}所有基础依赖已安装！${PLAIN}"
    fi

    SERVER_IP=$(get_public_ip)
    check_last_status $? "无法获取服务器公网 IP，请检查网络连接。"
}

apply_own_cert() {
    echo -e "${GREEN}===== 使用自带域名证书模式 =====${PLAIN}"
    echo -e "${YELLOW}请确保证书文件路径正确，且证书未过期。${PLAIN}"
    echo ""

    read -p "请输入证书文件路径 (fullchain.pem 或 fullchain.crt): " CERT_PATH
    if [ ! -f "$CERT_PATH" ]; then
        echo -e "${RED}证书文件不存在: ${CERT_PATH}${PLAIN}"
        return 1
    fi

    read -p "请输入私钥文件路径 (privkey.pem 或 private.key): " KEY_PATH
    if [ ! -f "$KEY_PATH" ]; then
        echo -e "${RED}私钥文件不存在: ${KEY_PATH}${PLAIN}"
        return 1
    fi

    if ! openssl x509 -noout -checkend 0 -in "$CERT_PATH" 2>/dev/null; then
        echo -e "${RED}证书已过期，请先更新证书！${PLAIN}"
        return 1
    fi

    mkdir -p /etc/certs
    cp "$CERT_PATH" /etc/certs/fullchain.crt
    cp "$KEY_PATH" /etc/certs/private.key
    chmod 755 /etc/certs
    chmod 644 /etc/certs/fullchain.crt
    chmod 600 /etc/certs/private.key

    echo -e "${GREEN}自带证书已安装到 /etc/certs/ 目录！${PLAIN}"
    return 0
}

apply_cert() {
    if [ -f /etc/certs/fullchain.crt ] && [ -f /etc/certs/private.key ]; then
        if openssl x509 -checkend 86400 -noout -in /etc/certs/fullchain.crt 2>/dev/null; then
            echo -e "${GREEN}检测到有效证书，跳过申请。${PLAIN}"
            return 0
        fi
        echo -e "${YELLOW}证书即将过期，需要重新申请...${PLAIN}"
    fi

    echo -e "${YELLOW}请选择证书获取方式:${PLAIN}"
    echo -e "  1. 使用 Acme.sh 自动签发 (Let's Encrypt)"
    echo -e "  2. 使用自带域名证书"
    read -p "请输入选择 (默认 1): " CERT_MODE
    CERT_MODE=${CERT_MODE:-1}

    if [ "$CERT_MODE" = "2" ]; then
        apply_own_cert
        return $?
    fi

    echo -e "${GREEN}开始申请证书 (用于 Hysteria2)...${PLAIN}"

    if command -v lsof &> /dev/null; then
        if lsof -i :80 &> /dev/null; then
            local pid=$(lsof -t -i :80 | head -n 1)
            local pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "未知进程")
            echo -e "${YELLOW}检测到 80 端口被进程 [${pname} (PID: ${pid})] 占用！${PLAIN}"
            read -p "是否尝试自动强制停止该进程以继续申请证书？(y/n) " stop_confirm
            if [[ "$stop_confirm" == "y" || "$stop_confirm" == "Y" ]]; then
                echo -e "${GREEN}正在尝试终止占用 80 端口的进程...${PLAIN}"
                kill -9 "$pid"
                sleep 2
            else
                die "80 端口被占用，无法使用 Standalone 模式申请证书，已终止。"
            fi
        fi
    fi

    echo -e "${YELLOW}注意: 请确保您的域名已经解析到本服务器的 IP！${PLAIN}"
    read -p "请输入您的域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}域名不能为空，取消申请！${PLAIN}"
        return 1
    fi

    curl https://get.acme.sh | sh
    check_last_status $? "acme.sh 安装失败。"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    check_last_status $? "切换 Let's Encrypt CA 失败。"

    mkdir -p /etc/certs

    if ~/.acme.sh/acme.sh --list | grep -q "$DOMAIN"; then
        echo -e "${YELLOW}检测到 acme.sh 已有该域名证书，尝试直接安装...${PLAIN}"
        if ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" \
            --fullchainpath /etc/certs/fullchain.crt \
            --keypath /etc/certs/private.key \
            --ecc 2>/dev/null; then
            echo -e "${GREEN}证书已从 acme.sh 恢复安装！${PLAIN}"
            chmod 755 /etc/certs
            chmod 644 /etc/certs/fullchain.crt
            chmod 600 /etc/certs/private.key
            return 0
        fi
        echo -e "${YELLOW}恢复失败，尝试重新签发...${PLAIN}"
    fi

    echo -e "${YELLOW}首次签发证书...${PLAIN}"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256
    if [ $? -ne 0 ]; then
        echo -e "${RED}证书签发失败！可能原因:${PLAIN}"
        echo -e "  1. 域名未解析到本服务器 IP"
        echo -e "  2. Let's Encrypt 签发限速 (7天内同一域名最多5张证书)"
        echo -e "  3. 80 端口被占用或防火墙未放行"
        echo -e "${YELLOW}如已签发过证书，请等待限速解除后重试 (通常24小时)。${PLAIN}"
        return 1
    fi

    ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" \
        --fullchainpath /etc/certs/fullchain.crt \
        --keypath /etc/certs/private.key \
        --ecc
    check_last_status $? "证书安装到 /etc/certs 失败。"

    chmod 755 /etc/certs
    chmod 644 /etc/certs/fullchain.crt
    chmod 600 /etc/certs/private.key

    echo -e "${GREEN}证书申请完成！存放路径: /etc/certs/${PLAIN}"
}

download_camouflage() {
    echo -e "${GREEN}正在从 GitHub 拉取静态伪装网站...${PLAIN}"
    mkdir -p /var/www/html
    rm -rf /var/www/html/*

    rm -rf /tmp/website
    git clone --depth 1 https://github.com/wulabing/3DCEList.git /tmp/website
    if [ $? -eq 0 ]; then
        cp -a /tmp/website/. /var/www/html/
        check_last_status $? "伪装网站复制失败。"
        rm -rf /tmp/website
        echo -e "${GREEN}伪装网站拉取完成！存放路径: /var/www/html${PLAIN}"
    else
        echo -e "${YELLOW}伪装网站拉取失败，将生成默认页面...${PLAIN}"
        ensure_camouflage
    fi
}

ensure_camouflage() {
    if [ ! -d "/var/www/html" ] || [ -z "$(ls -A /var/www/html)" ]; then
        echo -e "${YELLOW}未检测到伪装网站文件，正在生成默认页面...${PLAIN}"
        mkdir -p /var/www/html
        echo "<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>It works!</h1></body></html>" > /var/www/html/index.html
    fi
}

setup_nginx() {
    echo -e "${GREEN}正在安装 Nginx 并配置伪装网站 HTTPS...${PLAIN}"
    if ! command -v nginx &> /dev/null; then
        if command -v apt &> /dev/null; then
            apt update -y && apt install -y nginx
        elif command -v dnf &> /dev/null; then
            dnf install -y nginx
        elif command -v yum &> /dev/null; then
            yum install -y nginx
        fi
    fi
    check_last_status $? "Nginx 安装失败。"

    local HY2_DOMAIN="${DOMAIN:-_}"
    if [ "$HY2_DOMAIN" = "_" ]; then
        local fallback_ip
        fallback_ip=$(get_public_ip)
        HY2_DOMAIN="${fallback_ip:-_}"
    fi

    cat > /etc/nginx/sites-available/masquerade.conf <<EOF
server {
    listen 80;
    server_name ${HY2_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${HY2_DOMAIN};

    ssl_certificate /etc/certs/fullchain.crt;
    ssl_certificate_key /etc/certs/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/html;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    ln -sf /etc/nginx/sites-available/masquerade.conf /etc/nginx/sites-enabled/

    nginx -t 2>&1
    if [ $? -eq 0 ]; then
        systemctl restart nginx
        systemctl enable nginx >/dev/null 2>&1
        open_port 443 tcp
        echo -e "${GREEN}Nginx 安装配置完成！伪装网站已可通过 HTTPS 访问。${PLAIN}"
    else
        echo -e "${RED}Nginx 配置检测失败，请检查证书和端口。${PLAIN}"
    fi
}

install_xray() {
    echo -e "${GREEN}正在安装 Xray...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    check_last_status $? "Xray 安装失败。"

    UUID=$(/usr/local/bin/xray uuid)
    check_last_status $? "UUID 生成失败，请确认 Xray 是否已正确安装。"
    KEYS=$(/usr/local/bin/xray x25519)
    check_last_status $? "X25519 密钥生成失败，请确认 Xray 是否已正确安装。"
    PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey:" | sed 's/.*: //')
    PUBLIC_KEY=$(echo "$KEYS" | grep "PublicKey" | sed 's/.*: //')

    read -p "请输入 Xray VLESS 监听端口 (默认 8443): " XRAY_PORT
    XRAY_PORT=${XRAY_PORT:-8443}

    read -p "请输入 REALITY 伪装目标网站 (默认 www.microsoft.com): " DEST_SITE
    DEST_SITE=${DEST_SITE:-www.microsoft.com}

    read -p "请输入 SHORT ID (直接回车自动生成随机ID): " SHORT_ID
    if [ -z "$SHORT_ID" ]; then
        SHORT_ID=$(openssl rand -hex 8)
    fi

    cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST_SITE:443",
          "xver": 0,
          "serverNames": [
            "$DEST_SITE"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
    if grep -q -E -i "debian|ubuntu" /etc/os-release 2>/dev/null; then
        chown -R nobody:nogroup /usr/local/etc/xray
    else
        chown -R nobody:nobody /usr/local/etc/xray
    fi
    chmod 644 /usr/local/etc/xray/config.json

    systemctl restart xray
    sleep 2
    systemctl enable xray >/dev/null 2>&1
    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}Xray 服务启动失败，正在诊断...${PLAIN}"
        journalctl -u xray --no-pager -n 10 2>&1
        die "Xray 服务未处于运行状态。"
    fi

    open_port "$XRAY_PORT" "tcp"

    local VLESS_URL="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SITE}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Xray-${SERVER_IP}"

    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "${GREEN}Xray (VLESS+Vision+REALITY) 安装并配置完成！${PLAIN}"
    echo -e "端口: ${YELLOW}${XRAY_PORT}${PLAIN}"
    echo -e "UUID: ${YELLOW}${UUID}${PLAIN}"
    echo -e "Public Key: ${YELLOW}${PUBLIC_KEY}${PLAIN}"
    echo -e "目标网站: ${YELLOW}${DEST_SITE}${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "分享链接 (URL):"
    echo -e "${YELLOW}${VLESS_URL}${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "二维码 (请使用 V2rayN / v2rayNG / NekoBox 等客户端扫描):"
    echo -n "${VLESS_URL}" | qrencode -t ANSIUTF8
    echo -e "${GREEN}===================================================${PLAIN}"
}

install_hysteria2() {
    echo -e "${GREEN}正在安装 Hysteria2...${PLAIN}"
    bash <(curl -fsSL https://get.hy2.sh/)
    check_last_status $? "Hysteria2 安装失败。"
    ensure_cert_files || die "未能准备好 Hysteria2 所需证书。"
    ensure_camouflage

    if [ -z "$DOMAIN" ]; then
        read -p "请输入您绑定的域名 (用于生成客户端连接URL): " DOMAIN
    fi
    if [ -z "$DOMAIN" ]; then
        die "Hysteria2 连接域名不能为空。"
    fi

    read -p "请输入 Hysteria2 监听端口 (默认 8443): " HY2_PORT
    HY2_PORT=${HY2_PORT:-8443}

    read -p "请输入 Hysteria2 密码 (直接回车将自动生成随机密码): " HY2_PASS
    if [ -z "$HY2_PASS" ]; then
        HY2_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
    fi

    echo -e "${YELLOW}正在生成混淆密码 (obfs)...${PLAIN}"
    HY2_OBFS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)

    cat > /etc/hysteria/config.yaml <<EOF
listen: :$HY2_PORT

tls:
  cert: /etc/certs/fullchain.crt
  key: /etc/certs/private.key

auth:
  type: password
  password: $HY2_PASS

obfs:
  type: salamander
  salamander:
    password: "$HY2_OBFS"

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
    chmod 644 /etc/hysteria/config.yaml
    chown hysteria:hysteria /etc/hysteria/config.yaml 2>/dev/null

    systemctl daemon-reload
    systemctl restart hysteria-server.service
    sleep 2
    if ! systemctl is-active --quiet hysteria-server.service; then
        echo -e "${RED}Hysteria2 启动失败，正在诊断...${PLAIN}"
        journalctl -u hysteria-server.service --no-pager -n 15 2>&1
        die "Hysteria2 服务未处于运行状态。"
    fi
    systemctl enable hysteria-server.service >/dev/null 2>&1

    open_port "$HY2_PORT" "udp"

    local HY2_URL="hy2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}/?obfs=salamander&obfs-password=${HY2_OBFS}&sni=${DOMAIN}&insecure=0#Hysteria2-${DOMAIN}"

    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "${GREEN}Hysteria2 安装并配置完成！${PLAIN}"
    echo -e "域名:     ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "端口:     ${YELLOW}${HY2_PORT}${PLAIN}"
    echo -e "密码:     ${YELLOW}${HY2_PASS}${PLAIN}"
    echo -e "混淆密码: ${YELLOW}${HY2_OBFS}${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "分享链接 (URL):"
    echo -e "${YELLOW}${HY2_URL}${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "二维码 (请使用 v2rayN / NekoBox / Shadowrocket 等客户端扫描):"
    echo -n "${HY2_URL}" | qrencode -t ANSIUTF8
    echo -e "${GREEN}===================================================${PLAIN}"

    setup_nginx
}

install_all() {
    check_root
    install_base
    add_swap
    enable_bbr
    apply_cert || die "证书申请流程未完成。"
    download_camouflage
    install_xray
    install_hysteria2
    echo -e "${GREEN}====== 所有组件安装完成！请保存好上方的链接和二维码 ======${PLAIN}"
}

uninstall_all() {
    echo -e "${YELLOW}警告: 此操作将卸载 Xray、Hysteria2、Acme.sh 证书，并清理所有相关配置。${PLAIN}"
    read -p "确定要继续吗？(y/n) " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "已取消卸载。"
        return
    fi

    echo -e "${GREEN}正在停止并移除 Xray...${PLAIN}"
    systemctl stop xray 2>/dev/null
    systemctl disable xray >/dev/null 2>&1
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
    rm -rf /usr/local/etc/xray

    echo -e "${GREEN}正在停止并移除 Hysteria2...${PLAIN}"
    systemctl stop hysteria-server.service 2>/dev/null
    systemctl disable hysteria-server.service >/dev/null 2>&1
    rm -f /usr/local/bin/hysteria
    rm -rf /etc/hysteria
    rm -f /etc/systemd/system/hysteria-server.service
    rm -f /etc/systemd/system/hysteria-server@.service
    systemctl daemon-reload

    echo -e "${GREEN}正在清理证书与 acme.sh...${PLAIN}"
    rm -rf /etc/certs
    if [ -f ~/.acme.sh/acme.sh ]; then
        ~/.acme.sh/acme.sh --uninstall
        rm -rf ~/.acme.sh
    fi

    echo -e "${GREEN}正在清理伪装网站...${PLAIN}"
    rm -rf /var/www/html

    echo -e "${GREEN}正在清理 Nginx...${PLAIN}"
    systemctl stop nginx 2>/dev/null
    systemctl disable nginx 2>/dev/null
    rm -f /etc/nginx/sites-available/masquerade.conf
    rm -f /etc/nginx/sites-enabled/masquerade.conf
    rm -f /etc/nginx/conf.d/masquerade.conf

    echo -e "${GREEN}卸载与清理完成！(SWAP和BBR加速保留未受影响)${PLAIN}"
}

# ========== 菜单辅助 ==========

show_menu_status() {
    local xray_status hy2_status bbr_status
    if systemctl is-active --quiet xray 2>/dev/null; then
        xray_status="${GREEN}运行${PLAIN}"
    elif [ -f /usr/local/bin/xray ]; then
        xray_status="${RED}停止${PLAIN}"
    else
        xray_status="${YELLOW}未装${PLAIN}"
    fi

    if systemctl is-active --quiet hysteria-server.service 2>/dev/null; then
        hy2_status="${GREEN}运行${PLAIN}"
    elif [ -f /usr/local/bin/hysteria ]; then
        hy2_status="${RED}停止${PLAIN}"
    else
        hy2_status="${YELLOW}未装${PLAIN}"
    fi

    if grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        bbr_status="${GREEN}已启${PLAIN}"
    else
        bbr_status="${YELLOW}未启${PLAIN}"
    fi

    echo -e "  服务状态: Xray[${xray_status}]  Hysteria2[${hy2_status}]  BBR[${bbr_status}]"
}

view_logs() {
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "${GREEN}  查看服务日志${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "  1. Xray 日志"
    echo -e "  2. Hysteria2 日志"
    echo -e "  3. Nginx 日志"
    echo -e "  0. 返回主菜单"
    read -p "请选择: " log_choice
    case $log_choice in
        1) journalctl -u xray --no-pager -n 50 ;;
        2) journalctl -u hysteria-server.service --no-pager -n 50 ;;
        3) journalctl -u nginx --no-pager -n 50 ;;
        0) return ;;
        *) echo -e "${RED}输入错误！${PLAIN}" ;;
    esac
}

view_ports() {
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "${GREEN}  当前监听端口${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    if command -v ss &> /dev/null; then
        ss -tunlp 2>/dev/null | grep -E "LISTEN" || echo -e "  ${YELLOW}无监听端口${PLAIN}"
    elif command -v netstat &> /dev/null; then
        netstat -tunlp 2>/dev/null | grep -E "LISTEN" || echo -e "  ${YELLOW}无监听端口${PLAIN}"
    else
        echo -e "${YELLOW}未安装 ss 或 netstat 工具${PLAIN}"
    fi
}

# ========== 主菜单 ==========

show_menu() {
    while true; do
        clear
        echo -e "${GREEN}===================================================${PLAIN}"
        echo -e "${YELLOW}        综合代理服务器管理脚本 v2.4        ${PLAIN}"
        echo -e "${GREEN}===================================================${PLAIN}"
        show_menu_status
        echo -e "${GREEN}---------------------------------------------------${PLAIN}"
        echo ""
        echo -e "  ${BOLD}--- 查看信息 ---${PLAIN}"
        echo -e "  1. 查看 Xray 连接信息 (URL + 二维码)"
        echo -e "  2. 查看 Hysteria2 连接信息 (URL + 二维码)"
        echo -e "  3. 查看所有连接信息"
        echo -e "  4. 查看服务状态"
        echo ""
        echo -e "  ${BOLD}--- 服务管理 ---${PLAIN}"
        echo -e "  5. 重启所有服务"
        echo -e "  6. 启动所有服务"
        echo -e "  7. 停止所有服务"
        echo ""
        echo -e "  ${BOLD}--- 安装 / 卸载 ---${PLAIN}"
        echo -e "  10. 一键安装全部 (SWAP+BBR+证书+伪装+Xray+Hysteria2)"
        echo -e "  11. 仅开启 BBR 加速"
        echo -e "  12. 仅添加 SWAP (2GB)"
        echo -e "  13. 仅申请证书 (Acme.sh)"
        echo -e "  14. 仅拉取伪装网站"
        echo -e "  15. 仅安装 Xray"
        echo -e "  16. 仅安装 Hysteria2"
        echo -e "  17. 一键卸载全部"
        echo -e "  18. 使用自带域名证书"
        echo ""
        echo -e "  ${BOLD}--- 工具 ---${PLAIN}"
        echo -e "  20. 查看服务日志"
        echo -e "  21. 查看监听端口"
        echo ""
        echo -e "  0. 退出脚本"
        echo -e "${GREEN}===================================================${PLAIN}"
        read -p "请输入您的选择: " choice

        case $choice in
            1) show_xray_info ;;
            2) show_hy2_info ;;
            3) show_all_info ;;
            4) show_service_status ;;
            5) restart_services ;;
            6) start_services ;;
            7) stop_services ;;
            10) install_all ;;
            11) check_root; enable_bbr ;;
            12) check_root; add_swap ;;
            13) check_root; install_base; apply_cert ;;
            14) check_root; install_base; download_camouflage ;;
            15) check_root; install_base; install_xray ;;
            16) check_root; install_base; install_hysteria2 ;;
            17) check_root; uninstall_all ;;
            18) check_root; apply_own_cert ;;
            20) view_logs ;;
            21) view_ports ;;
            0) echo "退出脚本。"; exit 0 ;;
            *) echo -e "${RED}输入错误，请重新选择！${PLAIN}" ;;
        esac

        echo ""
        read -p "按回车返回主菜单..." _
    done
}

setup_shortcut() {
    local shortcut_path="/usr/local/bin/vpn"
    local current_script
    current_script=$(readlink -f "$0" 2>/dev/null || echo "$0")

    if [ "$current_script" != "$shortcut_path" ]; then
        echo -e "${GREEN}正在配置快捷命令 'vpn'...${PLAIN}"
        cp "$0" "$shortcut_path"
        chmod +x "$shortcut_path"
        echo -e "${GREEN}快捷命令配置完成！${PLAIN}"
        echo -e "${YELLOW}以后您可以随时在终端输入 ${RED}vpn${YELLOW} 来调出此管理菜单！${PLAIN}"
    fi
}

setup_shortcut
show_menu
