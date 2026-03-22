#!/bin/bash

# ================= 颜色配置 =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # 恢复默认颜色

# ================= 配置文件 =================
IFACE_FILE="/etc/hy2_iface.conf"
RULES_FILE="/etc/hy2_nat_rules.txt"

# 确保规则文件存在
touch "$RULES_FILE"

# ================= 基础函数 =================
info() { echo -e "${CYAN}[信息]${NC} $1"; }
success() { echo -e "${GREEN}[成功]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; }

# 自动检测并保存网卡 (支持 IPv4 和 IPv6，并兼容旧版修复)
detect_interface() {
    # 尝试读取已有配置
    [ -f "$IFACE_FILE" ] && source "$IFACE_FILE"
    
    # 校验是否成功读取到了双栈网卡配置 (防止旧版本残留)
    if [ -z "$IFACE4" ] || [ -z "$IFACE6" ]; then
        info "正在自动检测系统网络接口..."
        
        # 分别获取 IPv4 和 IPv6 的默认出网网卡
        IFACE4=$(ip -o -4 route show to default | awk '{print $5}' | head -n 1)
        IFACE6=$(ip -o -6 route show to default | awk '{print $5}' | head -n 1)
        
        # 容错处理：如果系统没默认路由，取第一个非回环的网卡
        [ -z "$IFACE4" ] && IFACE4=$(ip link | grep -v 'lo' | awk -F: '/^[0-9]+:/{print $2}' | tr -d ' ' | head -n 1)
        # 如果获取不到 IPv6 路由，默认绑定到跟 IPv4 相同的物理网卡上
        [ -z "$IFACE6" ] && IFACE6=$IFACE4

        # 覆写保存，清除旧版遗留的单栈变量
        echo "IFACE4=$IFACE4" > "$IFACE_FILE"
        echo "IFACE6=$IFACE6" >> "$IFACE_FILE"
    fi
}

# 应用 iptables 和 ip6tables 规则
apply_iptables() {
    detect_interface

    # 清理规则文件中的空行
    sed -i '/^$/d' "$RULES_FILE"

    # ================= IPv4 配置 =================
    if [ -n "$IFACE4" ]; then
        iptables -t nat -N HY2_PREROUTING 2>/dev/null
        iptables -t nat -C PREROUTING -i $IFACE4 -j HY2_PREROUTING 2>/dev/null || \
            iptables -t nat -A PREROUTING -i $IFACE4 -j HY2_PREROUTING
        iptables -t nat -F HY2_PREROUTING
    fi

    # ================= IPv6 配置 =================
    if [ -n "$IFACE6" ]; then
        ip6tables -t nat -N HY2_PREROUTING 2>/dev/null
        ip6tables -t nat -C PREROUTING -i $IFACE6 -j HY2_PREROUTING 2>/dev/null || \
            ip6tables -t nat -A PREROUTING -i $IFACE6 -j HY2_PREROUTING
        ip6tables -t nat -F HY2_PREROUTING
    fi

    # 从文件重新加载并应用所有规则
    if [ -s "$RULES_FILE" ]; then
        while read -r line; do
            [ -z "$line" ] && continue
            RANGE_START=$(echo "$line" | awk '{print $1}')
            RANGE_END=$(echo "$line" | awk '{print $2}')
            HY2_PORT=$(echo "$line" | awk '{print $3}')

            [ -n "$IFACE4" ] && iptables -t nat -A HY2_PREROUTING -p udp --dport $RANGE_START:$RANGE_END -j REDIRECT --to-ports $HY2_PORT
            [ -n "$IFACE6" ] && ip6tables -t nat -A HY2_PREROUTING -p udp --dport $RANGE_START:$RANGE_END -j REDIRECT --to-ports $HY2_PORT
        done < "$RULES_FILE"
    fi

    # 持久化保存
    netfilter-persistent save >/dev/null 2>&1 || {
        iptables-save > /etc/iptables/rules.v4
        ip6tables-save > /etc/iptables/rules.v6
    }
}

# 增加新规则
add_rule() {
    echo -e -n "${CYAN}请输入规则${NC} (格式: ${YELLOW}起始端口-结束端口-目标端口${NC}，例如 36921-37921-36920): "
    read INPUT_STR

    if [ -z "$INPUT_STR" ]; then
        error "输入为空，已放弃添加。"
        return
    fi

    RANGE_START=$(echo "$INPUT_STR" | awk -F'-' '{print $1}')
    RANGE_END=$(echo "$INPUT_STR" | awk -F'-' '{print $2}')
    HY2_PORT=$(echo "$INPUT_STR" | awk -F'-' '{print $3}')

    if [[ "$RANGE_START" =~ ^[0-9]+$ ]] && [[ "$RANGE_END" =~ ^[0-9]+$ ]] && [[ "$HY2_PORT" =~ ^[0-9]+$ ]]; then
        echo "$RANGE_START $RANGE_END $HY2_PORT" >> "$RULES_FILE"
        info "正在应用新规则 (双栈)..."
        apply_iptables
        success "新增规则配置完成！当前转发: $RANGE_START ~ $RANGE_END -> $HY2_PORT"
    else
        error "输入格式错误！请确保格式为【端口-端口-端口】且只包含数字和减号。"
    fi
}

# 查看当前系统生效的规则
view_rules() {
    echo -e "\n${BLUE}================ 当前生效的 IPv4 转发规则 ================${NC}"
    V4_RULES=$(iptables -t nat -L HY2_PREROUTING -n -v --line-numbers 2>/dev/null)
    if [ $? -ne 0 ] || [ $(echo "$V4_RULES" | wc -l) -le 2 ]; then
        echo -e "  ${YELLOW}暂无任何生效的 IPv4 转发规则。${NC}"
    else
        echo "$V4_RULES"
    fi
    
    echo -e "\n${BLUE}================ 当前生效的 IPv6 转发规则 ================${NC}"
    V6_RULES=$(ip6tables -t nat -L HY2_PREROUTING -n -v --line-numbers 2>/dev/null)
    if [ $? -ne 0 ] || [ $(echo "$V6_RULES" | wc -l) -le 2 ]; then
        echo -e "  ${YELLOW}暂无任何生效的 IPv6 转发规则。${NC}"
    else
        echo "$V6_RULES"
    fi
    echo -e "${BLUE}==========================================================${NC}\n"
}

# 按行号删除规则
delete_rule() {
    view_rules
    echo -e -n "${CYAN}请输入要删除的规则行号${NC} (即列表中的 num 值，输入 ${YELLOW}0${NC} 取消): "
    read LINE_NUM

    if [[ "$LINE_NUM" =~ ^[0-9]+$ ]] && [ "$LINE_NUM" -gt 0 ]; then
        sed -i "${LINE_NUM}d" "$RULES_FILE"
        info "正在删除并刷新系统双栈规则..."
        apply_iptables
        success "第 $LINE_NUM 行规则已成功删除！"
    elif [ "$LINE_NUM" -eq 0 ]; then
        info "已取消删除。"
    else
        error "无效的行号！"
    fi
}

# 清空所有规则
clear_rules() {
    echo -e -n "${RED}⚠️  确定要清空所有 HY2 转发规则吗？${NC}(y/n): "
    read confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        > "$RULES_FILE"
        apply_iptables
        success "所有 HY2 转发规则已清空！"
    else
        info "已取消清空操作。"
    fi
}

# 安装依赖并开启系统转发
install_dependencies() {
    info "开始更新软件源并安装依赖..."
    apt update -y > /dev/null 2>&1
    
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    
    DEBIAN_FRONTEND=noninteractive apt install -y iptables iptables-persistent netfilter-persistent > /dev/null 2>&1
    
    info "配置系统内核，开启 IPv4 和 IPv6 转发..."
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.all.forwarding/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    
    success "依赖安装及系统网络转发配置全部完成！"
}

# 主菜单界面
menu() {
    echo -e "${CYAN}================================================${NC}"
    echo -e "${GREEN}       HY2 端口跳跃 NAT 管理脚本 (双栈美化版)    ${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo -e " ${YELLOW}1.${NC} 安装依赖与环境配置 (首次使用必选)"
    echo -e " ${YELLOW}2.${NC} 增加一条端口转发规则 (格式: A-B-C)"
    echo -e " ${YELLOW}3.${NC} 查看当前所有规则 (真实系统状态)"
    echo -e " ${YELLOW}4.${NC} 删除单条规则 (按行号)"
    echo -e " ${YELLOW}5.${NC} 清空所有规则"
    echo -e " ${YELLOW}6.${NC} 退出"
    echo -e "${CYAN}================================================${NC}"
    echo -e -n "请输入对应数字以选择功能: "
    read OPTION

    case $OPTION in
        1) install_dependencies; detect_interface ;;
        2) add_rule ;;
        3) view_rules ;;
        4) delete_rule ;;
        5) clear_rules ;;
        6) echo -e "${GREEN}感谢使用，再见！${NC}"; exit 0 ;;
        *) error "无效的选项，请重新输入！" ;;
    esac
}

# 后台静默预加载网卡信息
detect_interface >/dev/null 2>&1

# 循环主程序
while true; do
    menu
    echo ""
done
