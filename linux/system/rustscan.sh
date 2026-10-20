#!/bin/bash

# 遇到错误立即退出，但后续 dpkg 安装部分会单独处理
set -e

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # 恢复默认颜色

echo -e "${GREEN}=== RustScan 2.4.1 一键安装脚本 ===${NC}"

# 1. 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 错误: 请使用 root 权限运行此脚本 (例如: sudo bash install_rustscan.sh)${NC}"
  exit 1
fi

# 2. 变量配置
DOWNLOAD_URL="https://github.com/bee-san/RustScan/releases/download/2.4.1/rustscan.deb.zip"
ZIP_FILE="rustscan.deb.zip"
TEMP_DIR=$(mktemp -d)

# 设置退出时自动清理临时目录
cleanup() {
  echo -e "\n${YELLOW}🧹 正在清理临时文件...${NC}"
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# 3. 检查并安装基础依赖 (wget, unzip, nmap)
echo -e "\n${YELLOW}[1/4] 正在检查系统依赖...${NC}"
apt-get update -qq
for cmd in wget unzip nmap; do
  if ! command -v $cmd &> /dev/null; then
    echo -e "未找到 $cmd，正在自动安装..."
    apt-get install -y $cmd > /dev/null
  else
    echo -e "✅ $cmd 已安装"
  fi
done

# 4. 下载文件
echo -e "\n${YELLOW}[2/4] 正在下载 RustScan 2.4.1...${NC}"
cd "$TEMP_DIR"
wget -q --show-progress "$DOWNLOAD_URL" -O "$ZIP_FILE"

# 5. 解压并安装
echo -e "\n${YELLOW}[3/4] 正在解压并安装...${NC}"
unzip -q "$ZIP_FILE"
DEB_FILE=$(ls *.deb 2>/dev/null | head -n 1)

if [ -z "$DEB_FILE" ]; then
  echo -e "${RED}❌ 错误: 解压后未找到 .deb 文件${NC}"
  exit 1
fi

echo -e "找到安装包: $DEB_FILE"
# 暂时关闭 set -e 以便手动处理 dpkg 的依赖报错
set +e
dpkg -i "$DEB_FILE"
DPKG_STATUS=$?
set -e

# 如果 dpkg 安装失败，尝试自动修复依赖
if [ $DPKG_STATUS -ne 0 ]; then
  echo -e "${YELLOW}⚠️ 检测到依赖缺失，正在尝试自动修复...${NC}"
  apt-get install -f -y
fi

# 6. 验证安装
echo -e "\n${YELLOW}[4/4] 正在验证安装结果...${NC}"
if command -v rustscan &> /dev/null; then
  echo -e "${GREEN}🎉 RustScan 安装成功！${NC}"
  echo "----------------------------------------"
  rustscan --version
  echo "----------------------------------------"
  echo -e "💡 提示: RustScan 需要配合 Nmap 使用，系统已为你准备好。"
  echo -e "你可以尝试运行: ${GREEN}rustscan -a 127.0.0.1${NC}"
else
  echo -e "${RED}❌ 安装失败，未找到 rustscan 命令。请检查上方报错信息。${NC}"
  exit 1
fi
