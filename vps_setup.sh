#!/bin/bash

# ==========================================
# 综合代理服务器管理脚本
# 包含: SWAP + BBR + Xray (VLESS+Vision+Reality) + Hysteria2 + Acme.sh 证书 + 伪装网站
# 特性: 自动检测安装依赖，支持生成分享 URL 与终端二维码
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 统一错误退出
die() {
    echo -e "${RED}错误: $1${PLAIN}"
    exit 1
}

# 检查上一条命令是否成功
check_last_status() {
    local status=$1
    local message="$2"
    if [ "$status" -ne 0 ]; then
        die "$message"
    fi
}

# 放行防火墙端口
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

# 获取服务器公网 IP
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

# 检查证书文件是否存在
ensure_cert_files() {
    if [ ! -f /etc/certs/fullchain.crt ] || [ ! -f /etc/certs/private.key ]; then
        echo -e "${YELLOW}未检测到 Hysteria2 所需证书，开始自动申请证书...${PLAIN}"
        apply_cert || return 1
    fi
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "必须使用 root 用户运行此脚本！"
    fi
}

# 开启 BBR
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

# 添加 SWAP (2GB)
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

# 安装基础环境及依赖检测
install_base() {
    echo -e "${GREEN}正在检查并安装基础依赖...${PLAIN}"
    local deps=("curl" "wget" "git" "socat" "jq" "qrencode" "lsof")
    local to_install=""
    
    # 检测包管理器
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
    
    # 获取服务器公网 IP (用于生成分享链接)
    SERVER_IP=$(get_public_ip)
    check_last_status $? "无法获取服务器公网 IP，请检查网络连接。"
}

# 申请证书 (Acme.sh)
apply_cert() {
    echo -e "${GREEN}开始申请证书 (用于 Hysteria2)...${PLAIN}"
    
    # 检查 80 端口占用情况
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
    
    # 安装 acme.sh
    curl https://get.acme.sh | sh
    check_last_status $? "acme.sh 安装失败。"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    check_last_status $? "切换 Let's Encrypt CA 失败。"
    
    # 申请证书 (Standalone 模式)
    # 增加 --force 参数，防止重复申请时因为未到期而退出导致后续安装中断
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force
    check_last_status $? "证书申请失败，请确认域名解析与 80 端口状态。"
    
    # 安装证书到 /etc/certs
    mkdir -p /etc/certs
    ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" \
        --fullchainpath /etc/certs/fullchain.crt \
        --keypath /etc/certs/private.key \
        --ecc
    check_last_status $? "证书安装到 /etc/certs 失败。"
        
    echo -e "${GREEN}证书申请完成！存放路径: /etc/certs/${PLAIN}"
}

# 从 GitHub 拉取伪装网站
download_camouflage() {
    echo -e "${GREEN}正在从 GitHub 拉取静态伪装网站...${PLAIN}"
    mkdir -p /var/www/html
    rm -rf /var/www/html/*
    
    # 拉取一个常用的静态模板网站作为伪装
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

# 确保伪装网站目录存在（用于独立安装 Hysteria2）
ensure_camouflage() {
    if [ ! -d "/var/www/html" ] || [ -z "$(ls -A /var/www/html)" ]; then
        echo -e "${YELLOW}未检测到伪装网站文件，正在生成默认页面...${PLAIN}"
        mkdir -p /var/www/html
        echo "<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>It works!</h1></body></html>" > /var/www/html/index.html
    fi
}

# 安装 Xray (VLESS + XTLS-rprx-vision + REALITY)
install_xray() {
    echo -e "${GREEN}正在安装 Xray...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    check_last_status $? "Xray 安装失败。"
    
    # 生成配置所需参数
    UUID=$(/usr/local/bin/xray uuid)
    check_last_status $? "UUID 生成失败，请确认 Xray 是否已正确安装。"
    KEYS=$(/usr/local/bin/xray x25519)
    check_last_status $? "X25519 密钥生成失败，请确认 Xray 是否已正确安装。"
    PRIVATE_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')
    
    read -p "请输入 Xray VLESS 监听端口 (默认 443): " XRAY_PORT
    XRAY_PORT=${XRAY_PORT:-443}
    
    read -p "请输入 REALITY 伪装目标网站 (默认 www.microsoft.com): " DEST_SITE
    DEST_SITE=${DEST_SITE:-www.microsoft.com}

    # 写入 Xray 配置文件
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
            ""
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
    # 修复 Xray 权限问题并启动
    # 判断发行版以使用正确的组名 (Debian/Ubuntu 为 nogroup, CentOS/Fedora 为 nobody)
    if grep -q -E -i "debian|ubuntu" /etc/os-release 2>/dev/null; then
        chown -R nobody:nogroup /usr/local/etc/xray
    else
        chown -R nobody:nobody /usr/local/etc/xray
    fi
    chmod 644 /usr/local/etc/xray/config.json
    
    systemctl restart xray
    sleep 2
    check_last_status $? "Xray 启动命令执行失败。"
    systemctl enable xray >/dev/null 2>&1
    systemctl is-active --quiet xray || die "Xray 服务未处于运行状态。"
    
    # 放行端口
    open_port "$XRAY_PORT" "tcp"
    
    # 生成 VLESS 分享链接
    VLESS_URL="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SITE}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#Xray-Reality"
    
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

# 安装 Hysteria2
install_hysteria2() {
    echo -e "${GREEN}正在安装 Hysteria2...${PLAIN}"
    bash <(curl -fsSL https://get.hy2.sh/)
    check_last_status $? "Hysteria2 安装失败。"
    ensure_cert_files || die "未能准备好 Hysteria2 所需证书。"
    ensure_camouflage
    
    # 如果单独安装，可能不存在 DOMAIN 变量，需要获取
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

    # 写入 Hysteria2 配置文件
    cat > /etc/hysteria/config.yaml <<EOF
listen: :$HY2_PORT

tls:
  cert: /etc/certs/fullchain.crt
  key: /etc/certs/private.key

auth:
  type: password
  password: $HY2_PASS

masquerade:
  type: file
  file:
    dir: /var/www/html
EOF
    systemctl restart hysteria-server.service
    check_last_status $? "Hysteria2 启动失败，请检查配置和证书。"
    systemctl enable hysteria-server.service >/dev/null 2>&1
    systemctl is-active --quiet hysteria-server.service || die "Hysteria2 服务未处于运行状态。"
    
    # 放行端口
    open_port "$HY2_PORT" "udp"
    
    # 生成 Hysteria2 分享链接
    HY2_URL="hy2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}&insecure=0#Hysteria2"
    
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "${GREEN}Hysteria2 安装并配置完成！${PLAIN}"
    echo -e "域名: ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "端口: ${YELLOW}${HY2_PORT}${PLAIN}"
    echo -e "密码: ${YELLOW}${HY2_PASS}${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "分享链接 (URL):"
    echo -e "${YELLOW}${HY2_URL}${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "二维码 (请使用 v2rayN / NekoBox / Shadowrocket 等客户端扫描):"
    echo -n "${HY2_URL}" | qrencode -t ANSIUTF8
    echo -e "${GREEN}===================================================${PLAIN}"
}

# 一键安装所有组件
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

# 一键卸载所有组件
uninstall_all() {
    echo -e "${YELLOW}警告: 此操作将卸载 Xray、Hysteria2、Acme.sh 证书，并清理所有相关配置。${PLAIN}"
    read -p "确定要继续吗？(y/n) " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "已取消卸载。"
        return
    fi
    
    echo -e "${GREEN}正在停止并移除 Xray...${PLAIN}"
    if systemctl is-active --quiet xray; then
        systemctl stop xray
    fi
    systemctl disable xray >/dev/null 2>&1
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
    rm -rf /usr/local/etc/xray
    
    echo -e "${GREEN}正在停止并移除 Hysteria2...${PLAIN}"
    if systemctl is-active --quiet hysteria-server.service; then
        systemctl stop hysteria-server.service
    fi
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
    
    echo -e "${GREEN}卸载与清理完成！(SWAP和BBR加速保留未受影响)${PLAIN}"
}

# 主菜单逻辑
show_menu() {
    clear
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "${YELLOW}        综合代理服务器管理脚本 v1.2        ${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "  1. 一键安装全部 (SWAP+BBR+证书+伪装+Xray+Hysteria2)"
    echo -e "  2. 仅开启 BBR 加速"
    echo -e "  3. 仅添加 SWAP (2GB)"
    echo -e "  4. 仅申请证书 (Acme.sh Standalone 模式)"
    echo -e "  5. 仅从 GitHub 拉取伪装网站"
    echo -e "  6. 仅安装 Xray (VLESS + Vision + Reality)"
    echo -e "  7. 仅安装 Hysteria2"
    echo -e "  8. 一键卸载 (Xray + Hysteria2 + 证书 + 伪装网站)"
    echo -e "  0. 退出脚本"
    echo -e "${GREEN}===================================================${PLAIN}"
    read -p "请输入您的选择 [0-8]: " choice

    case $choice in
        1) install_all ;;
        2) check_root; enable_bbr ;;
        3) check_root; add_swap ;;
        4) check_root; install_base; apply_cert ;;
        5) check_root; install_base; download_camouflage ;;
        6) check_root; install_base; install_xray ;;
        7) check_root; install_base; install_hysteria2 ;;
        8) check_root; uninstall_all ;;
        0) echo "退出脚本。"; exit 0 ;;
        *) echo -e "${RED}输入错误，请重新选择！${PLAIN}"; sleep 2; show_menu ;;
    esac
}

# 安装完成后的快捷命令设置
setup_shortcut() {
    local shortcut_path="/usr/local/bin/vpn"
    if [ ! -f "$shortcut_path" ]; then
        echo -e "${GREEN}正在配置快捷命令 'vpn'...${PLAIN}"
        cp "$0" "$shortcut_path"
        chmod +x "$shortcut_path"
        echo -e "${GREEN}快捷命令配置完成！${PLAIN}"
        echo -e "${YELLOW}以后您可以随时在终端输入 ${RED}vpn${YELLOW} 来调出此管理菜单！${PLAIN}"
    fi
}

# 运行主菜单
setup_shortcut
show_menu
