# wasi-host — Zig 跨平台 WASM 插件运行时

基于 [Wasm3](https://github.com/wasm3/wasm3) 的高性能 WebAssembly 运行时，支持多插件并发、沙箱隔离、宿主硬件信息采集、一键多平台打包。

## 能力

- **Zig 单文件交付**，无运行时依赖
- **完整 WASI** + 严格沙箱双模式
- **多插件并行**，完全隔离的内存/权限空间
- **细粒度权限控制**：内存上限、超时熔断、网络开关、文件写许可、宿主信息开关
- **宿主硬件采集**：CPU 使用率、物理内存、系统类型、核心数
- **一键打包**：Linux x86_64 / Windows x64 / ARM64

## 快速开始

```bash
# 1. 初始化（克隆 wasm3 + 编译插件 + 编译宿主）
chmod +x setup.sh build-all.sh
./setup.sh

# 2. 运行
zig build run
# 或直接
./zig-out/bin/wasi-host

# 3. 一键全平台打包
./build-all.sh
```

## 项目结构

```
wasi-host/
├── main.zig              # 宿主主程序
├── build.zig             # 构建配置
├── config.json           # 插件配置
├── setup.sh              # 初始化脚本
├── build-all.sh          # 全平台打包脚本
├── plugins/
│   ├── ai_plugin.zig     # AI 推理示例插件
│   └── api_plugin.zig    # API 网关示例插件
├── plug/                 # 编译后的 .wasm 文件（@embedFile）
├── wasm3/                # Wasm3 引擎源码
└── output/               # 打包产物目录
```

## 配置文件

编辑 `config.json` 控制每个插件的权限：

| 字段 | 说明 |
|------|------|
| `name` | 插件名称 |
| `embed_path` | 内嵌 WASM 文件路径 |
| `mem_kb` | 内存上限（KB） |
| `timeout_ms` | 超时熔断（毫秒） |
| `network` | 是否允许网络访问 |
| `write` | 是否允许写文件系统 |
| `allow_host_info` | 是否可读宿主硬件信息 |

如果 `config.json` 不存在，将使用默认配置运行所有内嵌插件。

## 插件开发

插件使用 Zig 编写，编译到 `wasm32-wasi` 目标：

```zig
// 导入宿主函数
extern "host" fn cpu_cores() u32;
extern "host" fn cpu_usage() f32;

pub fn main() void {
    // 你的插件逻辑
}
```

编译：
```bash
zig build-exe plugins/my_plugin.zig -target wasm32-wasi -rdynamic -O ReleaseSmall -femit-bin="plug/my_plugin.wasm"
```

然后在 `main.zig` 中添加 `@embedFile` 引用并重新编译宿主即可。

## 系统要求

- Zig 0.13+
- Git（用于克隆 Wasm3）
- （可选）zig build 跨平台目标：`x86_64-windows-gnu`、`aarch64-linux-gnu` 等
