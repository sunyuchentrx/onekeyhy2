#!/bin/bash

CONFIG_FILE="/etc/hy2_nat.conf"

# 自动检测网卡
detect_interface() {
    echo "正在自动检测网卡..."
    IFACE=$(ip -o -4 route show to default | awk '{print $5}')
    echo "检测到默认网卡为: $IFACE"
}

# 保存配置
save_config() {
    echo "IFACE=$IFACE" > $CONFIG_FILE
    echo "RANGE_START=$RANGE_START" >> $CONFIG_FILE
    echo "RANGE_END=$RANGE_END" >> $CONFIG_FILE
    echo "HY2_PORT=$HY2_PORT" >> $CONFIG_FILE
}

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    else
        return 1
    fi
}

# 应用 iptables 规则
apply_iptables() {
    echo "清除旧 NAT 规则..."
    iptables -t nat -F PREROUTING

    echo "应用新的 NAT 转发规则..."
    iptables -t nat -A PREROUTING -i $IFACE -p udp --dport $RANGE_START:$RANGE_END -j REDIRECT --to-ports $HY2_PORT

    echo "保存规则..."
    netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4

    echo "规则已应用并持久化完成！"
}

# 初次配置
setup() {
    detect_interface

    echo -n "请输入端口段开始值 (如 50000): "
    read RANGE_START

    echo -n "请输入端口段结束值 (如 53000): "
    read RANGE_END

    echo -n "请输入 HY2 实际监听端口 (如 36951): "
    read HY2_PORT

    save_config
    apply_iptables

    echo "✔ 初次配置完成"
}

# 修改配置
modify() {
    if load_config; then
        echo "当前配置如下："
        echo "网卡: $IFACE"
        echo "端口段: $RANGE_START - $RANGE_END"
        echo "HY2 监听端口: $HY2_PORT"
        echo ""
    fi

    echo -n "新的端口段开始 (留空则不变): "
    read NEW_RS
    [ -n "$NEW_RS" ] && RANGE_START=$NEW_RS

    echo -n "新的端口段结束 (留空则不变): "
    read NEW_RE
    [ -n "$NEW_RE" ] && RANGE_END=$NEW_RE

    echo -n "新的 HY2 监听端口 (留空则不变): "
    read NEW_HP
    [ -n "$NEW_HP" ] && HY2_PORT=$NEW_HP

    save_config
    apply_iptables

    echo "✔ 修改已立即生效！"
}

install_dependencies() {
    apt update -y
    apt install -y iptables iptables-persistent netfilter-persistent
}

menu() {
    echo "============ HY2 端口跳跃 NAT 管理 ============"
    echo "1) 初次安装配置"
    echo "2) 修改端口段 / 监听端口（立即生效）"
    echo "3) 查看当前配置"
    echo "4) 退出"
    echo "=============================================="
    echo -n "请选择: "
    read OPTION

    case $OPTION in
        1) install_dependencies; setup ;;
        2) modify ;;
        3) load_config && cat $CONFIG_FILE ;;
        4) exit 0 ;;
        *) echo "无效选择" ;;
    esac
}

# 主入口
menu
