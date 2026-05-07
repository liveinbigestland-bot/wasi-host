// Lua 5.4 stub - minimal implementation for build.zig dependency
// This file is used when the lua package is not available

const std = @import("std");

pub const Lua = struct {
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

    const Self = @This();
    state: ?*OpaqueLuaState = null;

    const OpaqueLuaState = extern struct {
        // Lua state structure - minimal for build compatibility
        _dummy: [1]u8,
    };

    pub fn init() !Self {
        return Self{ .state = @ptrCast(?OpaqueLuaState, @ptrFromInt(@intCast(usize, 0))) };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn getTop(self: Self) c_int {
        return 0;
    }

    pub fn setTop(self: Self, idx: c_int) void {
        _ = idx;
    }

    pub fn pushNil(self: Self) void {}

    pub fn pushBoolean(self: Self, b: bool) void {
        _ = b;
    }

    pub fn pushNumber(self: Self, n: f64) void {
        _ = n;
    }

    pub fn pushInteger(self: Self, n: i64) void {
        _ = n;
    }

    pub fn pushLightUserData(self: Self, p: ?*anyopaque) void {
        _ = p;
    }

    pub fn pushCFunction(self: Self, f: fn(?*Lua) callconv(.C) c_int) void {
        _ = f;
    }

    pub fn getType(self: Self, idx: c_int) Type {
        return .none;
    }

    pub fn isNil(self: Self, idx: c_int) bool {
        return false;
    }

    pub fn isNone(self: Self, idx: c_int) bool {
        return false;
    }

    pub fn isNoneOrNil(self: Self, idx: c_int) bool {
        return false;
    }

    pub fn toBoolean(self: Self, idx: c_int) bool {
        return false;
    }

    pub fn toNumber(self: Self, idx: c_int) f64 {
        return 0.0;
    }

    pub fn toInteger(self: Self, idx: c_int) i64 {
        return 0;
    }

    pub fn toUnsigned(self: Self, idx: c_int) u64 {
        return 0;
    }

    pub fn toString(self: Self, idx: c_int) ?[]const u8 {
        return null;
    }

    pub fn tolstring(self: Self, idx: c_int, len: ?*usize) ?[]const u8 {
        _ = len;
        return null;
    }

    pub fn objlen(self: Self, idx: c_int) usize {
        return 0;
    }

    pub fn toUserData(self: Self, idx: c_int) ?*anyopaque {
        return null;
    }

    pub fn tocfunction(self: Self, idx: c_int) ?fn(?*Lua) callconv(.C) c_int {
        return null;
    }

    pub fn tthread(self: Self, idx: c_int) ?*Lua {
        return null;
    }

    pub fn pushString(self: Self, s: []const u8) void {
        _ = s;
    }

    pub fn pushlstring(self: Self, s: ?[*]const u8, l: usize) void {
        _ = s;
        _ = l;
    }

    pub fn pushvfstring(self: Self, fmt: ?[*]const u8, argp: ?*anyopaque) void {
        _ = fmt;
        _ = argp;
    }

    pub fn pushfstring(self: Self, fmt: ?[*]const u8, ...) void {
        _ = fmt;
    }

    pub fn pushcclosure(self: Self, f: ?fn(?*Lua) callconv(.C) c_int, n: c_int) void {
        _ = f;
        _ = n;
    }

    pub fn pushthread(self: Self) void {}

    pub fn getglobal(self: Self, name: ?[*]const u8) void {
        _ = name;
    }

    pub fn setglobal(self: Self, name: ?[*]const u8) void {
        _ = name;
    }

    pub fn gettable(self: Self, idx: c_int) void {
        _ = idx;
    }

    pub fn settable(self: Self, idx: c_int) void {
        _ = idx;
    }

    pub fn getfield(self: Self, idx: c_int, k: ?[*]const u8) void {
        _ = idx;
        _ = k;
    }

    pub fn setfield(self: Self, idx: c_int, k: ?[*]const u8) void {
        _ = idx;
        _ = k;
    }

    pub fn geti(self: Self, idx: c_int, n: i64) void {
        _ = idx;
        _ = n;
    }

    pub fn seti(self: Self, idx: c_int, n: i64) void {
        _ = idx;
        _ = n;
    }

    pub fn rawget(self: Self, idx: c_int) void {
        _ = idx;
    }

    pub fn rawset(self: Self, idx: c_int) void {
        _ = idx;
    }

    pub fn rawgeti(self: Self, idx: c_int, n: i64) void {
        _ = idx;
        _ = n;
    }

    pub fn rawseti(self: Self, idx: c_int, n: i64) void {
        _ = idx;
        _ = n;
    }

    pub fn getmetatable(self: Self, objindex: c_int) void {
        _ = objindex;
    }

    pub fn getuservalue(self: Self, idx: c_int) void {
        _ = idx;
    }

    pub fn setuservalue(self: Self, idx: c_int) void {
        _ = idx;
    }

    pub fn setmetatable(self: Self, objindex: c_int) void {
        _ = objindex;
    }

    pub fn next(self: Self, idx: c_int) c_int {
        return 0;
    }

    pub fn call(self: Self, nargs: c_int, nresults: c_int) Status {
        _ = nargs;
        _ = nresults;
        return .ok;
    }

    pub fn pcall(self: Self, nargs: c_int, nresults: c_int, errfunc: c_int) Status {
        _ = nargs;
        _ = nresults;
        _ = errfunc;
        return .ok;
    }

    pub fn cpcall(self: Self, func: ?fn(?*anyopaque) callconv(.C) c_int, ud: ?*anyopaque) Status {
        _ = func;
        _ = ud;
        return .ok;
    }

    pub fn load(self: Self, reader: ?fn(?*anyopaque, ?[*]u8, ?*usize) callconv(.C) c_int, dt: ?*anyopaque, chunkname: ?[*]const u8, mode: ?[*]const u8) Status {
        _ = reader;
        _ = dt;
        _ = chunkname;
        _ = mode;
        return .ok;
    }

    pub fn dump(self: Self, writer: ?fn(?*anyopaque, ?[*]u8, usize) callconv(.C) c_int, dt: ?*anyopaque) c_int {
        _ = writer;
        _ = dt;
        return 0;
    }

    pub fn yield(self: Self, nresults: c_int) c_int {
        _ = nresults;
        return 0;
    }

    pub fn resume(self: Self, from: ?*Lua, nargs: c_int) c_int {
        _ = from;
        _ = nargs;
        return 0;
    }

    pub fn status(self: Self) c_int {
        return 0;
    }

    pub fn gc(self: Self, what: c_int, data: c_int) c_int {
        _ = what;
        _ = data;
        return 0;
    }

    pub fn error(self: Self) noreturn {
        @panic("Lua error");
    }

    pub const LuaRegistryIndex: c_int = 0;
};
