#!/bin/bash

# 遇到错误继续执行，依靠后续的错误判断和依赖修复
set +e

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # 恢复默认颜色

echo -e "${GREEN}=== RustScan 自动最新版安装脚本 ===${NC}"

# 1. 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 错误: 请使用 root 权限运行此脚本 (例如: sudo bash install_rustscan_latest.sh)${NC}"
  exit 1
fi

# 2. 检查并安装基础依赖 (wget, unzip, curl, jq, nmap)
echo -e "\n${YELLOW}[1/4] 正在检查系统依赖...${NC}"
apt-get update -qq
for cmd in wget unzip curl jq nmap; do
  if ! command -v $cmd &> /dev/null; then
    echo -e "未找到 $cmd，正在自动安装..."
    apt-get install -y $cmd > /dev/null
  else
    echo -e "✅ $cmd 已安装"
  fi
done

# 3. 动态获取最新版本号
echo -e "\n${YELLOW}[2/4] 正在查询 GitHub 最新版本...${NC}"
# 使用 GitHub API 获取 latest release 的 tag_name
LATEST_VERSION=$(curl -s https://api.github.com/repos/bee-san/RustScan/releases/latest | jq -r .tag_name)

# 检查是否成功获取版本号（防止网络问题或 API 限流）
if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" == "null" ]; then
  echo -e "${RED}❌ 错误: 无法获取最新版本号，可能触发了 GitHub API 限制或网络问题。${NC}"
  echo -e "请稍后再试，或者手动前往 GitHub 查看最新版本。"
  exit 1
fi

echo -e "✅ 检测到最新版本: ${GREEN}${LATEST_VERSION}${NC}"

# 4. 下载并解压
DOWNLOAD_URL="https://github.com/bee-san/RustScan/releases/download/${LATEST_VERSION}/rustscan.deb.zip"
TMP_DIR=$(mktemp -d)
ZIP_FILE="rustscan.deb.zip"

echo -e "\n${YELLOW}[3/4] 正在下载 RustScan ${LATEST_VERSION}...${NC}"
wget -q --show-progress "$DOWNLOAD_URL" -O "$TMP_DIR/$ZIP_FILE"

if [ $? -ne 0 ]; then
  echo -e "${RED}❌ 错误: 文件下载失败，请检查网络连接。${NC}"
  rm -rf "$TMP_DIR"
  exit 1
fi

echo -e "正在解压安装包..."
unzip -q "$TMP_DIR/$ZIP_FILE" -d "$TMP_DIR"
DEB_FILE=$(ls "$TMP_DIR"/*.deb 2>/dev/null | head -n 1)

if [ -z "$DEB_FILE" ]; then
  echo -e "${RED}❌ 错误: 解压后未找到 .deb 文件${NC}"
  rm -rf "$TMP_DIR"
  exit 1
fi

# 5. 安装并自动修复依赖
echo -e "\n${YELLOW}[4/4] 正在安装并修复依赖...${NC}"
dpkg -i "$DEB_FILE"
# 无论 dpkg 是否报错，都运行一次 -f 尝试修复缺失的依赖
apt-get install -f -y

# 清理临时文件
echo -e "\n${YELLOW}🧹 正在清理临时文件...${NC}"
rm -rf "$TMP_DIR"

# 6. 验证安装
if command -v rustscan &> /dev/null; then
  echo -e "\n${GREEN}🎉 RustScan ${LATEST_VERSION} 安装成功！${NC}"
  echo "----------------------------------------"
  rustscan --version
  echo "----------------------------------------"
  echo -e "💡 提示: 如果之前设置过 Docker 别名导致冲突，请运行 ${YELLOW}unalias rustscan${NC} 或删除 ~/.bashrc 中的相关配置。"
else
  echo -e "${RED}❌ 安装失败，未找到 rustscan 命令。请检查上方报错信息。${NC}"
  exit 1
fi
