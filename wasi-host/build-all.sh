#!/bin/bash
set -euo pipefail

echo "========================================"
echo "  一键全平台打包脚本"
echo "========================================"
echo ""

mkdir -p output

# 检查 wasm3
if [ ! -d "wasm3" ]; then
    echo "[...] 克隆 Wasm3 ..."
    git clone --depth=1 https://github.com/wasm3/wasm3.git
fi

# 确保 plug/ 存在
mkdir -p plug

# ============================================
# 第一步：编译 WASM 插件（共用于所有平台）
# ============================================
echo "[1/4] 编译 WASM 插件（wasm32-wasi）..."

for plugin in plugins/*.zig; do
    name=$(basename "$plugin" .zig)
    echo "  → $name"
    zig build-exe "$plugin" \
        -target wasm32-wasi \
        -rdynamic \
        -O ReleaseSmall \
        -femit-bin="plug/${name}.wasm"
done

echo "  ✓ WASM 插件完成"
echo ""

# ============================================
# 第二步：Linux x86_64
# ============================================
echo "[2/4] 编译 Linux x86_64 ..."
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall
cp zig-out/bin/wasi-host output/wasi-host-linux-x64
echo "  → output/wasi-host-linux-x64"
echo ""

# ============================================
# 第三步：Windows x86_64
# ============================================
echo "[3/4] 编译 Windows x86_64 ..."
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall
cp zig-out/bin/wasi-host.exe output/wasi-host-win-x64.exe
echo "  → output/wasi-host-win-x64.exe"
echo ""

# ============================================
# 第四步：Linux ARM64 (如树莓派、AWS Graviton)
# ============================================
echo "[4/4] 编译 Linux ARM64 ..."
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSmall
cp zig-out/bin/wasi-host output/wasi-host-linux-arm64
echo "  → output/wasi-host-linux-arm64"
echo ""

echo "========================================"
echo "  ✅ 全平台打包完成！"
echo "  产物目录：output/"
echo "========================================"
echo ""
ls -lh output/
