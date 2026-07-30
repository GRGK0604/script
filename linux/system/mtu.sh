#!/bin/bash
# =============================================
# Debian/Ubuntu 一键 MTU 设置脚本
# 支持 NetworkManager、systemd-networkd、传统 interfaces
# 用法: sudo ./set-mtu.sh [接口] [MTU]
# =============================================

set -e

# ================== 配置区 ==================
DEFAULT_MTU=1450
COMMON_MTUS=(1500 1492 1450 1400 1280)

# =============================================

if [[ $EUID -ne 0 ]]; then
    echo "❌ 错误: 请使用 sudo 运行此脚本"
    echo "用法示例: sudo $0 ens3 1450"
    exit 1
fi

echo "=== Debian MTU 一键设置工具 ==="

# 参数解析
INTERFACE="$1"
MTU="${2:-$DEFAULT_MTU}"

if [[ -z "$INTERFACE" ]]; then
    echo "当前网络接口状态："
    ip -brief link show | grep -v " LOOPBACK"
    echo
    read -rp "请输入要设置 MTU 的接口名称 (如 ens3, eth0, enp1s0): " INTERFACE
fi

# 验证接口
if ! ip link show "$INTERFACE" &>/dev/null; then
    echo "❌ 错误: 接口 $INTERFACE 不存在"
    exit 1
fi

# 如果没通过参数传 MTU，则显示菜单
if [[ -z "$2" ]]; then
    echo -e "\n常用 MTU 推荐值："
    for i in "${!COMMON_MTUS[@]}"; do
        case ${COMMON_MTUS[$i]} in
            1500) desc="(标准)" ;;
            1492) desc="(PPPoE)" ;;
            1450) desc="(VPN 常用)" ;;
            1400) desc="(保守值)" ;;
            1280) desc="(WireGuard 推荐)" ;;
            *) desc="" ;;
        esac
        echo "  $((i+1))) ${COMMON_MTUS[$i]} $desc"
    done
    echo "  0) 自定义"
    read -rp "请选择 [3]: " choice
    choice=${choice:-3}
    
    if [[ "$choice" -eq 0 ]]; then
        read -rp "请输入自定义 MTU (68-9000): " MTU
    elif [[ "$choice" -ge 1 && "$choice" -le ${#COMMON_MTUS[@]} ]]; then
        MTU=${COMMON_MTUS[$((choice-1))]}
    fi
fi

# MTU 合法性检查
if ! [[ "$MTU" =~ ^[0-9]+$ ]] || [ "$MTU" -lt 68 ] || [ "$MTU" -gt 9000 ]; then
    echo "❌ 错误: MTU 必须是 68-9000 之间的整数"
    exit 1
fi

echo -e "\n🚀 正在设置接口 \033[1;32m$INTERFACE\033[0m 的 MTU 为 \033[1;32m$MTU\033[0m ..."

# 1. 立即生效
if ip link set dev "$INTERFACE" mtu "$MTU" 2>/dev/null; then
    echo "✅ 当前 MTU 已立即更新"
else
    echo "⚠️  无法立即设置（接口可能为 down 状态）"
fi

# 2. 持久化配置
echo -e "\n📁 正在写入持久化配置..."

if systemctl is-active --quiet NetworkManager; then
    echo "检测到: NetworkManager"
    CONN=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$INTERFACE" '$2==dev {print $1}')
    if [[ -n "$CONN" ]]; then
        nmcli connection modify "$CONN" 802-3-ethernet.mtu "$MTU" 2>/dev/null || \
        nmcli connection modify "$CONN" 802-11-wireless.mtu "$MTU" 2>/dev/null
        echo "✅ NetworkManager 配置已更新 ($CONN)"
        read -rp "是否立即重连应用？(y/N): " reconnect
        [[ "$reconnect" =~ ^[Yy]$ ]] && nmcli connection down "$CONN" && nmcli connection up "$CONN"
    fi

elif systemctl is-active --quiet systemd-networkd; then
    echo "检测到: systemd-networkd"
    cat > "/etc/systemd/network/50-mtu-$INTERFACE.network" << EOF
[Match]
Name=$INTERFACE

[Link]
MTUBytes=$MTU
RequiredForOnline=no
EOF
    systemctl restart systemd-networkd
    echo "✅ 已创建 systemd-networkd 配置"

elif [ -f /etc/network/interfaces ]; then
    echo "检测到: /etc/network/interfaces"
    cp /etc/network/interfaces "/etc/network/interfaces.mtu.bak.$(date +%F-%H%M%S)"
    if grep -q "^iface $INTERFACE" /etc/network/interfaces; then
        sed -i "/^iface $INTERFACE/a\    mtu $MTU" /etc/network/interfaces
    else
        cat >> /etc/network/interfaces << EOF

auto $INTERFACE
iface $INTERFACE inet dhcp
    mtu $MTU
EOF
    fi
    echo "✅ /etc/network/interfaces 已更新（已备份）"
    systemctl restart networking 2>/dev/null || true

else
    echo "⚠️  使用备用方案（dhclient）"
    cat > "/etc/dhcp/dhclient-mtu.conf" << EOF
interface "$INTERFACE" {
    supersede interface-mtu $MTU;
    default interface-mtu $MTU;
}
EOF
    echo "已创建 /etc/dhcp/dhclient-mtu.conf，请确保 dhclient.conf 包含它"
fi

echo -e "\n🎉 设置完成！当前状态："
ip -4 addr show "$INTERFACE" | grep -E "mtu |inet "
echo -e "\n💡 测试建议："
echo "   ping -M do -s 1472 8.8.8.8     # 不分片 = 最佳"
echo "   ip link show $INTERFACE"
echo -e "\n如需恢复默认 MTU 1500，运行：sudo $0 $INTERFACE 1500"
