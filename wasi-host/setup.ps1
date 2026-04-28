# wasi-host Windows 一键初始化脚本
# 用法: 右键 "以 PowerShell 运行" 或在终端执行 .\setup.ps1

$ErrorActionPreference = "Stop"
$Host.UI.RawUI.ForegroundColor = "Green"
Write-Host "========================================"
Write-Host "  wasi-host 项目初始化 (Windows)"
Write-Host "========================================"
$Host.UI.RawUI.ForegroundColor = "White"

# 切到脚本所在目录
Set-Location $PSScriptRoot

# 1. 检查 Zig
Write-Host "`n[1/4] 检查 Zig ..." -ForegroundColor Cyan
try {
    $zigVer = zig version
    Write-Host "  [✓] Zig 版本: $zigVer" -ForegroundColor Green
} catch {
    Write-Host "  [x] 未找到 zig，请先安装:" -ForegroundColor Red
    Write-Host "      https://ziglang.org/download/" -ForegroundColor Yellow
    exit 1
}

# 2. 克隆 Wasm3 引擎
Write-Host "`n[2/4] 拉取 Wasm3 引擎 ..." -ForegroundColor Cyan
if (-not (Test-Path "wasm3")) {
    git clone --depth=1 https://github.com/wasm3/wasm3.git
    Write-Host "  [✓] Wasm3 克隆完成" -ForegroundColor Green
} else {
    Write-Host "  [✓] Wasm3 已存在" -ForegroundColor Green
}

# 3. 创建 plug/ 目录 + 编译 WASM 插件
Write-Host "`n[3/4] 编译 WASM 插件 (wasm32-wasi) ..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path "plug" | Out-Null

Get-ChildItem "plugins\*.zig" | ForEach-Object {
    $name = $_.BaseName
    Write-Host "  编译: $name" -ForegroundColor Yellow
    zig build-exe $_.FullName `
        -target wasm32-wasi `
        -rdynamic `
        -O ReleaseSmall `
        -femit-bin="plug/${name}.wasm"
    Write-Host "  [✓] $name → plug/${name}.wasm" -ForegroundColor Green
}

# 4. 编译宿主程序
Write-Host "`n[4/4] 编译宿主程序 wasi-host ..." -ForegroundColor Cyan
zig build -Doptimize=ReleaseSmall
Write-Host "  [✓] 编译完成: zig-out\bin\wasi-host.exe" -ForegroundColor Green

$Host.UI.RawUI.ForegroundColor = "Green"
Write-Host "`n========================================"
Write-Host "  ✅ 初始化完成！"
Write-Host "  运行: zig build run"
Write-Host "  或直接: .\zig-out\bin\wasi-host.exe"
Write-Host "========================================"
$Host.UI.RawUI.ForegroundColor = "White"

# 5. 询问是否立即运行
$run = Read-Host "`n立即运行 wasi-host？(y/n)"
if ($run -eq "y") {
    .\zig-out\bin\wasi-host.exe
}
