#!/bin/bash
# =============================================
# Debian/Ubuntu MTU 管理工具（菜单式）
# 支持 NetworkManager、systemd-networkd、传统 interfaces
# 用法:
#   sudo ./mtu.sh              进入交互菜单
#   sudo ./mtu.sh [接口] [MTU] 直接设置（兼容旧用法）
# =============================================

# 交互菜单需要容错，不使用 set -e
set -o pipefail

# ================== 配置区 ==================
DEFAULT_MTU=1450
# 格式: MTU值|说明
COMMON_MTUS=(
    "1500|标准以太网"
    "1492|PPPoE"
    "1450|VPN 常用"
    "1400|保守值"
    "1280|WireGuard/IPv6 推荐"
)
PROBE_TARGET="8.8.8.8"
IF_FILE=/etc/network/interfaces
DHCLIENT_FILE=/etc/dhcp/dhclient-mtu.conf
# =============================================

# 使用 $'' 让变量直接保存真实转义字符，这样在 heredoc 里也能正常着色
RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[1;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo "${RED}❌ 错误: 请使用 sudo 运行此脚本${RESET}"
    echo "用法示例: sudo $0 ens3 1450"
    exit 1
fi

# ---------- 通用函数 ----------

pause() {
    echo
    read -rp "按回车键返回主菜单..." _
}

# 除 lo 外的所有网卡
list_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v '^lo$'
}

mtu_of() {
    ip -o link show "$1" 2>/dev/null | grep -oP 'mtu \K[0-9]+'
}

state_of() {
    ip -o link show "$1" 2>/dev/null | grep -oP 'state \K\w+'
}

# 返回当前生效的网络管理后端: NetworkManager / systemd-networkd / interfaces / dhclient
detect_backend() {
    if systemctl is-active --quiet NetworkManager; then
        echo "NetworkManager"
    elif systemctl is-active --quiet systemd-networkd; then
        echo "systemd-networkd"
    elif [[ -f $IF_FILE ]]; then
        echo "interfaces"
    else
        echo "dhclient"
    fi
}

validate_interface() {
    if ! ip link show "$1" &>/dev/null; then
        echo "${RED}❌ 错误: 接口 $1 不存在${RESET}"
        return 1
    fi
}

validate_mtu() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || (( $1 < 68 || $1 > 9000 )); then
        echo "${RED}❌ 错误: MTU 必须是 68-9000 之间的整数${RESET}"
        return 1
    fi
}

# NetworkManager: 查出接口对应的活动连接名
nm_conn_of() {
    nmcli -t -f NAME,DEVICE connection show --active |
        awk -F: -v dev="$1" '$2==dev {print $1}'
}

# NetworkManager: 设置连接 MTU（传 0 表示恢复 auto），有线失败则按无线再试
nm_set_mtu() {
    nmcli connection modify "$1" 802-3-ethernet.mtu "$2" 2>/dev/null ||
        nmcli connection modify "$1" 802-11-wireless.mtu "$2" 2>/dev/null
}

backup_if_file() {
    cp "$IF_FILE" "$IF_FILE.mtu.bak.$(date +%F-%H%M%S)"
}

# 删除 interfaces 中指定接口段内已有的 mtu 行，避免重复叠加
if_file_del_mtu() {
    sed -i "/^iface $1/,/^$/{/^[[:space:]]*mtu /d}" "$IF_FILE"
}

# 未指定接口时让用户选择，结果写入全局 SELECTED_IF
choose_interface() {
    local ifaces=() i idx name
    mapfile -t ifaces < <(list_interfaces)

    if (( ${#ifaces[@]} == 0 )); then
        echo "${RED}❌ 未找到任何可用网卡${RESET}"
        return 1
    fi

    echo "${BOLD}可用网卡：${RESET}"
    for i in "${!ifaces[@]}"; do
        name="${ifaces[$i]}"
        printf "  %d) %-14s MTU=%-6s %s\n" \
            "$((i+1))" "$name" "$(mtu_of "$name")" "$(state_of "$name")"
    done
    echo

    read -rp "请选择网卡编号 [1]: " idx
    idx=${idx:-1}
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#ifaces[@]} )); then
        echo "${RED}❌ 无效的选择${RESET}"
        return 1
    fi

    SELECTED_IF="${ifaces[$((idx-1))]}"
}

# 从常用值菜单中选择 MTU，结果写入全局 SELECTED_MTU
choose_mtu() {
    local i choice entry
    echo
    echo "${BOLD}常用 MTU 推荐值：${RESET}"
    for i in "${!COMMON_MTUS[@]}"; do
        entry="${COMMON_MTUS[$i]}"
        echo "  $((i+1))) ${entry%%|*} (${entry#*|})"
    done
    echo "  0) 自定义"

    read -rp "请选择 [3]: " choice
    choice=${choice:-3}

    if [[ "$choice" == "0" ]]; then
        read -rp "请输入自定义 MTU (68-9000): " SELECTED_MTU
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#COMMON_MTUS[@]} )); then
        entry="${COMMON_MTUS[$((choice-1))]}"
        SELECTED_MTU="${entry%%|*}"
    else
        echo "${RED}❌ 无效的选择${RESET}"
        return 1
    fi

    validate_mtu "$SELECTED_MTU"
}

# ---------- 功能 1: 查看 MTU ----------

show_mtu() {
    local name mtu ipaddr backend conn dev found

    echo "${CYAN}=== 网卡 MTU 一览 ===${RESET}"
    echo
    printf "${BOLD}%-16s %-8s %-10s %s${RESET}\n" "接口" "MTU" "状态" "IPv4 地址"
    printf '%.0s-' {1..60}; echo

    while read -r name; do
        ipaddr=$(ip -4 -o addr show "$name" 2>/dev/null | awk '{print $4}' | paste -sd ',' -)
        printf "%-16s %-8s %-10s %s\n" \
            "$name" "$(mtu_of "$name")" "$(state_of "$name")" "${ipaddr:--}"
    done < <(list_interfaces)

    # lo 单独列出，方便对照但不参与设置
    mtu=$(mtu_of lo)
    [[ -n "$mtu" ]] && printf "%-16s %-8s %-10s %s\n" "lo" "$mtu" "UNKNOWN" "127.0.0.1/8"

    backend=$(detect_backend)
    echo
    echo "当前网络管理后端: ${GREEN}${backend}${RESET}"
    echo
    echo "${BOLD}持久化配置中的 MTU：${RESET}"

    case "$backend" in
        NetworkManager)
            while IFS=: read -r conn dev; do
                [[ -z "$dev" || "$dev" == "lo" ]] && continue
                echo "  $dev ($conn): $(nmcli -g 802-3-ethernet.mtu connection show "$conn" 2>/dev/null || echo auto)"
            done < <(nmcli -t -f NAME,DEVICE connection show --active)
            ;;
        systemd-networkd)
            found=$(grep -H "MTUBytes" /etc/systemd/network/*.network 2>/dev/null)
            echo "${found:-  未找到设置了 MTUBytes 的 .network 文件}"
            ;;
        interfaces)
            found=$(grep -nE "^[[:space:]]*(iface|mtu)" "$IF_FILE" 2>/dev/null | sed 's/^/  /')
            echo "${found:-  未找到相关配置}"
            ;;
        dhclient)
            found=$(sed 's/^/  /' "$DHCLIENT_FILE" 2>/dev/null)
            echo "${found:-  未找到 $DHCLIENT_FILE}"
            ;;
    esac
}

# ---------- 功能 2: 设置 MTU ----------

apply_mtu() {
    local iface="$1" mtu="$2" backend conn reconnect

    echo
    echo "🚀 正在设置接口 ${GREEN}${iface}${RESET} 的 MTU 为 ${GREEN}${mtu}${RESET} ..."

    if ip link set dev "$iface" mtu "$mtu" 2>/dev/null; then
        echo "${GREEN}✅ 当前 MTU 已立即更新${RESET}"
    else
        echo "${YELLOW}⚠️  无法立即设置（接口可能为 down 状态或不支持该 MTU）${RESET}"
    fi

    backend=$(detect_backend)
    echo
    echo "📁 正在写入持久化配置（后端: $backend）..."

    case "$backend" in
        NetworkManager)
            conn=$(nm_conn_of "$iface")
            if [[ -z "$conn" ]]; then
                echo "${YELLOW}⚠️  未找到 $iface 对应的活动连接，跳过持久化${RESET}"
            else
                nm_set_mtu "$conn" "$mtu"
                echo "${GREEN}✅ NetworkManager 配置已更新 ($conn)${RESET}"
                read -rp "是否立即重连应用？(y/N): " reconnect
                if [[ "$reconnect" =~ ^[Yy]$ ]]; then
                    nmcli connection down "$conn" && nmcli connection up "$conn"
                fi
            fi
            ;;

        systemd-networkd)
            cat > "/etc/systemd/network/50-mtu-$iface.network" << EOF
[Match]
Name=$iface

[Link]
MTUBytes=$mtu
RequiredForOnline=no
EOF
            systemctl restart systemd-networkd
            echo "${GREEN}✅ 已创建 /etc/systemd/network/50-mtu-$iface.network${RESET}"
            ;;

        interfaces)
            backup_if_file
            if grep -q "^iface $iface" "$IF_FILE"; then
                if_file_del_mtu "$iface"
                sed -i "/^iface $iface/a\\    mtu $mtu" "$IF_FILE"
            else
                cat >> "$IF_FILE" << EOF

auto $iface
iface $iface inet dhcp
    mtu $mtu
EOF
            fi
            echo "${GREEN}✅ $IF_FILE 已更新（已备份）${RESET}"
            read -rp "是否重启 networking 服务？(y/N): " reconnect
            [[ "$reconnect" =~ ^[Yy]$ ]] && systemctl restart networking 2>/dev/null
            ;;

        dhclient)
            echo "${YELLOW}⚠️  使用备用方案（dhclient）${RESET}"
            cat > "$DHCLIENT_FILE" << EOF
interface "$iface" {
    supersede interface-mtu $mtu;
    default interface-mtu $mtu;
}
EOF
            echo "已创建 $DHCLIENT_FILE，请确保 dhclient.conf 包含它"
            ;;
    esac

    echo
    echo "🎉 设置完成！当前状态："
    ip -4 addr show "$iface" | grep -E "mtu |inet "
}

# $1 可选：固定 MTU（用于"恢复默认"），不传则让用户从菜单选
set_mtu_flow() {
    local mtu="$1"

    if [[ -n "$mtu" ]]; then
        echo "${CYAN}=== 恢复默认 MTU $mtu ===${RESET}"
    else
        echo "${CYAN}=== 设置网卡 MTU ===${RESET}"
    fi
    echo

    choose_interface || return 1
    if [[ -z "$mtu" ]]; then
        choose_mtu || return 1
        mtu="$SELECTED_MTU"
    fi
    apply_mtu "$SELECTED_IF" "$mtu"
}

# ---------- 功能 3: 探测最佳 MTU ----------

probe_mtu() {
    local target payload low=1200 high=1500 best=0 mid ans

    echo "${CYAN}=== 探测最佳 MTU ===${RESET}"
    echo
    echo "通过发送不分片 ICMP 包，二分查找链路能通过的最大包体大小。"
    read -rp "探测目标 [$PROBE_TARGET]: " target
    target=${target:-$PROBE_TARGET}

    if ! ping -c 1 -W 2 "$target" &>/dev/null; then
        echo "${RED}❌ 目标 $target 不可达（或 ICMP 被拦截），无法探测${RESET}"
        return 1
    fi

    echo
    echo "正在探测，请稍候..."
    while (( low <= high )); do
        mid=$(( (low + high) / 2 ))
        payload=$(( mid - 28 ))  # IP 头 20 + ICMP 头 8
        if ping -c 1 -W 2 -M do -s "$payload" "$target" &>/dev/null; then
            best=$mid
            low=$(( mid + 1 ))
        else
            high=$(( mid - 1 ))
        fi
    done

    if (( best == 0 )); then
        echo "${RED}❌ 探测失败：即使 1200 字节也无法通过，链路可能拦截了不分片包${RESET}"
        return 1
    fi

    echo
    echo "${GREEN}✅ 探测结果: 最大可通过 MTU = ${best}${RESET}"
    echo "   （PPPoE 环境建议再减 8；WireGuard 隧道内建议再减 60-80）"

    read -rp "是否将某张网卡设置为 $best？(y/N): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        choose_interface || return 1
        apply_mtu "$SELECTED_IF" "$best"
    fi
}

# ---------- 功能 4: 清理持久化配置 ----------

clean_persist() {
    local backend conn files=() confirm

    echo "${CYAN}=== 移除本脚本写入的持久化配置 ===${RESET}"
    echo
    backend=$(detect_backend)
    echo "当前后端: $backend"

    case "$backend" in
        NetworkManager)
            choose_interface || return 1
            conn=$(nm_conn_of "$SELECTED_IF")
            if [[ -z "$conn" ]]; then
                echo "${YELLOW}⚠️  未找到对应的活动连接${RESET}"
                return 1
            fi
            nm_set_mtu "$conn" 0
            echo "${GREEN}✅ 已将 $conn 的 MTU 恢复为 auto${RESET}"
            ;;

        systemd-networkd)
            mapfile -t files < <(compgen -G "/etc/systemd/network/50-mtu-*.network")
            if (( ${#files[@]} == 0 )); then
                echo "没有本脚本创建的配置文件"
                return 0
            fi
            printf '%s\n' "${files[@]}"
            read -rp "确认删除以上文件？(y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -f "${files[@]}"
                systemctl restart systemd-networkd
                echo "${GREEN}✅ 已删除并重启 systemd-networkd${RESET}"
            fi
            ;;

        interfaces)
            choose_interface || return 1
            grep -nE "^[[:space:]]*mtu " "$IF_FILE" | sed 's/^/  /' || echo "  无 mtu 配置"
            read -rp "确认删除 $SELECTED_IF 段内的 mtu 行？(y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                backup_if_file
                if_file_del_mtu "$SELECTED_IF"
                echo "${GREEN}✅ 已删除（原文件已备份），重启后生效${RESET}"
            fi
            ;;

        dhclient)
            if [[ ! -f "$DHCLIENT_FILE" ]]; then
                echo "没有找到需要清理的文件"
                return 0
            fi
            read -rp "确认删除 $DHCLIENT_FILE？(y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -f "$DHCLIENT_FILE"
                echo "${GREEN}✅ 已删除${RESET}"
            fi
            ;;
    esac
}

# ---------- 功能 5: 测试建议 ----------

show_tips() {
    cat << 'EOF'
=== MTU 测试与排错建议 ===

1) 测试是否分片（payload = MTU - 28）：
     ping -M do -s 1472 8.8.8.8    # 对应 MTU 1500
     ping -M do -s 1422 8.8.8.8    # 对应 MTU 1450
   若提示 "Message too long" / "需要分片"，说明当前 MTU 过大。

2) 查看接口 MTU：
     ip link show
     ip -brief link show

3) 常见场景参考值：
     标准以太网          1500
     PPPoE 拨号          1492
     PPTP / L2TP VPN     1400-1450
     WireGuard           1280-1420
     GRE 隧道            1476

4) MTU 过大的典型症状：
   能 ping 通但网页打不开、SSH 登录后卡住、大文件下载中断。
EOF
}

# ---------- 主菜单 ----------

main_menu() {
    local choice
    while true; do
        clear
        cat << EOF
${CYAN}╔══════════════════════════════════════════════╗
║          Debian MTU 管理工具  v2.0           ║
╚══════════════════════════════════════════════╝${RESET}

  1) 查看网卡 MTU 值
  2) 设置网卡 MTU
  3) 探测最佳 MTU（自动二分查找）
  4) 恢复默认 MTU 1500
  5) 移除持久化配置
  6) 查看测试建议
  0) 退出

EOF
        read -rp "请输入选项 [0-6]: " choice
        echo

        case "$choice" in
            1) show_mtu; pause ;;
            2) set_mtu_flow; pause ;;
            3) probe_mtu; pause ;;
            4) set_mtu_flow 1500; pause ;;
            5) clean_persist; pause ;;
            6) show_tips; pause ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo "${RED}❌ 无效选项${RESET}"; sleep 1 ;;
        esac
    done
}

# ---------- 入口 ----------

# 兼容旧的命令行用法: sudo ./mtu.sh [接口] [MTU]
if [[ -n "$1" ]]; then
    case "$1" in
        -h|--help)
            echo "用法:"
            echo "  sudo $0                进入交互菜单"
            echo "  sudo $0 <接口> [MTU]   直接设置（MTU 默认 $DEFAULT_MTU）"
            exit 0
            ;;
    esac

    validate_interface "$1" || exit 1
    validate_mtu "${2:-$DEFAULT_MTU}" || exit 1
    apply_mtu "$1" "${2:-$DEFAULT_MTU}"
    echo
    echo "如需恢复默认 MTU 1500，运行：sudo $0 $1 1500"
    exit 0
fi

main_menu
