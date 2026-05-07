const std = @import("std");

pub const Lua = opaque {
    pub const Status = enum(c_int) {
        ok = 0,
        yield = 1,
        errrun = 2,
        errsyntax = 3,
        errmem = 4,
        errerr = 5,
        errfile = 6,
    };

    pub const GC = enum(c_int) {
        STOP = 0,
        RESTART = 1,
        COLLECT = 2,
        COUNT = 3,
        STOPPERCENTAGE = 4,
        RESTARTPERCENTAGE = 5,
        SETSTEP = 6,
        SETSTEPMUL = 7,
        SETMAJORINC = 8,
        SETMINORMUL = 9,
        ISRUNNING = 10,
        GENE = 11,
        GCMODESTOP = 12,
        GCMODERESTART = 13,
        GCMODEGEN = 14,
        INCSTEP = 15,
        INCSTEPMUL = 16,
        INCMAJORINC = 17,
        INCMINORMUL = 18,
        INCGCMODESTOP = 19,
        INCGCMODERESTART = 20,
        INCGCMODEGEN = 21,
        INCSTEPFAST = 22,
        INCSTEPFAST2 = 23,
    };

    pub const PanicBehavior = enum(c_int) {
        HALT = 0,    // Default Lua behavior - abort the program
        LOG = 1,     // Log panic and return error status
        RETURN = 2,  // Return error to Lua caller (more sandbox-friendly)
    };

    pub const Type = enum(c_int) {
        none = -1,
        nil = 0,
        boolean = 1,
        lightuserdata = 2,
        number = 3,
        string = 4,
        table = 5,
        function = 6,
        userdata = 7,
        thread = 8,
    };

    extern fn lua_newstate(alloc_fn: ?fn(usize, usize) callconv(.C) ?[*]u8, ud: ?*anyopaque) ?*Lua;
    extern fn lua_close(L: ?*Lua) void;
    extern fn lua_atpanic(L: ?*Lua, panicf: fn(?*Lua) callconv(.C) c_int) c_int;
    extern fn lua_getversion() ?[*]const u8;

    extern fn lua_newthread(L: ?*Lua) ?*Lua;
    extern fn lua_resetthread(L: ?*Lua) c_int;

    extern fn lua_gettop(L: ?*Lua) c_int;
    extern fn lua_settop(L: ?*Lua, idx: c_int) void;
    extern fn lua_pushvalue(L: ?*Lua, idx: c_int) void;
    extern fn lua_remove(L: ?*Lua, idx: c_int) void;
    extern fn lua_insert(L: ?*Lua, idx: c_int) void;
    extern fn lua_replace(L: ?*Lua, idx: c_int) void;
    extern fn lua_copy(L: ?*Lua, fromidx: c_int, toidx: c_int) void;
    extern fn lua_checkstack(L: ?*Lua, n: c_int, msg: ?[*]const u8) c_int;

    extern fn lua_xmove(from: ?*Lua, to: ?*Lua, n: c_int) void;

    extern fn lua_isnil(L: ?*Lua, idx: c_int) c_int;
    extern fn lua_isnone(L: ?*Lua, idx: c_int) c_int;
    extern fn lua_isnoneornil(L: ?*Lua, idx: c_int) c_int;
    extern fn lua_type(L: ?*Lua, idx: c_int) Type;
    extern fn lua_typename(L: ?*Lua, tp: Type) ?[*]const u8;

    extern fn lua_equal(L: ?*Lua, idx1: c_int, idx2: c_int) c_int;
    extern fn lua_lessthan(L: ?*Lua, idx1: c_int, idx2: c_int) c_int;
    extern fn lua_rawequal(L: ?*Lua, idx1: c_int, idx2: c_int) c_int;

    extern fn lua_toboolean(L: ?*Lua, idx: c_int) c_int;
    extern fn lua_tonumber(L: ?*Lua, idx: c_int) f64;
    extern fn lua_tointeger(L: ?*Lua, idx: c_int) i64;
    extern fn lua_tounsigned(L: ?*Lua, idx: c_int) u64;
    extern fn lua_tostring(L: ?*Lua, idx: c_int) ?[*]const u8;
    extern fn lua_tolstring(L: ?*Lua, idx: c_int, len: ?*usize) ?[*]const u8;
    extern fn lua_objlen(L: ?*Lua, idx: c_int) usize;
    extern fn lua_touserdata(L: ?*Lua, idx: c_int) ?*anyopaque;
    extern fn lua_tocfunction(L: ?*Lua, idx: c_int) ?fn(?*Lua) callconv(.C) c_int;
    extern fn lua_tthread(L: ?*Lua, idx: c_int) ?*Lua;

    extern fn lua_pushnil(L: ?*Lua) void;
    extern fn lua_pushboolean(L: ?*Lua, b: c_int) void;
    extern fn lua_pushlightuserdata(L: ?*Lua, p: ?*anyopaque) void;
    extern fn lua_pushnumber(L: ?*Lua, n: f64) void;
    extern fn lua_pushinteger(L: ?*Lua, n: i64) void;
    extern fn lua_pushunsigned(L: ?*Lua, n: u64) void;
    extern fn lua_pushlstring(L: ?*Lua, s: ?[*]const u8, l: usize) void;
    extern fn lua_pushstring(L: ?*Lua, s: ?[*]const u8) void;
    extern fn lua_pushvfstring(L: ?*Lua, fmt: ?[*]const u8, argp: ?*anyopaque) void;
    extern fn lua_pushfstring(L: ?*Lua, fmt: ?[*]const u8, ...) void;
    extern fn lua_pushcclosure(L: ?*Lua, f: ?fn(?*Lua) callconv(.C) c_int, n: c_int) void;
    extern fn lua_pushboolean(L: ?*Lua, b: c_int) void;
    extern fn lua_pushcfunction(L: ?*Lua, f: ?fn(?*Lua) callconv(.C) c_int) void;
    extern fn lua_pushthread(L: ?*Lua) void;

    extern fn lua_getglobal(L: ?*Lua, name: ?[*]const u8) void;
    extern fn lua_setglobal(L: ?*Lua, name: ?[*]const u8) void;
    extern fn lua_gettable(L: ?*Lua, idx: c_int) void;
    extern fn lua_settable(L: ?*Lua, idx: c_int) void;
    extern fn lua_getfield(L: ?*Lua, idx: c_int, k: ?[*]const u8) void;
    extern fn lua_setfield(L: ?*Lua, idx: c_int, k: ?[*]const u8) void;
    extern fn lua_geti(L: ?*Lua, idx: c_int, n: i64) void;
    extern fn lua_seti(L: ?*Lua, idx: c_int, n: i64) void;
    extern fn lua_rawget(L: ?*Lua, idx: c_int) void;
    extern fn lua_rawset(L: ?*Lua, idx: c_int) void;
    extern fn lua_rawgeti(L: ?*Lua, idx: c_int, n: i64) void;
    extern fn lua_rawseti(L: ?*Lua, idx: c_int, n: i64) void;
    extern fn lua_getmetatable(L: ?*Lua, objindex: c_int) void;
    extern fn lua_getuservalue(L: ?*Lua, idx: c_int) void;
    extern fn lua_setuservalue(L: ?*Lua, idx: c_int) void;
    extern fn lua_setmetatable(L: ?*Lua, objindex: c_int) void;

    extern fn lua_next(L: ?*Lua, idx: c_int) c_int;

    extern fn lua_call(L: ?*Lua, nargs: c_int, nresults: c_int) Status;
    extern fn lua_pcall(L: ?*Lua, nargs: c_int, nresults: c_int, errfunc: c_int) Status;
    extern fn lua_cpcall(L: ?*Lua, func: ?fn(?*Lua) callconv(.C) c_int, ud: ?*anyopaque) Status;
    extern fn lua_load(L: ?*Lua, reader: ?fn(?*anyopaque, ?[*]u8, ?*usize) callconv(.C) c_int, dt: ?*anyopaque, chunkname: ?[*]const u8, mode: ?[*]const u8) Status;
    extern fn lua_dump(L: ?*Lua, writer: ?fn(?*anyopaque, ?[*]const u8, usize) callconv(.C) c_int, dt: ?*anyopaque) c_int;
    extern fn lua_yield(L: ?*Lua, nresults: c_int) c_int;
    extern fn lua_resume(L: ?*Lua, from: ?*Lua, nargs: c_int) c_int;
    extern fn lua_status(L: ?*Lua) c_int;
    extern fn lua_gc(L: ?*Lua, what: c_int, data: c_int) c_int;

    extern fn lua_error(L: ?*Lua) noreturn;
    extern fn lua_next(L: ?*Lua, idx: c_int) c_int;
    extern fn lua_concat(L: ?*Lua, n: c_int) void;
    extern fn lua_getallocf(L: ?*Lua, ud: ?*?*anyopaque) fn(usize, usize) callconv(.C) ?[*]u8;
    extern fn lua_setallocf(L: ?*Lua, f: fn(usize, usize) callconv(.C) ?[*]u8, ud: ?*anyopaque) void;
    extern fn lua_gc(L: ?*Lua, what: c_int, data: c_int) c_int;
    extern fn lua_atpanic(L: ?*Lua, panicf: fn(?*Lua) callconv(.C) c_int) c_int;

    pub const LuaRegistryIndex = -10000;
    pub const LuaEnvIndex = -10001;

    pub const LuaState = struct {
        state: ?*Lua,

        pub fn init() !LuaState {
            const state = lua_newstate(allocator, null);
            if (state == null) {
                return error.OutOfMemory;
            }
            return LuaState{ .state = state };
        }

        pub fn deinit(self: *LuaState) void {
            if (self.state) |state| {
                lua_close(state);
                self.state = null;
            }
        }

        pub fn getTop(self: LuaState) c_int {
            return lua_gettop(self.state);
        }

        pub fn setTop(self: LuaState, idx: c_int) void {
            lua_settop(self.state, idx);
        }

        pub fn pushNil(self: LuaState) void {
            lua_pushnil(self.state);
        }

        pub fn pushBoolean(self: LuaState, b: bool) void {
            lua_pushboolean(self.state, @boolToInt(b));
        }

        pub fn pushNumber(self: LuaState, n: f64) void {
            lua_pushnumber(self.state, n);
        }

        pub fn pushInteger(self: LuaState, n: i64) void {
            lua_pushinteger(self.state, n);
        }

        pub fn pushString(self: LuaState, s: []const u8) void {
            lua_pushlstring(self.state, s.ptr, s.len);
        }

        pub fn pushLightUserData(self: LuaState, p: ?*anyopaque) void {
            lua_pushlightuserdata(self.state, p);
        }

        pub fn pushCFunction(self: LuaState, f: fn(?*Lua) callconv(.C) c_int) void {
            lua_pushcfunction(self.state, f);
        }

        pub fn getType(self: LuaState, idx: c_int) Type {
            return lua_type(self.state, idx);
        }

        pub fn isNil(self: LuaState, idx: c_int) bool {
            return lua_isnil(self.state, idx) != 0;
        }

        pub fn isNone(self: LuaState, idx: c_int) bool {
            return lua_isnone(self.state, idx) != 0;
        }

        pub fn isNoneOrNil(self: LuaState, idx: c_int) bool {
            return lua_isnoneornil(self.state, idx) != 0;
        }

        pub fn toBoolean(self: LuaState, idx: c_int) bool {
            return lua_toboolean(self.state, idx) != 0;
        }

        pub fn toNumber(self: LuaState, idx: c_int) f64 {
            return lua_tonumber(self.state, idx);
        }

        pub fn toInteger(self: LuaState, idx: c_int) i64 {
            return lua_tointeger(self.state, idx);
        }

        pub fn toString(self: LuaState, idx: c_int) ?[]const u8 {
            var len: usize = undefined;
            const ptr = lua_tolstring(self.state, idx, &len);
            if (ptr == null) return null;
            return ptr[0..len];
        }

        pub fn toUserData(self: LuaState, idx: c_int) ?*anyopaque {
            return lua_touserdata(self.state, idx);
        }

        pub fn call(self: LuaState, nargs: c_int, nresults: c_int) !Status {
            const status = lua_pcall(self.state, nargs, nresults, 0);
            return @intToEnum(Status, @intCast(c_int, status));
        }

        fn allocator(size: usize, ptr: usize, ud: ?*anyopaque) callconv(.C) ?[*]u8 {
            _ = ud;
            if (size == 0) {
                return null;
            }
            const allocator = std.heap.c_allocator;
            const new_ptr = allocator.alloc(u8, size) catch return null;
            if (ptr != 0) {
                std.mem.copy(u8, new_ptr, @ptrCast([*]u8, @intToPtr(*anyopaque, ptr))[0..size]);
            }
            return new_ptr.ptr;
        }
    };

    pub fn fromPtr(ptr: ?*Lua) LuaState {
        return LuaState{ .state = ptr };
    }

    pub fn allocator(_: LuaState) std.mem.Allocator {
        return std.heap.c_allocator;
    }

    pub fn ref(self: LuaState, index: c_int) c_int {
        return luaL_ref(self.state, index);
    }

    pub fn unref(self: LuaState, ref: c_int) void {
        luaL_unref(self.state, ref);
    }

    // Error handling methods
    pub fn getErrorInfo(self: LuaState) ![]const u8 {
        if (lua_type(self.state, -1) != .string) {
            return error.NoErrorOnStack;
        }
        return lua_tostring(self.state, -1);
    }

    pub fn getFullErrorInfo(self: LuaState) !struct { message: []const u8, source: ?[]const u8, line: i32 } {
        const logger = std.log.scoped(.lua_api);
        const msg = self.getErrorInfo() catch return .{
            .message = "unknown error",
            .source = null,
            .line = 0,
        };

        // Try to get more detailed info (Lua's debug library)
        lua_pushcfunction(self.state, @ptrCast(*const fn (?*Lua) callconv(.C) c_int, lua_getinfo));
        lua_pushstring(self.state, "*s");
        lua_pushvalue(self.state, -3); // The error message
        lua_pushnil(self.state); // No extra args
        if (lua_pcall(self.state, 2, 2, 0) == ok) {
            const source = lua_tostring(self.state, -2);
            const line = @intCast(i32, lua_tonumber(self.state, -1));
            lua_pop(self.state, 3);
            return .{
                .message = msg,
                .source = source,
                .line = line,
            };
        } else {
            lua_pop(self.state, 1);
            return .{
                .message = msg,
                .source = null,
                .line = 0,
            };
        }
    }

    pub fn hasError(self: LuaState) bool {
        return lua_type(self.state, -1) == .string;
    }

    pub fn getLastError(self: LuaState) ?[]const u8 {
        if (self.hasError()) {
            const msg = lua_tostring(self.state, -1);
            lua_pop(self.state, 1);
            return msg;
        }
        return null;
    }

    // Memory management methods
    pub fn getMemUsage(self: LuaState) u64 {
        // Get current memory usage in KB
        const usage = lua_gc(self.state, lua.GC.COUNT, 0);
        return @intCast(u64, usage);
    }

    pub fn getMaxMemUsage(self: LuaState) u64 {
        // Get max memory usage since last collect
        const max_usage = lua_gc(self.state, lua.GC.COUNT, 1);
        return @intCast(u64, max_usage);
    }

    pub fn getMemLimit(self: LuaState) u64 {
        // Get memory limit in KB
        return @intCast(u64, lua_gc(self.state, lua.GC.STOPPERCENTAGE, 0) * 1024);
    }

    pub fn setMemLimit(self: LuaState, limit_kb: u64) void {
        // Set memory limit as percentage of system memory
        // Default is usually around 50-75% of available memory
        const percent = @floatToInt(c_int, (@as(f64, @floatFromInt(limit_kb)) / 1024.0) / 1024.0 * 100.0);
        lua_gc(self.state, lua.GC.STOPPERCENTAGE, @intMin(percent, 100));
    }

    pub fn getGCState(self: LuaState) enum { stopped, running, collecting } {
        const status = lua_gc(self.state, lua.GC.ISRUNNING, 0);
        if (status == 0) return .stopped;
        if (status == 1) return .running;
        return .collecting;
    }

    pub fn forceGC(self: LuaState) void {
        lua_gc(self.state, lua.GC.COLLECT, 0);
    }

    pub fn stepGC(self: LuaState, count: usize) void {
        lua_gc(self.state, lua.GC.COUNT, @intCast(c_int, count));
    }
};

pub fn lua_getinfo(L: ?*Lua, fmt: ?[*]const u8) callconv(.C) c_int {
    // Placeholder - in real implementation would use lua_getinfo
    _ = L;
    _ = fmt;
    return 0;
}

// Sandbox and security helpers
pub const SandboxHelper = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SandboxHelper {
        return SandboxHelper{ .allocator = allocator };
    }

    pub fn deinit(self: *SandboxHelper) void {
        _ = self;
    }

    /// Create a sandboxed environment for Lua code
    pub fn createEnvironment(self: *SandboxHelper, state: LuaState) !void {
        // Create environment table
        lua_newtable(state.state);

        // Set environment as thread's environment
        lua_setfenv(state.state, lua.LuaEnvIndex);

        // Set __index to access globals
        lua_getglobal(state.state, "_G");
        lua_setfield(state.state, -2, "__index");

        // Restrict __newindex
        lua_pushstring(state.state, "__newindex");
        lua_pushcfunction(state.state, @ptrCast(*const fn (?*Lua) callconv(.C) c_int, sandboxNewindex));
        lua_rawset(state.state, -3);
        lua_pop(state.state, 1);
    }

    /// Get sandboxed globals
    pub fn getSandboxedGlobals(state: LuaState) ![]const u8 {
        lua_getfenv(state.state, -1);

        // Get _G as the index
        lua_pushglobaltable(state.state);
        lua_gettable(state.state, -2);

        // Convert to string representation
        const str = lua_tolstring(state.state, -1, null);
        lua_pop(state.state, 2);

        if (str) |s| {
            const len = @as(usize, @intCast(str.len));
            return s[0..len];
        }
        return error.NoGlobalsAvailable;
    }

    /// Check if module is allowed in sandbox
    pub fn isModuleAllowed(config: const SandboxConfig, module_name: []const u8) bool {
        if (config.disallow_os and std.mem.eql(u8, module_name, "os")) {
            return false;
        }
        if (config.disallow_io and std.mem.eql(u8, module_name, "io")) {
            return false;
        }
        if (config.disallow_filesystem and std.mem.eql(u8, module_name, "lfs")) {
            return false;
        }
        if (config.disallow_network and std.mem.eql(u8, module_name, "socket")) {
            return false;
        }

        // Check allowed modules list
        for (config.allowed_modules.items) |allowed| {
            if (std.mem.eql(u8, module_name, allowed)) {
                return true;
            }
        }

        return false;
    }

    /// Create a list of allowed modules for require() checking
    pub fn createRequireList(config: const SandboxConfig) std.ArrayList([]const u8) {
        var list = std.ArrayList([]const u8).init(config.allocator);
        defer list.deinit();

        // Add explicitly allowed modules
        for (config.allowed_modules.items) |module| {
            try list.append(module);
        }

        // Optionally add built-in modules
        // This would be extended based on security policy

        return list;
    }

    /// Restrict access to dangerous globals
    pub fn restrictDangerousGlobals(state: LuaState, config: const SandboxConfig) void {
        const dangerous = [_][]const u8{
            "dofile",
            "loadfile",
            "load",
            "assert",
        };

        for (dangerous) |name| {
            lua_pushnil(state.state);
            lua_setglobal(state.state, name);
        }

        // Optionally restrict os.* functions
        if (config.disallow_os) {
            _ = state;
            // Lua will need to block os module loads
        }

        // Restrict io.* functions
        if (config.disallow_io) {
            _ = state;
        }

        // Restrict file system access
        if (config.disallow_filesystem) {
            _ = state;
        }
    }
};

fn sandboxNewindex(L: ?*Lua) callconv(.C) c_int {
    // This function is called when __newindex is accessed
    // It can be used to prevent certain modifications
    _ = L;
    return 1; // Return truthy value to indicate access was prevented
}

pub fn createLuaSandbox(state: LuaState, config: const SandboxConfig) !void {
    const helper = SandboxHelper.init(config.allocator);

    // Create new environment table
    lua_newtable(state.state);

    // Set environment
    lua_setfenv(state.state, lua.LuaEnvIndex);

    // Set __index to access globals (but limited)
    lua_getglobal(state.state, "_G");
    lua_setfield(state.state, -2, "__index");

    // Set __newindex to prevent modifications
    lua_pushstring(state.state, "__newindex");
    lua_pushcfunction(state.state, sandboxNewindex);
    lua_rawset(state.state, -3);

    // Apply security restrictions
    helper.restrictDangerousGlobals(state, config);

    helper.deinit();
}

pub const MemTracker = struct {
    allocator: std.mem.Allocator,
    initial_usage: u64,
    current_usage: u64,
    peak_usage: u64,
    collected_times: u64,

    pub fn init(allocator: std.mem.Allocator) MemTracker {
        return MemTracker{
            .allocator = allocator,
            .initial_usage = 0,
            .current_usage = 0,
            .peak_usage = 0,
            .collected_times = 0,
        };
    }

    pub fn initWithState(state: LuaState) MemTracker {
        var tracker = MemTracker.init(state.allocator());
        tracker.initial_usage = state.getMemUsage();
        tracker.current_usage = tracker.initial_usage;
        tracker.peak_usage = tracker.initial_usage;
        return tracker;
    }

    pub fn update(state: LuaState) void {
        tracker.current_usage = state.getMemUsage();
        if (tracker.current_usage > tracker.peak_usage) {
            tracker.peak_usage = tracker.current_usage;
        }
    }

    pub fn forceCollect(state: LuaState) void {
        state.forceGC();
        tracker.collected_times += 1;
    }

    pub fn getStats(self: MemTracker) struct {
        initial_kb: u64,
        current_kb: u64,
        peak_kb: u64,
        collected: u64,
    } {
        return .{
            .initial_kb = self.initial_usage,
            .current_kb = self.current_usage,
            .peak_kb = self.peak_usage,
            .collected = self.collected_times,
        };
    }

    pub fn deinit(self: *MemTracker) void {
        _ = self;
    }
};

var tracker: ?MemTracker = null;

pub fn initMemTracker(state: LuaState) !void {
    tracker = MemTracker.initWithState(state);
}

pub fn getMemTracker() ?*MemTracker {
    return tracker;
}

pub fn deinitMemTracker() void {
    if (tracker) |t| {
        t.deinit();
        tracker = null;
    }
}

// Lua reference management functions
extern fn luaL_ref(L: ?*Lua, index: c_int) callconv(.C) c_int;
extern fn luaL_unref(L: ?*Lua, ref: c_int) callconv(.C) void;

pub fn lua_getinfo(L: ?*Lua, fmt: ?[*]const u8) callconv(.C) c_int {
    // Placeholder - in real implementation would use lua_getinfo
    _ = L;
    _ = fmt;
    return 0;
}

// Sandbox and security helpers
pub const SandboxHelper = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SandboxHelper {
        return SandboxHelper{ .allocator = allocator };
    }

    pub fn deinit(self: *SandboxHelper) void {
        _ = self;
    }

    /// Create a sandboxed environment for Lua code
    pub fn createEnvironment(self: *SandboxHelper, state: LuaState) !void {
        // Create environment table
        lua_newtable(state.state);

        // Set environment as thread's environment
        lua_setfenv(state.state, lua.LuaEnvIndex);

        // Set __index to access globals
        lua_getglobal(state.state, "_G");
        lua_setfield(state.state, -2, "__index");

        // Restrict __newindex
        lua_pushstring(state.state, "__newindex");
        lua_pushcfunction(state.state, @ptrCast(*const fn (?*Lua) callconv(.C) c_int, sandboxNewindex));
        lua_rawset(state.state, -3);
        lua_pop(state.state, 1);
    }

    /// Get sandboxed globals
    pub fn getSandboxedGlobals(state: LuaState) ![]const u8 {
        lua_getfenv(state.state, -1);

        // Get _G as the index
        lua_pushglobaltable(state.state);
        lua_gettable(state.state, -2);

        // Convert to string representation
        const str = lua_tolstring(state.state, -1, null);
        lua_pop(state.state, 2);

        if (str) |s| {
            const len = @as(usize, @intCast(str.len));
            return s[0..len];
        }
        return error.NoGlobalsAvailable;
    }

    /// Check if module is allowed in sandbox
    pub fn isModuleAllowed(config: const SandboxConfig, module_name: []const u8) bool {
        if (config.disallow_os and std.mem.eql(u8, module_name, "os")) {
            return false;
        }
        if (config.disallow_io and std.mem.eql(u8, module_name, "io")) {
            return false;
        }
        if (config.disallow_filesystem and std.mem.eql(u8, module_name, "lfs")) {
            return false;
        }
        if (config.disallow_network and std.mem.eql(u8, module_name, "socket")) {
            return false;
        }

        // Check allowed modules list
        for (config.allowed_modules.items) |allowed| {
            if (std.mem.eql(u8, module_name, allowed)) {
                return true;
            }
        }

        return false;
    }

    /// Create a list of allowed modules for require() checking
    pub fn createRequireList(config: const SandboxConfig) std.ArrayList([]const u8) {
        var list = std.ArrayList([]const u8).init(config.allocator);
        defer list.deinit();

        // Add explicitly allowed modules
        for (config.allowed_modules.items) |module| {
            try list.append(module);
        }

        // Optionally add built-in modules
        // This would be extended based on security policy

        return list;
    }

    /// Restrict access to dangerous globals
    pub fn restrictDangerousGlobals(state: LuaState, config: const SandboxConfig) void {
        const dangerous = [_][]const u8{
            "dofile",
            "loadfile",
            "load",
            "assert",
        };

        for (dangerous) |name| {
            lua_pushnil(state.state);
            lua_setglobal(state.state, name);
        }

        // Optionally restrict os.* functions
        if (config.disallow_os) {
            _ = state;
            // Lua will need to block os module loads
        }

        // Restrict io.* functions
        if (config.disallow_io) {
            _ = state;
        }

        // Restrict file system access
        if (config.disallow_filesystem) {
            _ = state;
        }
    }
};

fn sandboxNewindex(L: ?*Lua) callconv(.C) c_int {
    // This function is called when __newindex is accessed
    // It can be used to prevent certain modifications
    _ = L;
    return 1; // Return truthy value to indicate access was prevented
}

pub fn createLuaSandbox(state: LuaState, config: const SandboxConfig) !void {
    const helper = SandboxHelper.init(config.allocator);

    // Create new environment table
    lua_newtable(state.state);

    // Set environment
    lua_setfenv(state.state, lua.LuaEnvIndex);

    // Set __index to access globals (but limited)
    lua_getglobal(state.state, "_G");
    lua_setfield(state.state, -2, "__index");

    // Set __newindex to prevent modifications
    lua_pushstring(state.state, "__newindex");
    lua_pushcfunction(state.state, sandboxNewindex);
    lua_rawset(state.state, -3);

    // Apply security restrictions
    helper.restrictDangerousGlobals(state, config);

    helper.deinit();
}

pub const MemTracker = struct {
    allocator: std.mem.Allocator,
    initial_usage: u64,
    current_usage: u64,
    peak_usage: u64,
    collected_times: u64,

    pub fn init(allocator: std.mem.Allocator) MemTracker {
        return MemTracker{
            .allocator = allocator,
            .initial_usage = 0,
            .current_usage = 0,
            .peak_usage = 0,
            .collected_times = 0,
        };
    }

    pub fn initWithState(state: LuaState) MemTracker {
        var tracker = MemTracker.init(state.allocator());
        tracker.initial_usage = state.getMemUsage();
        tracker.current_usage = tracker.initial_usage;
        tracker.peak_usage = tracker.initial_usage;
        return tracker;
    }

    pub fn update(state: LuaState) void {
        tracker.current_usage = state.getMemUsage();
        if (tracker.current_usage > tracker.peak_usage) {
            tracker.peak_usage = tracker.current_usage;
        }
    }

    pub fn forceCollect(state: LuaState) void {
        state.forceGC();
        tracker.collected_times += 1;
    }

    pub fn getStats(self: MemTracker) struct {
        initial_kb: u64,
        current_kb: u64,
        peak_kb: u64,
        collected: u64,
    } {
        return .{
            .initial_kb = self.initial_usage,
            .current_kb = self.current_usage,
            .peak_kb = self.peak_usage,
            .collected = self.collected_times,
        };
    }

    pub fn deinit(self: *MemTracker) void {
        _ = self;
    }
};

var tracker: ?MemTracker = null;

pub fn initMemTracker(state: LuaState) !void {
    tracker = MemTracker.initWithState(state);
}

pub fn getMemTracker() ?*MemTracker {
    return tracker;
}

pub fn deinitMemTracker() void {
    if (tracker) |t| {
        t.deinit();
        tracker = null;
    }
}