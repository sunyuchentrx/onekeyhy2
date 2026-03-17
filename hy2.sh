#!/bin/bash

# 配置文件
IFACE_FILE="/etc/hy2_iface.conf"
RULES_FILE="/etc/hy2_nat_rules.txt"

# 确保规则文件存在
touch "$RULES_FILE"

# 自动检测并保存网卡
detect_interface() {
    if [ -f "$IFACE_FILE" ]; then
        source "$IFACE_FILE"
    else
        echo "正在自动检测网卡..."
        IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n 1)
        echo "检测到默认网卡为: $IFACE"
        echo "IFACE=$IFACE" > "$IFACE_FILE"
    fi
}

# 应用 iptables 规则
apply_iptables() {
    detect_interface

    # 清理规则文件中的空行，保证行号与 iptables 输出完全一致
    sed -i '/^$/d' "$RULES_FILE"

    # 1. 创建并引入 HY2 专属链
    iptables -t nat -N HY2_PREROUTING 2>/dev/null
    iptables -t nat -C PREROUTING -i $IFACE -j HY2_PREROUTING 2>/dev/null || \
    iptables -t nat -A PREROUTING -i $IFACE -j HY2_PREROUTING

    # 2. 安全清空专属链
    iptables -t nat -F HY2_PREROUTING

    # 3. 从文件重新加载并应用所有规则
    if [ -s "$RULES_FILE" ]; then
        while read -r line; do
            [ -z "$line" ] && continue
            RANGE_START=$(echo "$line" | awk '{print $1}')
            RANGE_END=$(echo "$line" | awk '{print $2}')
            HY2_PORT=$(echo "$line" | awk '{print $3}')
            
            iptables -t nat -A HY2_PREROUTING -p udp --dport $RANGE_START:$RANGE_END -j REDIRECT --to-ports $HY2_PORT
        done < "$RULES_FILE"
    fi

    # 4. 持久化保存
    netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4
}

# 增加新规则
add_rule() {
    echo -n "请输入端口段开始值 (如 50000): "
    read RANGE_START
    echo -n "请输入端口段结束值 (如 53000): "
    read RANGE_END
    echo -n "请输入 HY2 实际监听端口 (如 36951): "
    read HY2_PORT

    if [ -n "$RANGE_START" ] && [ -n "$RANGE_END" ] && [ -n "$HY2_PORT" ]; then
        echo "$RANGE_START $RANGE_END $HY2_PORT" >> "$RULES_FILE"
        echo "正在应用新规则..."
        apply_iptables
        echo "✔ 新增规则配置完成！"
    else
        echo "❌ 输入有空值，已放弃添加。"
    fi
}

# 查看当前系统生效的规则
view_rules() {
    echo ""
    echo "========= 当前系统底层生效的转发规则 ========="
    # 直接调用 iptables 命令查看真实生效的规则
    iptables -t nat -L HY2_PREROUTING -n -v --line-numbers 2>/dev/null
    
    # 如果命令执行失败或没有任何输出，说明链没建好或没规则
    if [ $? -ne 0 ] || [ $(iptables -t nat -L HY2_PREROUTING -n 2>/dev/null | wc -l) -le 2 ]; then
        echo "  暂无任何生效的转发规则。"
    fi
    echo "=============================================="
    echo ""
}

# 按行号删除规则
delete_rule() {
    view_rules
    echo -n "请输入要删除的规则行号 (即最左侧的 num 值，输入 0 取消): "
    read LINE_NUM

    if [[ "$LINE_NUM" =~ ^[0-9]+$ ]] && [ "$LINE_NUM" -gt 0 ]; then
        # 从文本文件中删除对应行
        sed -i "${LINE_NUM}d" "$RULES_FILE"
        echo "正在删除并刷新系统规则..."
        apply_iptables
        echo "✔ 第 $LINE_NUM 行规则已成功删除！"
    elif [ "$LINE_NUM" -eq 0 ]; then
        echo "已取消删除。"
    else
        echo "❌ 无效的行号！"
    fi
}

# 清空所有规则
clear_rules() {
    echo -n "⚠️ 确定要清空所有 HY2 转发规则吗？(y/n): "
    read confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        > "$RULES_FILE"
        apply_iptables
        echo "✔ 所有 HY2 转发规则已清空！"
    fi
}

install_dependencies() {
    apt update -y
    apt install -y iptables iptables-persistent netfilter-persistent
    echo "✔ 依赖安装完成！"
}

menu() {
    echo "============ HY2 端口跳跃 NAT 管理 ============"
    echo "1) 安装依赖 (首次使用需运行)"
    echo "2) 增加一条端口转发规则 (可无限叠加)"
    echo "3) 查看当前所有规则 (真实系统状态)"
    echo "4) 删除单条规则 (按行号)"
    echo "5) 清空所有规则"
    echo "6) 退出"
    echo "==============================================="
    echo -n "请选择: "
    read OPTION

    case $OPTION in
        1) install_dependencies; detect_interface ;;
        2) add_rule ;;
        3) view_rules ;;
        4) delete_rule ;;
        5) clear_rules ;;
        6) exit 0 ;;
        *) echo "无效选择" ;;
    esac
}

# 确保每次回到菜单前都有网卡信息
detect_interface >/dev/null 2>&1

while true; do
    menu
    echo ""
done
