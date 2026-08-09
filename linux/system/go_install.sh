#!/bin/bash

# ============================================================
# 交互式 Go 安装/更新/卸载脚本（无备份版）
# 功能：
#   1. 安装 Go（安装最新稳定版）
#   2. 更新 Go（升级到最新稳定版）
#   3. 卸载 Go（移除所有相关文件和配置）
#   每次运行自动检查当前版本及最新版本
#   说明：安装/更新时直接覆盖旧版本，不进行备份
# ============================================================

# 定义颜色
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# 定义常量
readonly GO_ROOT="/usr/local/go"
readonly GO_WORKSPACE="/usr/local/go_workspace"
readonly GO_URL="https://dl.google.com/go"
readonly TEMP_DIR="/tmp/go_install_$$"
readonly LOG_FILE="/tmp/go_install_$$.log"
readonly VERSION_URL="https://go.dev/VERSION?m=text"

# 全局变量
CURRENT_VERSION=""
LATEST_VERSION=""
TARGET_VERSION=""

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >> "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"
}

# 清理函数
cleanup() {
    log_info "清理临时文件..."
    rm -rf "$TEMP_DIR" 2>/dev/null
}

# 错误处理（仅用于安装流程）
handle_error() {
    log_error "安装过程中发生错误，请检查日志文件: $LOG_FILE"
    cleanup
    exit 1
}

# 设置错误处理（安装时启用）
enable_error_trap() {
    trap 'handle_error' ERR
}

# 取消错误处理（卸载等操作不需要触发全局 trap）
disable_error_trap() {
    trap - ERR
}

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        echo "使用: sudo bash $0"
        exit 1
    fi
}

# 检测操作系统并安装依赖
detect_os_and_install_deps() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$NAME
        OS_VERSION=$VERSION_ID
        log_info "检测到系统: $OS_NAME $OS_VERSION"
    else
        log_error "不支持的系统类型"
        exit 1
    fi

    log_info "安装必要的依赖..."
    case "$OS_NAME" in
        *"Ubuntu"*|*"Debian"*)
            apt update -qq
            apt install -y wget tar curl
            ;;
        *"CentOS"*|*"Red Hat"*)
            yum install -y wget tar curl
            ;;
        *"Fedora"*)
            dnf install -y wget tar curl
            ;;
        *"openSUSE"*)
            zypper install -y wget tar curl
            ;;
        *"Arch"*)
            pacman -Sy --noconfirm wget tar curl
            ;;
        *)
            log_error "不支持的系统类型: $OS_NAME"
            exit 1
            ;;
    esac
}

# 获取当前已安装的 Go 版本
get_current_version() {
    if command -v go &> /dev/null; then
        CURRENT_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    else
        CURRENT_VERSION="未安装"
    fi
}

# 获取官方最新稳定版本
get_latest_version() {
    log_info "正在检查最新 Go 版本..."
    local latest_raw
    latest_raw=$(curl -s "$VERSION_URL" | head -n 1)
    if [ -z "$latest_raw" ]; then
        log_error "无法获取最新版本信息，请检查网络"
        exit 1
    fi
    LATEST_VERSION=$(echo "$latest_raw" | sed 's/go//')
    log_info "最新版本: $LATEST_VERSION"
}

# 检查版本是否存在（下载前验证）
check_version_exists() {
    local ver=$1
    local check_url="$GO_URL/go$ver.linux-amd64.tar.gz"
    if ! curl --output /dev/null --silent --head --fail "$check_url"; then
        return 1
    fi
    return 0
}

# 下载 Go 指定版本
download_go() {
    local ver=$1
    log_info "准备下载 Go $ver ..."

    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR" || exit 1

    local archive="go$ver.linux-amd64.tar.gz"
    log_info "正在下载 $archive ..."
    if ! wget -q "$GO_URL/$archive"; then
        log_error "下载失败，请检查网络连接"
        return 1
    fi

    if [ ! -f "$archive" ]; then
        log_error "下载文件不存在"
        return 1
    fi

    log_info "下载完成"
    return 0
}

# ================================================================
# 安装指定的 Go 版本（内部使用）—— 无备份版
# ================================================================
install_go_version() {
    local ver=$1
    enable_error_trap

    # 如果已存在 Go 安装，直接删除（不备份）
    if [ -d "$GO_ROOT" ]; then
        log_info "检测到已存在的 Go 安装，将直接删除旧版本"
        rm -rf "$GO_ROOT" || {
            log_error "删除旧版本失败，无法继续安装"
            return 1
        }
        log_info "旧版本已删除"
    fi

    # 解压安装
    log_info "正在解压安装..."
    tar -C /usr/local -xzf "go$ver.linux-amd64.tar.gz"
    if [ ! -d "$GO_ROOT" ]; then
        log_error "安装失败，目录不存在: $GO_ROOT"
        return 1
    fi

    # 创建工作空间
    mkdir -p "$GO_WORKSPACE"/{src,pkg,bin}
    chmod -R 777 "$GO_WORKSPACE"

    # 配置环境变量
    cat > /etc/profile.d/go.sh << EOF
export GOROOT=$GO_ROOT
export GOPATH=$GO_WORKSPACE
export PATH=\$PATH:\$GOROOT/bin:\$GOPATH/bin
EOF
    chmod 644 /etc/profile.d/go.sh
    source /etc/profile.d/go.sh

    # 验证安装
    if ! command -v go &> /dev/null; then
        log_error "Go 命令不可用，安装失败"
        return 1
    fi

    local installed_version
    installed_version=$(go version | awk '{print $3}' | sed 's/go//')
    if [ "$installed_version" != "$ver" ]; then
        log_error "版本不匹配: 预期 $ver, 实际 $installed_version"
        return 1
    fi

    log_info "Go $ver 安装成功!"
    cleanup
    disable_error_trap
    return 0
}

# 安装主流程（交互式调用）
install_go() {
    local target_ver="$1"
    if [ -z "$target_ver" ]; then
        target_ver="$LATEST_VERSION"
    fi

    # 检查是否已安装相同版本
    if [ "$CURRENT_VERSION" = "$target_ver" ] && [ "$CURRENT_VERSION" != "未安装" ]; then
        log_warn "Go $target_ver 已安装，无需重复安装"
        return 0
    fi

    # 检查版本是否存在
    if ! check_version_exists "$target_ver"; then
        log_error "版本 $target_ver 不存在或无法访问"
        return 1
    fi

    # 下载
    if ! download_go "$target_ver"; then
        log_error "下载失败"
        return 1
    fi

    # 安装
    if ! install_go_version "$target_ver"; then
        log_error "安装失败"
        return 1
    fi

    # 更新全局当前版本
    CURRENT_VERSION="$target_ver"
    log_info "安装完成！"
    show_post_install_help
    return 0
}

# 更新 Go（升级到最新版）
update_go() {
    if [ "$CURRENT_VERSION" = "未安装" ]; then
        log_error "Go 尚未安装，请先执行安装"
        return 1
    fi

    if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        log_info "当前已是最新版本 $CURRENT_VERSION，无需更新"
        return 0
    fi

    log_info "将 Go 从 $CURRENT_VERSION 更新到 $LATEST_VERSION"
    install_go "$LATEST_VERSION"
    return $?
}

# 卸载 Go
uninstall_go() {
    if [ "$CURRENT_VERSION" = "未安装" ]; then
        log_warn "Go 尚未安装，无需卸载"
        return 0
    fi

    echo -e "${YELLOW}即将卸载 Go $CURRENT_VERSION${NC}"
    echo "将删除以下内容："
    echo "  - $GO_ROOT"
    echo "  - /etc/profile.d/go.sh"
    echo "  - $GO_WORKSPACE (可选)"
    echo -n "确认卸载？[y/N] "
    read -r answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        log_info "卸载已取消"
        return 0
    fi

    echo -n "是否保留工作空间目录 $GO_WORKSPACE ？（保留则仅删除内部 bin/pkg/src？）[y/N] "
    read -r keep_workspace
    disable_error_trap

    if [ -d "$GO_ROOT" ]; then
        rm -rf "$GO_ROOT" && log_info "已删除 $GO_ROOT" || log_warn "删除 $GO_ROOT 失败"
    fi

    if [ -f "/etc/profile.d/go.sh" ]; then
        rm -f "/etc/profile.d/go.sh" && log_info "已删除 /etc/profile.d/go.sh" || log_warn "删除 /etc/profile.d/go.sh 失败"
    fi

    if [[ "$keep_workspace" =~ ^[Yy]$ ]]; then
        log_info "保留工作空间目录，但清空内部 src/pkg/bin"
        if [ -d "$GO_WORKSPACE" ]; then
            rm -rf "$GO_WORKSPACE"/{src,pkg,bin} 2>/dev/null
            log_info "已清空 $GO_WORKSPACE 下的 src/pkg/bin"
        fi
    else
        if [ -d "$GO_WORKSPACE" ]; then
            rm -rf "$GO_WORKSPACE" && log_info "已删除 $GO_WORKSPACE" || log_warn "删除 $GO_WORKSPACE 失败"
        fi
    fi

    CURRENT_VERSION="未安装"
    log_info "卸载完成"
    echo -e "${GREEN}请执行 'source /etc/profile' 或重新登录使环境变量生效${NC}"
    disable_error_trap
    return 0
}

# 显示安装后的帮助信息
show_post_install_help() {
    echo
    echo -e "${GREEN}===============================================${NC}"
    echo -e "${BLUE}Go $CURRENT_VERSION 安装完成！${NC}"
    echo -e "${GREEN}-----------------------------------------------${NC}"
    echo -e "请执行以下步骤完成配置："
    echo
    echo -e "1. 重新加载环境变量:"
    echo -e "   ${YELLOW}source /etc/profile${NC}"
    echo
    echo -e "2. 配置 Go 模块和代理 (推荐):"
    echo -e "   ${YELLOW}go env -w GO111MODULE=on${NC}"
    echo -e "   ${YELLOW}go env -w GOPROXY=https://goproxy.cn,direct${NC}"
    echo
    echo -e "3. 验证安装:"
    echo -e "   ${YELLOW}go version${NC}"
    echo -e "${GREEN}===============================================${NC}"
}

# 显示菜单
show_menu() {
    clear
    echo -e "${BLUE}===============================================${NC}"
    echo -e "${BLUE}          Go 版本管理交互工具（无备份）${NC}"
    echo -e "${BLUE}===============================================${NC}"
    echo -e "当前安装版本: ${YELLOW}${CURRENT_VERSION}${NC}"
    echo -e "官方最新版本: ${GREEN}${LATEST_VERSION}${NC}"
    echo -e "${BLUE}-----------------------------------------------${NC}"
    echo "请选择操作:"
    echo "  1) 安装 Go（安装最新稳定版）"
    echo "  2) 更新 Go（升级到最新版）"
    echo "  3) 卸载 Go"
    echo "  4) 退出"
    echo -n "请输入数字 [1-4]: "
}

# 主循环
main() {
    check_root
    detect_os_and_install_deps
    get_current_version
    get_latest_version

    while true; do
        show_menu
        read -r choice
        case "$choice" in
            1)
                echo
                if [ "$CURRENT_VERSION" != "未安装" ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
                    log_warn "Go $CURRENT_VERSION 已是最新，无需安装"
                    echo "按 Enter 继续..."
                    read -r
                    continue
                fi
                log_info "开始安装 Go $LATEST_VERSION ..."
                install_go "$LATEST_VERSION"
                echo "按 Enter 继续..."
                read -r
                ;;
            2)
                echo
                update_go
                echo "按 Enter 继续..."
                read -r
                ;;
            3)
                echo
                uninstall_go
                echo "按 Enter 继续..."
                read -r
                ;;
            4)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 启动主函数
main
