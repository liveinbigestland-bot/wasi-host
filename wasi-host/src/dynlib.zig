const std = @import("std");
const builtin = @import("builtin");

/// 跨平台动态库句柄（安全封装）
pub const DynamicLibrary = struct {
    handle: Handle,

    const Handle = if (builtin.os.tag == .windows)
        std.os.windows.HMODULE
    else
        *anyopaque;

    /// 打开动态库（安全、带错误）
    pub fn open(path: []const u8) !DynamicLibrary {
        const handle = try platformOpen(path);
        return DynamicLibrary{ .handle = handle };
    }

    /// 安全获取函数指针（强类型）
    pub fn getFunction(self: DynamicLibrary, comptime Func: type, name: []const u8) !Func {
        const addr = platformGetSymbol(self.handle, name) orelse {
            return error.SymbolNotFound;
        };
        return @ptrCast(Func, addr);
    }

    /// 安全关闭（不会重复关闭）
    pub fn close(self: *DynamicLibrary) void {
        if (self.handle == null) return;
        platformClose(self.handle);
        self.handle = null;
    }
};

// ==========================
// 平台底层稳定实现
// ==========================
fn platformOpen(path: []const u8) !DynamicLibrary.Handle {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const h = w.LoadLibraryA(@ptrCast(path.ptr));
        if (h == null) return error.LoadLibraryFailed;
        return h;
    }

    const c = @cImport({
        @cInclude("dlfcn.h");
    });

    const h = c.dlopen(path.ptr, c.RTLD_NOW);
    if (h == null) return error.DLOpenFailed;
    return h;
}

fn platformGetSymbol(handle: DynamicLibrary.Handle, name: []const u8) ?*anyopaque {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        return @ptrCast(w.GetProcAddress(handle, name.ptr));
    }

    const c = @cImport({
        @cInclude("dlfcn.h");
    });
    return c.dlsym(handle, name.ptr);
}

fn platformClose(handle: DynamicLibrary.Handle) void {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        _ = w.FreeLibrary(handle);
    } else {
        const c = @cImport({
            @cInclude("dlfcn.h");
        });
        _ = c.dlclose(handle);
    }
}
