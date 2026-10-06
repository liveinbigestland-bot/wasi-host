const std = @import("std");
const lua = @import("api.zig");
const Lua = lua.Lua;
const events = @import("events.zig");
const plugin_mod = @import("../plugin/manager.zig");
const content_mod = @import("../plugin/content.zig");

pub const HostFunctions = struct {
    // ── 栈操作辅助 ──────────────────────────────────────────────

    /// 压入 nil + 错误字符串，返回 2（用于 (value, err) 风格）
    fn pushNilErr(L: ?*Lua, msg: [*:0]const u8) c_int {
        lua.lua_pushnil(L);
        lua.lua_pushstring(L, msg);
        return 2;
    }

    /// 压入 false + 错误字符串，返回 2
    fn pushFalseErr(L: ?*Lua, msg: [*:0]const u8) c_int {
        lua.lua_pushboolean(L, 0);
        lua.lua_pushstring(L, msg);
        return 2;
    }

    fn setFieldInt(L: ?*Lua, key: [*:0]const u8, val: i64) void {
        lua.lua_pushinteger(L, val);
        lua.lua_setfield(L, -2, key);
    }

    fn setFieldBoolField(L: ?*Lua, key: [*:0]const u8, val: bool) void {
        lua.lua_pushboolean(L, @intFromBool(val));
        lua.lua_setfield(L, -2, key);
    }

    fn setFieldStr(L: ?*Lua, key: [*:0]const u8, val: []const u8) void {
        lua.lua_pushlstring(L, val.ptr, val.len);
        lua.lua_setfield(L, -2, key);
    }

    /// 读取 table 字段（number），读完恢复栈
    fn readI64Field(L: ?*Lua, idx: c_int, key: [*:0]const u8) ?i64 {
        lua.lua_getfield(L, idx, key);
        defer lua.lua_pop(L, 1);
        if (lua.lua_type(L, -1) == .number) return lua.lua_tointeger(L, -1);
        return null;
    }

    fn readBoolField(L: ?*Lua, idx: c_int, key: [*:0]const u8) ?bool {
        lua.lua_getfield(L, idx, key);
        defer lua.lua_pop(L, 1);
        if (lua.lua_type(L, -1) == .boolean) return lua.lua_toboolean(L, -1) != 0;
        return null;
    }

    fn isActiveState(s: plugin_mod.State) bool {
        return s == .starting or s == .running or s == .paused;
    }

    // ── wasm_start / stop / pause / resume ──────────────────────

    /// wasm_start(plugin_ref, [config]) -> handle, err
    /// plugin_ref: 裸名称（解析为 plug/<ref>.wasm）或以 .wasm 结尾的路径
    /// config: { mem_kb=512, timeout_ms=5000, network=false, write=false, allow_host_info=true }
    fn wasmStart(L: ?*Lua) callconv(.C) c_int {
        if (lua.lua_type(L, 1) != .string)
            return pushNilErr(L, "Expected plugin name/path as string");

        const ref = std.mem.span(lua.lua_tolstring(L, 1, null).?);

        var cfg = plugin_mod.ConfigSnapshot{};
        if (lua.lua_type(L, 2) == .table) {
            if (readI64Field(L, 2, "mem_kb")) |v| cfg.mem_kb = @intCast(v);
            if (readI64Field(L, 2, "timeout_ms")) |v| cfg.timeout_ms = @intCast(v);
            if (readBoolField(L, 2, "network")) |v| cfg.network = v;
            if (readBoolField(L, 2, "write")) |v| cfg.write = v;
            if (readBoolField(L, 2, "allow_host_info")) |v| cfg.allow_host_info = v;
        }

        const pm = plugin_mod.global_manager orelse
            return pushNilErr(L, "Plugin manager not initialized");

        const handle = pm.startFromFile(ref, cfg) catch |e| {
            lua.lua_pushnil(L);
            lua.lua_pushlstring(L, @errorName(e).ptr, @errorName(e).len);
            return 2;
        };

        lua.lua_pushinteger(L, @intCast(handle));
        lua.lua_pushnil(L);
        return 2;
    }

    /// wasm_stop(handle) -> success, err
    fn wasmStop(L: ?*Lua) callconv(.C) c_int {
        if (lua.lua_type(L, 1) != .number)
            return pushFalseErr(L, "Expected plugin handle as number");

        const pm = plugin_mod.global_manager orelse
            return pushFalseErr(L, "Plugin manager not initialized");

        const ok = pm.cancel(@intCast(lua.lua_tointeger(L, 1)));
        lua.lua_pushboolean(L, @intFromBool(ok));
        if (ok) {
            lua.lua_pushnil(L);
        } else {
            lua.lua_pushstring(L, "No active plugin with that handle");
        }
        return 2;
    }

    /// wasm_pause(handle) -> success, err
    fn wasmPause(L: ?*Lua) callconv(.C) c_int {
        if (lua.lua_type(L, 1) != .number)
            return pushFalseErr(L, "Expected plugin handle as number");

        const pm = plugin_mod.global_manager orelse
            return pushFalseErr(L, "Plugin manager not initialized");

        const ok = pm.pause(@intCast(lua.lua_tointeger(L, 1)));
        lua.lua_pushboolean(L, @intFromBool(ok));
        if (ok) {
            lua.lua_pushnil(L);
        } else {
            lua.lua_pushstring(L, "Plugin cannot be paused");
        }
        return 2;
    }

    /// wasm_resume(handle) -> success, err
    fn wasmResume(L: ?*Lua) callconv(.C) c_int {
        if (lua.lua_type(L, 1) != .number)
            return pushFalseErr(L, "Expected plugin handle as number");

        const pm = plugin_mod.global_manager orelse
            return pushFalseErr(L, "Plugin manager not initialized");

        const ok = pm.resumePlugin(@intCast(lua.lua_tointeger(L, 1)));
        lua.lua_pushboolean(L, @intFromBool(ok));
        if (ok) {
            lua.lua_pushnil(L);
        } else {
            lua.lua_pushstring(L, "Plugin cannot be resumed");
        }
        return 2;
    }

    // ── 内容寻址发布 / 拉取 ─────────────────────────────────────

    /// 读取本地插件字节：裸名称 → plug/<ref>.wasm；.wasm 结尾视为路径
    fn readLocalBytes(alloc: std.mem.Allocator, ref: []const u8) ![]u8 {
        const path = if (std.mem.endsWith(u8, ref, ".wasm"))
            try alloc.dupe(u8, ref)
        else
            try std.fmt.allocPrint(alloc, "plug/{s}.wasm", .{ref});
        defer alloc.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch return error.PluginFileNotFound;
        defer file.close();
        return try file.readToEndAlloc(alloc, 32 * 1024 * 1024);
    }

    /// wasm_publish(ref) -> hash, err
    /// 读取本地插件字节码，经 DHT 内容寻址发布，返回 64 字符 SHA256
    fn wasmPublish(L: ?*Lua) callconv(.C) c_int {
        if (lua.lua_type(L, 1) != .string)
            return pushNilErr(L, "Expected plugin name/path as string");
        const ref = std.mem.span(lua.lua_tolstring(L, 1, null).?);

        const pm = plugin_mod.global_manager orelse
            return pushNilErr(L, "Plugin manager not initialized");
        const chord = content_mod.getChord() orelse
            return pushNilErr(L, "P2P/DHT unavailable");

        const bytes = readLocalBytes(pm.allocator, ref) catch |e| {
            lua.lua_pushnil(L);
            lua.lua_pushlstring(L, @errorName(e).ptr, @errorName(e).len);
            return 2;
        };
        defer pm.allocator.free(bytes);

        const hex = content_mod.publish(chord, pm.allocator, bytes) catch |e| {
            lua.lua_pushnil(L);
            lua.lua_pushlstring(L, @errorName(e).ptr, @errorName(e).len);
            return 2;
        };

        lua.lua_pushlstring(L, &hex, hex.len);
        lua.lua_pushnil(L);
        return 2;
    }

    /// wasm_fetch(hash, [opts]) -> info table, err
    /// opts: { mem_kb, timeout_ms, network, write, allow_host_info, load=true }
    /// 返回 { hash, size, source="cache"|"dht", handle? }
    fn wasmFetch(L: ?*Lua) callconv(.C) c_int {
        if (lua.lua_type(L, 1) != .string)
            return pushNilErr(L, "Expected content hash as string");

        var cfg = plugin_mod.ConfigSnapshot{};
        var want_load = true;
        if (lua.lua_type(L, 2) == .table) {
            if (readI64Field(L, 2, "mem_kb")) |v| cfg.mem_kb = @intCast(v);
            if (readI64Field(L, 2, "timeout_ms")) |v| cfg.timeout_ms = @intCast(v);
            if (readBoolField(L, 2, "network")) |v| cfg.network = v;
            if (readBoolField(L, 2, "write")) |v| cfg.write = v;
            if (readBoolField(L, 2, "allow_host_info")) |v| cfg.allow_host_info = v;
            if (readBoolField(L, 2, "load")) |v| want_load = v;
        }

        const pm = plugin_mod.global_manager orelse
            return pushNilErr(L, "Plugin manager not initialized");

        var hex_buf: [content_mod.HASH_HEX_LEN]u8 = undefined;
        const raw_hash = std.mem.span(lua.lua_tolstring(L, 1, null).?);
        const hex = content_mod.normalizeHash(raw_hash) catch {
            return pushNilErr(L, "Invalid hash: expected 64 hex chars");
        };
        hex_buf = hex;

        // 1. 缓存优先
        var source: []const u8 = "cache";
        var bytes = content_mod.readCache(pm.allocator, &hex_buf) catch null;

        if (bytes == null) {
            const chord = content_mod.getChord() orelse
                return pushNilErr(L, "P2P/DHT unavailable");
            const fetched = content_mod.fetch(chord, pm.allocator, &hex_buf) catch |e| {
                lua.lua_pushnil(L);
                lua.lua_pushlstring(L, @errorName(e).ptr, @errorName(e).len);
                return 2;
            };
            content_mod.writeCache(&hex_buf, fetched) catch {};
            source = "dht";
            bytes = fetched;
        }
        const code = bytes.?;

        // 2. 仅预取：信息入栈后释放字节
        if (!want_load) {
            defer pm.allocator.free(code);
            pushFetchInfoTable(L, &hex_buf, code.len, source, null);
            return 1;
        }

        // 3. 立即装载（字节所有权移交 worker）
        const name = std.fmt.allocPrint(pm.allocator, "{s}.wasm", .{hex_buf[0..16]}) catch {
            pm.allocator.free(code);
            return pushNilErr(L, "Out of memory");
        };
        defer pm.allocator.free(name);

        const handle = pm.startFromBytes(name, code, cfg) catch |e| {
            lua.lua_pushnil(L);
            lua.lua_pushlstring(L, @errorName(e).ptr, @errorName(e).len);
            return 2;
        };

        pushFetchInfoTable(L, &hex_buf, code.len, source, handle);
        return 1;
    }

    /// 压入 fetch 结果表
    fn pushFetchInfoTable(
        L: ?*Lua,
        hex: *const [content_mod.HASH_HEX_LEN]u8,
        size: usize,
        source: []const u8,
        handle: ?u64,
    ) void {
        lua.lua_createtable(L, 0, if (handle != null) 4 else 3);
        setFieldStr(L, "hash", hex);
        setFieldInt(L, "size", @intCast(size));
        setFieldStr(L, "source", source);
        if (handle) |h| setFieldInt(L, "handle", @intCast(h));
    }

    // ── 列表 / 信息 ─────────────────────────────────────────────

    /// wasm_list_plugins() -> array of .wasm file names under plug/
    fn wasmListPlugins(L: ?*Lua) callconv(.C) c_int {
        const pm = plugin_mod.global_manager orelse {
            lua.lua_pushnil(L);
            return 1;
        };

        const names = pm.listPluginFiles(pm.allocator) catch {
            lua.lua_pushnil(L);
            return 1;
        };
        defer {
            for (names) |n| pm.allocator.free(n);
            pm.allocator.free(names);
        }

        lua.lua_createtable(L, @intCast(names.len), 0);
        for (names, 0..) |n, i| {
            lua.lua_pushlstring(L, n.ptr, n.len);
            lua.lua_seti(L, -2, @intCast(i + 1));
        }
        return 1;
    }

    /// wasm_list_active() -> array of info tables for active plugins
    fn wasmListActive(L: ?*Lua) callconv(.C) c_int {
        const pm = plugin_mod.global_manager orelse {
            lua.lua_pushnil(L);
            return 1;
        };

        const infos = pm.snapshotAll(pm.allocator) catch {
            lua.lua_pushnil(L);
            return 1;
        };
        defer {
            for (infos) |info| plugin_mod.Manager.freeInfo(pm.allocator, info);
            pm.allocator.free(infos);
        }

        var count: c_int = 0;
        for (infos) |info| if (isActiveState(info.state)) {
            count += 1;
        };

        lua.lua_createtable(L, count, 0);
        var i: c_int = 0;
        for (infos) |info| {
            if (!isActiveState(info.state)) continue;
            i += 1;

            lua.lua_createtable(L, 0, 4);
            setFieldInt(L, "handle", @intCast(info.handle));
            setFieldStr(L, "name", info.name);
            setFieldStr(L, "state", @tagName(info.state));
            setFieldInt(L, "duration_ms", @intCast(info.duration_ms));
            lua.lua_seti(L, -2, i);
        }
        return 1;
    }

    /// wasm_plugin_info(handle|name) -> info table
    fn wasmPluginInfo(L: ?*Lua) callconv(.C) c_int {
        const pm = plugin_mod.global_manager orelse
            return pushNilErr(L, "Plugin manager not initialized");

        switch (lua.lua_type(L, 1)) {
            .number => {
                const maybe_info = pm.snapshot(
                    pm.allocator,
                    @intCast(lua.lua_tointeger(L, 1)),
                ) catch {
                    lua.lua_pushnil(L);
                    return 1;
                };
                if (maybe_info) |info| {
                    defer plugin_mod.Manager.freeInfo(pm.allocator, info);
                    pushInfoTable(L, info);
                } else {
                    lua.lua_pushnil(L);
                }
            },
            .string => {
                const plugin_name = std.mem.span(lua.lua_tolstring(L, 1, null).?);

                lua.lua_createtable(L, 0, 4);
                setFieldStr(L, "name", plugin_name);
                setFieldStr(L, "state", "unknown");
                setFieldInt(L, "default_mem_kb", 512);
                setFieldInt(L, "default_timeout_ms", 5000);
            },
            else => return pushNilErr(L, "Expected plugin handle or name"),
        }

        return 1;
    }

    /// 将插件信息快照压栈为 table
    fn pushInfoTable(L: ?*Lua, info: plugin_mod.Info) void {
        lua.lua_createtable(L, 0, 10);

        setFieldInt(L, "handle", @intCast(info.handle));
        setFieldStr(L, "name", info.name);
        setFieldStr(L, "state", @tagName(info.state));
        setFieldInt(L, "mem_kb", @intCast(info.config.mem_kb));
        setFieldInt(L, "timeout_ms", @intCast(info.config.timeout_ms));
        setFieldBoolField(L, "network", info.config.network);
        setFieldBoolField(L, "write", info.config.write);
        setFieldInt(L, "duration_ms", @intCast(info.duration_ms));
        setFieldInt(L, "exit_code", info.exit_code);
        if (info.error_message) |m| setFieldStr(L, "error", m);
    }

    // ── 事件回调注册 ───────────────────────────────────────────

    /// Requires global LuaStateManager reference to be set via setLuaStateManager()
    var global_lua_manager: ?*@import("state.zig").LuaStateManager = null;

    /// event_type -> registry ref
    var event_refs: ?std.StringHashMap(c_int) = null;

    pub fn setLuaStateManager(manager: *@import("state.zig").LuaStateManager) void {
        global_lua_manager = manager;
    }

    /// 查询经 wasm_on_event 注册的回调 registry ref；无则 null
    pub fn lookupEventRef(event_type: []const u8) ?c_int {
        if (event_refs) |map| {
            return map.get(event_type);
        }
        return null;
    }

    /// wasm_on_event(event_type, callback) -> success, err
    fn wasmOnEvent(L: ?*Lua) callconv(.C) c_int {
        const mgr = global_lua_manager orelse
            return pushFalseErr(L, "LuaStateManager not initialized");

        if (lua.lua_type(L, 1) != .string)
            return pushFalseErr(L, "Expected event_type as string");
        if (lua.lua_type(L, 2) != .function)
            return pushFalseErr(L, "Expected callback as function");

        const event_type = std.mem.span(lua.lua_tolstring(L, 1, null).?);
        if (!checkValidEventType(event_type))
            return pushFalseErr(L, "Invalid event_type");

        // 为回调创建持久引用
        lua.lua_pushvalue(L, 2);
        const ref = lua.luaL_ref(L, lua.LuaRegistryIndex);
        errdefer lua.luaL_unref(L, lua.LuaRegistryIndex, ref);

        if (event_refs == null) {
            event_refs = std.StringHashMap(c_int).init(mgr.allocator);
        }
        var map = &event_refs.?;

        // 替换同类型旧回调
        if (map.fetchRemove(event_type)) |old| {
            lua.luaL_unref(L, lua.LuaRegistryIndex, old.value);
            mgr.allocator.free(old.key);
        }

        const key = mgr.allocator.dupe(u8, event_type) catch {
            return pushFalseErr(L, "Out of memory");
        };
        map.put(key, ref) catch {
            mgr.allocator.free(key);
            return pushFalseErr(L, "Out of memory");
        };

        lua.lua_pushboolean(L, 1);
        lua.lua_pushnil(L);
        return 2;
    }

    /// wasm_off_event(event_type) -> success, err
    fn wasmOffEvent(L: ?*Lua) callconv(.C) c_int {
        const mgr = global_lua_manager orelse
            return pushFalseErr(L, "LuaStateManager not initialized");

        if (lua.lua_type(L, 1) != .string)
            return pushFalseErr(L, "Expected event_type as string");

        const event_type = std.mem.span(lua.lua_tolstring(L, 1, null).?);

        if (event_refs) |*map| {
            if (map.fetchRemove(event_type)) |old| {
                lua.luaL_unref(L, lua.LuaRegistryIndex, old.value);
                mgr.allocator.free(old.key);
            }
        }

        lua.lua_pushboolean(L, 1);
        lua.lua_pushnil(L);
        return 2;
    }

    // ── 连接级配置（预留） ──────────────────────────────────────

    /// wasm_get_connection_config(connection_id) -> config table
    fn wasmGetConnectionConfig(L: ?*Lua) callconv(.C) c_int {
        const mgr = global_lua_manager orelse
            return pushNilErr(L, "LuaStateManager not initialized");

        if (lua.lua_type(L, 1) != .number)
            return pushNilErr(L, "Expected connection_id as number");

        const connection_id: u64 = @intCast(lua.lua_tointeger(L, 1));
        if (!mgr.connection_states.contains(connection_id))
            return pushNilErr(L, "Connection not found");

        lua.lua_createtable(L, 0, 4);
        setFieldInt(L, "mem_kb", 512);
        setFieldInt(L, "timeout_ms", 5000);
        setFieldBoolField(L, "network", false);
        setFieldBoolField(L, "write", false);
        return 1;
    }

    /// wasm_set_connection_config(connection_id, config) -> success, err
    fn wasmSetConnectionConfig(L: ?*Lua) callconv(.C) c_int {
        const mgr = global_lua_manager orelse
            return pushFalseErr(L, "LuaStateManager not initialized");

        if (lua.lua_type(L, 1) != .number)
            return pushFalseErr(L, "Expected connection_id as number");
        if (lua.lua_type(L, 2) != .table)
            return pushFalseErr(L, "Expected config as table");

        const connection_id: u64 = @intCast(lua.lua_tointeger(L, 1));
        if (!mgr.connection_states.contains(connection_id))
            return pushFalseErr(L, "Connection not found");

        // TODO: 应用到连接级 Lua 状态
        lua.lua_pushboolean(L, 1);
        lua.lua_pushnil(L);
        return 2;
    }

    /// wasm_remove_connection_state(connection_id) -> success, err
    fn wasmRemoveConnectionState(L: ?*Lua) callconv(.C) c_int {
        const mgr = global_lua_manager orelse
            return pushFalseErr(L, "LuaStateManager not initialized");

        if (lua.lua_type(L, 1) != .number)
            return pushFalseErr(L, "Expected connection_id as number");

        const connection_id: u64 = @intCast(lua.lua_tointeger(L, 1));
        mgr.removeConnectionState(connection_id);

        lua.lua_pushboolean(L, 1);
        lua.lua_pushnil(L);
        return 2;
    }

    // ── 注册 ───────────────────────────────────────────────────

    fn checkValidEventType(event_type: []const u8) bool {
        const types = [_][]const u8{
            "plugin_start",
            "plugin_stop",
            "plugin_error",
            "plugin_complete",
            "plugin_timeout",
            "chord_node_join",
            "chord_successor_change",
            "dht_put",
        };

        for (types) |t| {
            if (std.mem.eql(u8, t, event_type)) {
                return true;
            }
        }
        return false;
    }

    /// 将全部 host 函数注册到指定 Lua 状态
    pub fn register(state: ?*Lua) void {
        const regs = .{
            .{ "wasm_start", wasmStart },
            .{ "wasm_stop", wasmStop },
            .{ "wasm_pause", wasmPause },
            .{ "wasm_resume", wasmResume },
            .{ "wasm_publish", wasmPublish },
            .{ "wasm_fetch", wasmFetch },
            .{ "wasm_list_plugins", wasmListPlugins },
            .{ "wasm_list_active", wasmListActive },
            .{ "wasm_plugin_info", wasmPluginInfo },
            .{ "wasm_on_event", wasmOnEvent },
            .{ "wasm_off_event", wasmOffEvent },
            .{ "wasm_get_connection_config", wasmGetConnectionConfig },
            .{ "wasm_set_connection_config", wasmSetConnectionConfig },
            .{ "wasm_remove_connection_state", wasmRemoveConnectionState },
        };

        inline for (regs) |r| {
            lua.lua_pushcfunction(state, r[1]);
            lua.lua_setglobal(state, r[0]);
        }
    }
};
