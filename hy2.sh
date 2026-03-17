#!/bin/bash

# 配置文件拆分为网卡配置和规则列表
IFACE_FILE="/etc/hy2_iface.conf"
RULES_FILE="/etc/hy2_nat_rules.txt"

# 自动检测并保存网卡
detect_interface() {
    if [ -f "$IFACE_FILE" ]; then
        source "$IFACE_FILE"
    else
        echo "正在自动检测网卡..."
        # 提取网卡名称并取第一行，防止有多条默认路由报错
        IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n 1)
        echo "检测到默认网卡为: $IFACE"
        echo "IFACE=$IFACE" > "$IFACE_FILE"
    fi
}

# 应用 iptables 规则 (重构：使用安全独立的自定义链)
apply_iptables() {
    detect_interface

    # 1. 创建 HY2 专属链，防止清理掉系统其他重要 NAT 规则
    iptables -t nat -N HY2_PREROUTING 2>/dev/null
    
    # 2. 将专属链引入主 PREROUTING 链 (如果不存在则添加)
    iptables -t nat -C PREROUTING -i $IFACE -j HY2_PREROUTING 2>/dev/null || \
    iptables -t nat -A PREROUTING -i $IFACE -j HY2_PREROUTING

    # 3. 安全清空我们自己的专属链（不会影响其他软件）
    echo "正在刷新 HY2 转发规则..."
    iptables -t nat -F HY2_PREROUTING

    # 4. 从文件加载并应用所有规则
    if [ -f "$RULES_FILE" ]; then
        while read -r line; do
            # 忽略空行
            [ -z "$line" ] && continue
            
            # 解析文本中的配置
            RANGE_START=$(echo "$line" | awk '{print $1}')
            RANGE_END=$(echo "$line" | awk '{print $2}')
            HY2_PORT=$(echo "$line" | awk '{print $3}')

            echo " -> 应用规则: 端口段 $RANGE_START:$RANGE_END 转发至 $HY2_PORT"
            iptables -t nat -A HY2_PREROUTING -p udp --dport $RANGE_START:$RANGE_END -j REDIRECT --to-ports $HY2_PORT
        done < "$RULES_FILE"
    fi

    echo "正在保存 iptables 规则..."
    netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4
    echo "✔ 规则已全部应用并持久化完成！"
}

# 增加新规则
add_rule() {
    detect_interface

    echo -n "请输入端口段开始值 (如 50000): "
    read RANGE_START
    echo -n "请输入端口段结束值 (如 53000): "
    read RANGE_END
    echo -n "请输入 HY2 实际监听端口 (如 36951): "
    read HY2_PORT

    if [ -n "$RANGE_START" ] && [ -n "$RANGE_END" ] && [ -n "$HY2_PORT" ]; then
        # 将新规则追加到文件中
        echo "$RANGE_START $RANGE_END $HY2_PORT" >> "$RULES_FILE"
        apply_iptables
        echo "✔ 新增规则配置完成！"
    else
        echo "输入有空值，已放弃添加。"
    fi
}

# 清空所有规则
clear_rules() {
    echo -n "⚠️ 确定要清空所有 HY2 转发规则吗？(y/n): "
    read confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        > "$RULES_FILE"  # 清空文件内容
        apply_iptables
        echo "✔ 所有 HY2 转发规则已清空！"
    fi
}

# 查看当前规则
view_rules() {
    detect_interface
    echo ""
    echo "当前绑定的网卡: $IFACE"
    echo "========= 当前生效的转发规则 ========="
    if [ -s "$RULES_FILE" ]; then
        printf "%-15s %-15s %-15s\n" "起始端口" "结束端口" "目标端口"
        echo "----------------------------------------------"
        while read -r rs re hp; do
            [ -z "$rs" ] && continue
            printf "%-15s %-15s %-15s\n" "$rs" "$re" "$hp"
        done < "$RULES_FILE"
    else
        echo "暂无任何转发规则。"
    fi
    echo "======================================"
    echo ""
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
    echo "3) 查看当前所有规则"
    echo "4) 清空所有规则"
    echo "5) 退出"
    echo "==============================================="
    echo -n "请选择: "
    read OPTION

    case $OPTION in
        1) install_dependencies; detect_interface ;;
        2) add_rule ;;
        3) view_rules ;;
        4) clear_rules ;;
        5) exit 0 ;;
        *) echo "无效选择" ;;
    esac
}

# 主入口，使用循环让脚本执行完毕后回到菜单
while true; do
    menu
    echo ""
done
