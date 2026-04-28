#!/bin/bash
set -euo pipefail

echo "========================================"
echo "  wasi-host 项目初始化"
echo "========================================"

# 1. 检查 Zig 是否已安装
if ! command -v zig &>/dev/null; then
    echo "[错误] 未找到 zig，请先安装 Zig 0.13+"
    echo "  macOS: brew install zig"
    echo "  Linux: curl -fsSL https://ziglang.org/download/ | 下载最新版"
    echo "  Windows: https://ziglang.org/download/"
    exit 1
fi

ZIG_VERSION=$(zig version 2>/dev/null || echo "unknown")
echo "[✓] Zig 版本: $ZIG_VERSION"

# 2. 克隆 Wasm3 引擎
if [ ! -d "wasm3" ]; then
    echo "[...] 克隆 Wasm3 ..."
    git clone --depth=1 https://github.com/wasm3/wasm3.git
    echo "[✓] Wasm3 克隆完成"
else
    echo "[✓] Wasm3 已存在"
fi

# 3. 创建 plug/ 目录
mkdir -p plug

# 4. 编译 WASM 插件
echo "[...] 编译 WASM 插件 ..."
for plugin in plugins/*.zig; do
    name=$(basename "$plugin" .zig)
    echo "  编译: $name"
    zig build-exe "$plugin" \
        -target wasm32-wasi \
        -rdynamic \
        -O ReleaseSmall \
        -femit-bin="plug/${name}.wasm" 2>&1 | sed 's/^/  /'
done
echo "[✓] WASM 插件编译完成"

# 5. 编译宿主程序（当前平台）
echo "[...] 编译宿主程序 ..."
zig build -Doptimize=ReleaseSmall
echo "[✓] 编译完成"

echo ""
echo "========================================"
echo "  构建成功！"
echo "  运行: zig build run"
echo "  或直接: ./zig-out/bin/wasi-host"
echo "========================================"
