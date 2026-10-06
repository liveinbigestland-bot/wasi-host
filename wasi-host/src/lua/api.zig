const std = @import("std");

pub const ErrorCallback = fn (message: []const u8, source: ?[]const u8, line: i32) void;

pub const MemTracker = struct {
    max_kb: u64,
    current_kb: u64,
    allocated_kb: u64,
};

pub const SandboxConfig = struct {
    allocator: std.mem.Allocator,
    safe_mode: bool,
    block_globals: bool,
    allowed_host_api: bool,

    pub fn init(allocator: std.mem.Allocator) SandboxConfig {
        return SandboxConfig{
            .allocator = allocator,
            .safe_mode = true,
            .block_globals = true,
            .allowed_host_api = true,
        };
    }
};

pub const LuaRegistryIndex = -10000;
pub const LuaEnvIndex = -10001;

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
    HALT = 0, // Default Lua behavior - abort the program
    LOG = 1, // Log panic and return error status
    RETURN = 2, // Return error to Lua caller (more sandbox-friendly)
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

pub const Lua = opaque {
    pub fn deinit(self: *Lua) void {
        _ = self;
    }
};

// External C API functions
pub extern fn lua_newstate(alloc_fn: ?fn (usize, usize) callconv(.C) ?[*]u8, ud: ?*anyopaque) ?*Lua;
pub extern fn lua_close(L: ?*Lua) void;
pub extern fn lua_atpanic(L: ?*Lua, panicf: fn (?*Lua) callconv(.C) c_int) c_int;
pub extern fn lua_version(L: ?*Lua) f64;
pub inline fn lua_getversion() ?[*]const u8 {
    return "Lua 5.4";
}
pub extern fn lua_newthread(L: ?*Lua) ?*Lua;
pub extern fn lua_resetthread(L: ?*Lua) c_int;
pub extern fn lua_gettop(L: ?*Lua) c_int;
pub extern fn lua_settop(L: ?*Lua, idx: c_int) void;
pub extern fn lua_pushvalue(L: ?*Lua, idx: c_int) void;
pub extern fn lua_remove(L: ?*Lua, idx: c_int) void;
pub extern fn lua_insert(L: ?*Lua, idx: c_int) void;
pub extern fn lua_replace(L: ?*Lua, idx: c_int) void;
pub extern fn lua_copy(L: ?*Lua, fromidx: c_int, toidx: c_int) void;
pub extern fn lua_checkstack(L: ?*Lua, n: c_int, msg: ?[*]const u8) c_int;
pub extern fn lua_xmove(from: ?*Lua, to: ?*Lua, n: c_int) void;
pub extern fn lua_isnil(L: ?*Lua, idx: c_int) c_int;
pub extern fn lua_isnone(L: ?*Lua, idx: c_int) c_int;
pub extern fn lua_isnoneornil(L: ?*Lua, idx: c_int) c_int;
pub extern fn lua_type(L: ?*Lua, idx: c_int) Type;
pub extern fn lua_typename(L: ?*Lua, tp: Type) ?[*]const u8;
pub extern fn lua_equal(L: ?*Lua, idx1: c_int, idx2: c_int) c_int;
pub extern fn lua_lessthan(L: ?*Lua, idx1: c_int, idx2: c_int) c_int;
pub extern fn lua_rawequal(L: ?*Lua, idx1: c_int, idx2: c_int) c_int;
pub extern fn lua_toboolean(L: ?*Lua, idx: c_int) c_int;
pub extern fn lua_tonumberx(L: ?*Lua, idx: c_int, isnum: ?*c_int) f64;
pub inline fn lua_tonumber(L: ?*Lua, idx: c_int) f64 {
    return lua_tonumberx(L, idx, null);
}
pub extern fn lua_tointegerx(L: ?*Lua, idx: c_int, isnum: ?*c_int) i64;
pub inline fn lua_tointeger(L: ?*Lua, idx: c_int) i64 {
    return lua_tointegerx(L, idx, null);
}
pub extern fn lua_tounsignedx(L: ?*Lua, idx: c_int, isnum: ?*c_int) u64;
pub inline fn lua_tounsigned(L: ?*Lua, idx: c_int) u64 {
    return lua_tounsignedx(L, idx, null);
}
pub extern fn lua_tolstring(L: ?*Lua, idx: c_int, len: ?*usize) ?[*:0]const u8;
pub inline fn lua_tostring(L: ?*Lua, idx: c_int) ?[*:0]const u8 {
    return lua_tolstring(L, idx, null);
}
pub extern fn lua_objlen(L: ?*Lua, idx: c_int) usize;
pub extern fn lua_touserdata(L: ?*Lua, idx: c_int) ?*anyopaque;
pub extern fn lua_tocfunction(L: ?*Lua, idx: c_int) ?fn (?*Lua) callconv(.C) c_int;
pub extern fn lua_tthread(L: ?*Lua, idx: c_int) ?*Lua;
pub extern fn lua_pushnil(L: ?*Lua) void;
pub extern fn lua_pushboolean(L: ?*Lua, b: c_int) void;
pub extern fn lua_pushlightuserdata(L: ?*Lua, p: ?*anyopaque) void;
pub extern fn lua_pushnumber(L: ?*Lua, n: f64) void;
pub extern fn lua_pushinteger(L: ?*Lua, n: i64) void;
pub inline fn lua_pushunsigned(L: ?*Lua, n: u64) void {
    lua_pushinteger(L, @intCast(n));
}
pub extern fn lua_pushlstring(L: ?*Lua, s: ?[*]const u8, l: usize) void;
pub extern fn lua_pushstring(L: ?*Lua, s: ?[*]const u8) void;
pub extern fn lua_createtable(L: ?*Lua, narr: c_int, nrec: c_int) void;
pub inline fn lua_pop(L: ?*Lua, n: c_int) void {
    lua_settop(L, -n - 1);
}
pub inline fn lua_newtable(L: ?*Lua) void {
    lua_createtable(L, 0, 0);
}
pub extern fn lua_pushvfstring(L: ?*Lua, fmt: ?[*]const u8, argp: ?*anyopaque) void;
pub extern fn lua_pushfstring(L: ?*Lua, fmt: ?[*]const u8, ...) void;
pub extern fn lua_pushcclosure(L: ?*Lua, f: ?fn (?*Lua) callconv(.C) c_int, n: c_int) void;
pub inline fn lua_pushcfunction(L: ?*Lua, f: ?fn (?*Lua) callconv(.C) c_int) void {
    lua_pushcclosure(L, f, 0);
}
pub extern fn lua_pushthread(L: ?*Lua) void;
pub extern fn lua_getglobal(L: ?*Lua, name: ?[*]const u8) void;
pub extern fn lua_setglobal(L: ?*Lua, name: ?[*]const u8) void;
pub extern fn lua_gettable(L: ?*Lua, idx: c_int) void;
pub extern fn lua_settable(L: ?*Lua, idx: c_int) void;
pub extern fn lua_getfield(L: ?*Lua, idx: c_int, k: ?[*]const u8) void;
pub extern fn lua_setfield(L: ?*Lua, idx: c_int, k: ?[*]const u8) void;
pub extern fn lua_geti(L: ?*Lua, idx: c_int, n: i64) void;
pub extern fn lua_seti(L: ?*Lua, idx: c_int, n: i64) void;
pub extern fn lua_rawget(L: ?*Lua, idx: c_int) void;
pub extern fn lua_rawset(L: ?*Lua, idx: c_int) void;
pub extern fn lua_rawgeti(L: ?*Lua, idx: c_int, n: i64) void;
pub extern fn lua_rawseti(L: ?*Lua, idx: c_int, n: i64) void;
pub extern fn lua_getmetatable(L: ?*Lua, objindex: c_int) void;
pub extern fn lua_getuservalue(L: ?*Lua, idx: c_int) void;
pub extern fn lua_setuservalue(L: ?*Lua, idx: c_int) void;
pub extern fn lua_setmetatable(L: ?*Lua, objindex: c_int) void;
pub extern fn lua_next(L: ?*Lua, idx: c_int) c_int;
pub extern fn lua_callk(L: ?*Lua, nargs: c_int, nresults: c_int, ctx: isize, k: ?*const anyopaque) Status;
pub inline fn lua_call(L: ?*Lua, nargs: c_int, nresults: c_int) Status {
    return lua_callk(L, nargs, nresults, 0, null);
}
pub extern fn lua_pcallk(L: ?*Lua, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?*const anyopaque) Status;
pub inline fn lua_pcall(L: ?*Lua, nargs: c_int, nresults: c_int, errfunc: c_int) Status {
    return lua_pcallk(L, nargs, nresults, errfunc, 0, null);
}
pub extern fn lua_cpcall(L: ?*Lua, func: ?fn (?*Lua) callconv(.C) c_int, ud: ?*anyopaque) Status;
pub extern fn lua_load(L: ?*Lua, reader: ?*const fn (?*anyopaque, ?[*]u8, ?*usize) callconv(.C) c_int, dt: ?*anyopaque, chunkname: ?[*]const u8, mode: ?[*]const u8) Status;
pub extern fn luaL_loadbufferx(L: ?*Lua, buff: ?[*]const u8, sz: usize, name: ?[*]const u8, mode: ?[*]const u8) Status;
pub inline fn luaL_loadbuffer(L: ?*Lua, buff: ?[*]const u8, sz: usize, name: ?[*]const u8) Status {
    return luaL_loadbufferx(L, buff, sz, name, null);
}
pub extern fn lua_dump(L: ?*Lua, writer: ?fn (?*anyopaque, ?[*]const u8, usize) callconv(.C) c_int, dt: ?*anyopaque) c_int;
pub extern fn lua_yieldk(L: ?*Lua, nresults: c_int, ctx: isize, k: ?*const anyopaque) c_int;
pub inline fn lua_yield(L: ?*Lua, nresults: c_int) c_int {
    return lua_yieldk(L, nresults, 0, null);
}
pub extern fn lua_resume(L: ?*Lua, from: ?*Lua, nargs: c_int) c_int;
pub extern fn lua_status(L: ?*Lua) c_int;
pub extern fn lua_gc(L: ?*Lua, what: c_int, data: c_int) c_int;
pub extern fn lua_error(L: ?*Lua) noreturn;

pub const LuaState = struct {
    state: ?*Lua = null,
    allocator: std.mem.Allocator = undefined,
};
