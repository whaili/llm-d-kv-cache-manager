#!/bin/bash
set -e

# ================== 配置变量 ==================
ANTHROPIC_BASE_URL="https://hongma.cc/api"
ANTHROPIC_AUTH_TOKEN="cr_05286ecd7280408954e6e42cd86023ff85f42c6f3e85d76c56c996cc5a680402"
# ==============================================

echo "=========================================="
echo ">>> 配置环境变量 (放在最前面，便于修改替换) ..."
echo "=========================================="

if ! grep -q "ANTHROPIC_BASE_URL" ~/.bashrc; then
  echo "export ANTHROPIC_BASE_URL=\"$ANTHROPIC_BASE_URL\"" >> ~/.bashrc
fi
if ! grep -q "ANTHROPIC_AUTH_TOKEN" ~/.bashrc; then
  echo "export ANTHROPIC_AUTH_TOKEN=\"$ANTHROPIC_AUTH_TOKEN\"" >> ~/.bashrc
fi

# 立即生效
source ~/.bashrc

echo "=========================================="
echo ">>> 安装 Node.js (LTS) ..."
echo "=========================================="

curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs

echo "=========================================="
echo ">>> 安装 Claude Code CLI ..."
echo "=========================================="

sudo npm install -g @anthropic-ai/claude-code

echo "claude --version"
claude --version

echo "=========================================="
echo ">>> 安装 VS Code 插件 ..."
echo "=========================================="

extensions=(
  anthropic.claude-codes   # Claude Code 插件
  ms-vscode.go             # Go 插件
  golang.go                # Go Tools
)

for ext in "${extensions[@]}"; do
  echo "安装插件: $ext"
  code --install-extension "$ext" || true
done

echo "=========================================="
echo ">>> 环境安装完成 ✅"
echo "=========================================="

