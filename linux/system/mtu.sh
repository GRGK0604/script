#!/bin/bash
# Debian 系统专用 MTU 设置脚本

if [ $# -ne 2 ]; then
    echo "用法: $0 <网络接口名> <MTU值>"
    echo "示例: $0 ens3 1460"
    exit 1
fi

IFACE=$1
MTU=$2

# 1. 检查接口是否存在
if ! ip link show "$IFACE" > /dev/null 2>&1; then
    echo "错误: 网络接口 $IFACE 不存在。"
    exit 1
fi

# 2. 临时修改，立即生效
echo "正在临时修改 $IFACE 的 MTU 为 $MTU ..."
sudo ip link set dev "$IFACE" mtu "$MTU"

# 3. 永久修改，写入配置文件
echo "正在将配置写入 /etc/network/interfaces ..."
# 检查是否已存在该接口的配置
if grep -q "^iface .* inet .* $IFACE" /etc/network/interfaces; then
    # 如果存在，在接口配置段内添加或修改 mtu 行
    sudo sed -i "/^iface .* inet .* $IFACE/,/^$/ { /mtu /d; }" /etc/network/interfaces
    sudo sed -i "/^iface .* inet .* $IFACE/a\    mtu $MTU" /etc/network/interfaces
else
    echo "警告: 在 /etc/network/interfaces 中未找到 $IFACE 的配置，请手动添加。"
fi

echo "完成！当前 MTU 值："
ip link show "$IFACE" | grep mtu
