const std = @import("std");
const w = @import("win32").everything;

const protocol = @import("protocol.zig");
const input = @import("input.zig");

const version = "1.5.1";

const MAX_EVENTS: usize = 1 << 20;
const MAX_DEVICES: usize = 256;
const MAX_RECORD_BYTES: usize = (8 + MAX_DEVICES + MAX_EVENTS) * 4;
const RAW_QUEUE_CAPACITY: usize = 256;
const RAW_CONTROLLER_CAPACITY: usize = 16;
const RAW_INPUT_CAPACITY: usize = 64 * 1024;
const PREPARSED_DATA_CAPACITY: usize = 16 * 1024;

const Address = enum(usize) {
    none = 0,
    _,

    fn at(value: usize) Address {
        return @fromBackingInt(value);
    }

    fn fromPtr(pointer: anytype) Address {
        return at(@intFromPtr(pointer));
    }

    fn ptr(self: Address, comptime T: type) T {
        return @ptrFromInt(@backingInt(self));
    }

    fn add(self: Address, offset: usize) Address {
        return at(@backingInt(self) + offset);
    }

    fn sub(self: Address, offset: usize) Address {
        return at(@backingInt(self) - offset);
    }
};

// Fixed addresses found in the March 2010 build of TMNF.
const FixedAddress = enum(usize) {
    image_base = 0x0040_0000,
    patch_marker_a = 0x005e_b5cc,
    patch_marker_b = 0x005e_b47c,
    serialization_vtable_a = 0x00b6_60e4,
    serialization_vtable_b = 0x00b6_60dc,
    frame_site = 0x0092_2f5e,
    serialize_site = 0x0092_41b5,
    input_setup_site = 0x0048_4733,
    analog_site = 0x008f_7881,
    analog_gate_set_site = 0x0054_9bd6,
    analog_gate_clear_site = 0x0048_2f66,
    window_site = 0x009a_0936,
    force_update_site = 0x0067_67f5,
    disable_call_site = 0x0049_1c95,
    analog_destination = 0x00d5_77f0,
    game_root_holder = 0x0040_1580,
    get_race = 0x0047_b900,
    game_string_cstr = 0x0093_5290,
    game_string_assign = 0x008f_f6d0,
    game_writer = 0x0090_9c00,
    game_set_label = 0x0076_9d80,
    _,

    fn at(addr: usize) FixedAddress {
        return @fromBackingInt(addr);
    }

    fn add(self: FixedAddress, offset: usize) FixedAddress {
        return at(@backingInt(self) + offset);
    }

    fn address(self: FixedAddress) Address {
        return Address.at(@backingInt(self));
    }

    fn ptr(self: FixedAddress, comptime T: type) T {
        return self.address().ptr(T);
    }
};

fn DeviceInstance(comptime Char: type) type {
    return extern struct {
        size: u32,
        guid_instance: w.Guid,
        guid_product: w.Guid,
        device_type: u32,
        instance_name: [260]Char,
        product_name: [260]Char,
        ff_driver: w.Guid,
        usage_page: u16,
        usage: u16,
    };
}

/// DirectInput byte offsets.
const DeviceOffset = enum(u32) {
    x = 0,
    y = 4,
    z = 8,
    rx = 12,
    ry = 16,
    rz = 20,
    pov_0 = 32,
    pov_1 = 36,
    pov_2 = 40,
    pov_3 = 44,
    button_0 = 48,
    _,

    fn at(value: u32) DeviceOffset {
        return @fromBackingInt(value);
    }

    fn isButton(self: DeviceOffset) bool {
        return @backingInt(self) -% @backingInt(DeviceOffset.button_0) < 128;
    }
};

const DeviceDataFlags = packed struct(u32) {
    peek: bool,
    reserved: u31 = 0,
};
const RawInputKind = enum(u32) {
    mouse = 0,
    keyboard = 1,
    hid = 2,
    _,
};
const DesktopUsage = enum(u16) {
    x = 0x30,
    y = 0x31,
    z = 0x32,
    rx = 0x33,
    ry = 0x34,
    rz = 0x35,
    hat = 0x39,
};
const ProductId = packed struct(u32) {
    vendor: u16,
    product: u16,

    const unknown: ProductId = .{
        .vendor = 0,
        .product = 0,
    };
};

const DeviceObjectData = extern struct {
    offset: DeviceOffset,
    data: u32,
    timestamp: u32,
    sequence: u32,
    app_data: usize,
};
const RawDeviceInfo = extern struct {
    size: u32,
    kind: RawInputKind,
    payload: [6]u32,
};
const HidpCaps = extern struct {
    usage: u16,
    usage_page: u16,
    input_report_bytes: u16,
    output_report_bytes: u16,
    feature_report_bytes: u16,
    reserved: [17]u16,
    link_nodes: u16,
    input_button_caps: u16,
    input_value_caps: u16,
    input_data_indices: u16,
    output_button_caps: u16,
    output_value_caps: u16,
    output_data_indices: u16,
    feature_button_caps: u16,
    feature_value_caps: u16,
    feature_data_indices: u16,
};
const HidpRange = extern struct {
    usage_min: u16,
    usage_max: u16,
    string_min: u16,
    string_max: u16,
    designator_min: u16,
    designator_max: u16,
    data_index_min: u16,
    data_index_max: u16,
};
const HidpNotRange = extern struct {
    usage: u16,
    reserved1: u16,
    string_index: u16,
    reserved2: u16,
    designator_index: u16,
    reserved3: u16,
    data_index: u16,
    reserved4: u16,
};
const HidpUsage = extern union {
    range: HidpRange,
    single: HidpNotRange,
};
const HidpButtonCaps = extern struct {
    usage_page: u16,
    report_id: u8,
    is_alias: u8,
    bit_field: u16,
    link_collection: u16,
    link_usage: u16,
    link_usage_page: u16,
    is_range: u8,
    is_string_range: u8,
    is_designator_range: u8,
    is_absolute: u8,
    reserved: [10]u32,
    usages: HidpUsage,
};
const HidpValueCaps = extern struct {
    usage_page: u16,
    report_id: u8,
    is_alias: u8,
    bit_field: u16,
    link_collection: u16,
    link_usage: u16,
    link_usage_page: u16,
    is_range: u8,
    is_string_range: u8,
    is_designator_range: u8,
    is_absolute: u8,
    has_null: u8,
    reserved: u8,
    bit_size: u16,
    report_count: u16,
    reserved2: [5]u16,
    units_exponent: u32,
    units: u32,
    logical_min: i32,
    logical_max: i32,
    physical_min: i32,
    physical_max: i32,
    usages: HidpUsage,
};
const GameText = extern struct {
    length: u32,
    pointer: [*]const u16,
};
const GameStringText = extern struct {
    pointer: [*]const u8,
    length: u32,
};

const AcquireFn = *const fn (?*anyopaque) callconv(.winapi) w.HRESULT;
const GetStateFn = *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.winapi) w.HRESULT;
const GetDataFn = *const fn (?*anyopaque, u32, ?*DeviceObjectData, ?*u32, u32) callconv(.winapi) w.HRESULT;
const GetDeviceInfoFn = *const fn (?*anyopaque, *anyopaque) callconv(.winapi) w.HRESULT;
const ReleaseFn = *const fn (?*anyopaque) callconv(.winapi) u32;
const CreateDeviceFn = *const fn (?*anyopaque, *const w.Guid, *?*anyopaque, ?*anyopaque) callconv(.winapi) w.HRESULT;
const DirectInput8CreateFn = @TypeOf(&w.DirectInput8Create);
const GetRaceFn = *const fn (?*anyopaque) callconv(.{ .x86_thiscall = .{} }) ?*u8;
const GameStringFn = *const fn (?*anyopaque) callconv(.{ .x86_thiscall = .{} }) ?[*]const u8;
const GameStringAssignFn = *const fn (?*anyopaque, *const GameStringText) callconv(.{ .x86_thiscall = .{} }) void;
const GameWriterFn = *const fn (?*anyopaque, [*]const u8, u32) callconv(.{ .x86_thiscall = .{} }) u32;
const GameSetLabelFn = *const fn (?*anyopaque, *const GameText) callconv(.{ .x86_thiscall = .{} }) u32;
const DetourFn = *const fn () callconv(.naked) void;

// Partial COM vtable layouts. Reserved slots are never called or modified.
const DirectInputVtable = extern struct {
    reserved_0: [2]usize,
    release: ReleaseFn,
    create_device: CreateDeviceFn,
};
const DeviceVtable = extern struct {
    reserved_0: [2]usize,
    release: ReleaseFn,
    reserved_3: [4]usize,
    acquire: AcquireFn,
    unacquire: AcquireFn,
    get_state: GetStateFn,
    get_data: GetDataFn,
    reserved_11: [4]usize,
    get_info: GetDeviceInfoFn,
    reserved_16: [9]usize,
    poll: AcquireFn,
};
const DEVICE_HOOK_BYTES = @offsetOf(DeviceVtable, "poll") + @sizeOf(AcquireFn) - @offsetOf(DeviceVtable, "acquire");

// Recorder state derived from DirectInput and the game's action history.
const DeviceClass = enum(u8) { other, keyboard, controller };
const DeviceCache = struct {
    pointer: ?*anyopaque = null,
    class: DeviceClass = .other,
    acquired: bool = false,
    raw_handle: ?w.HANDLE = null,
    product_id: ProductId = .unknown,
    state_len: usize = 0,
    state: [272]u8 = undefined,

    fn ensureStateLength(self: *DeviceCache, length: usize) void {
        if (self.state_len >= length) return;
        @memset(self.state[self.state_len..length], 0);
        self.state_len = length;
    }
};

// These values are added to (or subtracted from) timestamps in the replay record.
const InputKind = enum(u8) {
    key_up = 0,
    key_down = 1,
    button_up = 2,
    button_down = 3,
    axis = 4,
};
const InputEvent = struct {
    stamp: i32,
    kind: InputKind,
};
const HistoryAction = packed struct(u32) {
    value: u16,
    reserved: u8,
    index: u8,
};
const EnvironmentFlags = packed struct(u32) {
    wine: bool = false,
    negative_elapsed: bool = false,
    alternate: bool = false,
    debugger: bool = false,
    reserved: u28 = 0,
};

// Generic Desktop usages and their DirectInput state offsets, in event order.
const CONTROLLER_AXES = [_]struct { usage: DesktopUsage, offset: DeviceOffset }{
    .{ .usage = .x, .offset = .x },
    .{ .usage = .y, .offset = .y },
    .{ .usage = .z, .offset = .z },
    .{ .usage = .rx, .offset = .rx },
    .{ .usage = .ry, .offset = .ry },
    .{ .usage = .rz, .offset = .rz },
    .{ .usage = .hat, .offset = .pov_0 },
};
const RawQueue = struct {
    head: usize = 0,
    length: usize = 0,
    events: [RAW_QUEUE_CAPACITY]DeviceObjectData = undefined,
};
const RawController = struct {
    handle: ?w.HANDLE = null,
    product_id: ProductId = .unknown,
    state: [272]u8 = undefined,
    queue: RawQueue = .{},

    fn reset(self: *RawController) void {
        @memset(&self.state, 0);
        // DirectInput represents a neutral POV hat with all bits set.
        for ([_]DeviceOffset{ .pov_0, .pov_1, .pov_2, .pov_3 }) |offset| {
            std.mem.writeInt(u32, self.state[@backingInt(offset)..][0..4], 0xffff_ffff, .little);
        }
        self.queue = .{};
    }
};

const PatchState = struct {
    active: bool = false,
    finished: bool = false,
    last_history_total: i32 = 0,
    start_ticks: u64 = 0,
    queue_len: usize = 0,
    accepted_len: usize = 0,
    device_count: usize = 0,
    used_count: usize = 0,
    record_len: usize = 0,
    analog_blocked: bool = false,
    alternate_requested: bool = false,
    raw_ready: bool = false,
    raw_failed: bool = false,
    window_active: bool = true,
    raw_sequence: u32 = 0,
    raw_controller_count: usize = 0,
    raw_keyboard: [256]u8 = undefined,
    raw_keyboard_queue: RawQueue = .{},
    raw_controllers: [RAW_CONTROLLER_CAPACITY]RawController = undefined,
    raw_input: [RAW_INPUT_CAPACITY]u8 align(8) = undefined,
    preparsed_data: [PREPARSED_DATA_CAPACITY]u8 align(8) = undefined,
    queue: [MAX_EVENTS]InputEvent = undefined,
    accepted: [MAX_EVENTS]i32 = undefined,
    devices: [MAX_DEVICES]DeviceCache = undefined,
    used_devices: [MAX_DEVICES]u32 = undefined,
    record: [MAX_RECORD_BYTES]u8 = undefined,
};

const HookTable = struct {
    vtable: *DeviceVtable,
    acquire: AcquireFn,
    unacquire: AcquireFn,
    get_state: GetStateFn,
    get_data: GetDataFn,
    poll: AcquireFn,
};

// Just a process-wide hook state, yucky global instance!
var module: w.HINSTANCE = undefined;
var critical: w.RTL_CRITICAL_SECTION = undefined;
var patch_state: ?*PatchState = null;
var hook_tables: [4]HookTable = undefined;
var hook_table_count: usize = 0;
var game_window: ?w.HWND = null;
var previous_window_proc: ?w.WNDPROC = null;
var title_applied: bool = false;
var raw_setup_attempted: bool = false;

// The original patch shared these maps and queues without synchronization.
fn lockState() *PatchState {
    return patch_state.?;
}
fn unlockState() void {}

const GameError = error{
    NullGamePointer,
    InvalidGameRoot,
    WindowNotFound,
    UiChildNotFound,
    ActionNotFound,
};

fn readU32(address: Address) u32 {
    return address.ptr(*align(1) const u32).*;
}
fn readI32(address: Address) i32 {
    return @bitCast(readU32(address));
}
fn readAddress(address: Address) GameError!Address {
    const value = readU32(address);
    if (value == 0) return error.NullGamePointer;
    return Address.at(value);
}

// View a range of bytes in game-memory.
fn bytesAt(address: Address, length: usize) []const u8 {
    return address.ptr([*]const u8)[0..length];
}

fn bytesEqual(address: FixedAddress, expected: []const u8) bool {
    return std.mem.eql(u8, bytesAt(address.address(), expected.len), expected);
}

fn cString(pointer: ?[*]const u8, limit: usize) []const u8 {
    const value = pointer orelse return "";
    return std.mem.sliceTo(value[0..limit], 0);
}

fn readCString(field: Address, limit: usize) []const u8 {
    return cString(@ptrFromInt(readU32(field)), limit);
}

fn pushRawEvent(state: *PatchState, queue: *RawQueue, offset: DeviceOffset, data: u32) void {
    if (queue.length == queue.events.len) {
        queue.head = (queue.head + 1) % queue.events.len;
        queue.length -= 1;
    }
    const tail = (queue.head + queue.length) % queue.events.len;
    queue.events[tail] = .{
        .offset = offset,
        .data = data,
        .timestamp = state.raw_sequence,
        .sequence = state.raw_sequence,
        .app_data = std.math.maxInt(usize),
    };
    state.raw_sequence +%= 1;
    queue.length += 1;
}

fn readRawEvent(queue: *RawQueue, index: usize, remove: bool) DeviceObjectData {
    const event = queue.events[(queue.head + index) % queue.events.len];
    if (remove and index == 0) {
        queue.head = (queue.head + 1) % queue.events.len;
        queue.length -= 1;
        if (queue.length == 0) queue.head = 0;
    }
    return event;
}

// Find or create state for one raw HID controller.
fn findOrAddRawController(state: *PatchState, handle: ?w.HANDLE, product_id: ProductId) error{RawControllerCacheFull}!*RawController {
    for (state.raw_controllers[0..state.raw_controller_count]) |*controller| {
        if (controller.handle == handle) return controller;
    }
    if (state.raw_controller_count == state.raw_controllers.len) return error.RawControllerCacheFull;
    const controller = &state.raw_controllers[state.raw_controller_count];
    state.raw_controller_count += 1;
    controller.* = .{ .handle = handle, .product_id = product_id };
    controller.reset();
    return controller;
}

// Assign a stable raw controller to a DirectInput controller object.
fn rawControllerForDevice(state: *PatchState, cache: *DeviceCache) ?*RawController {
    if (cache.raw_handle != null) {
        for (state.raw_controllers[0..state.raw_controller_count]) |*controller| {
            if (controller.handle == cache.raw_handle) return controller;
        }
        cache.raw_handle = null;
    }
    for (state.raw_controllers[0..state.raw_controller_count]) |*controller| {
        if (cache.product_id != ProductId.unknown and
            controller.product_id != ProductId.unknown and
            cache.product_id != controller.product_id) continue;

        var assigned = false;
        for (state.devices[0..state.device_count]) |device| {
            if (device.pointer != cache.pointer and device.raw_handle == controller.handle) {
                assigned = true;
                break;
            }
        }
        if (!assigned) {
            cache.raw_handle = controller.handle;
            return controller;
        }
    }
    return null;
}

// Apply one Raw Input keyboard transition and suppress duplicates.
fn processRawKeyboard(state: *PatchState, body: []const u8) void {
    if (body.len < 16 or !state.window_active) return;

    const make_code = std.mem.readInt(u16, body[0..2], .little);
    const flags: input.Flags = @bitCast(std.mem.readInt(u16, body[2..4], .little));
    const virtual_key = std.mem.readInt(u16, body[6..8], .little);

    const offset = input.rawKeyOffset(make_code, flags, virtual_key) orelse return;

    const value: u8 = if (flags.@"break") 0 else 0x80;
    if (state.raw_keyboard[offset] == value) return;
    state.raw_keyboard[offset] = value;

    pushRawEvent(state, &state.raw_keyboard_queue, DeviceOffset.at(offset), value);
}

// Parse one HID report into a safe DirectInput-compatible controller state.
fn processHidReport(state: *PatchState, handle: ?w.HANDLE, product_id: ProductId, preparsed: isize, report: []const u8) error{RawControllerCacheFull}!void {
    var caps: HidpCaps = undefined;
    if (w.HidP_GetCaps(preparsed, @ptrCast(&caps)) != w.HIDP_STATUS_SUCCESS) return;
    const controller = try findOrAddRawController(state, handle, product_id);
    var next = controller.state;

    var button_caps: [32]HidpButtonCaps = undefined;
    var button_count: u16 = @min(caps.input_button_caps, button_caps.len);
    if (button_count != 0 and w.HidP_GetButtonCaps(.Input, @ptrCast(&button_caps), &button_count, preparsed) == w.HIDP_STATUS_SUCCESS) {
        var base: usize = 0;
        for (button_caps[0..button_count]) |cap| {
            const first = if (cap.is_range != 0) cap.usages.range.usage_min else cap.usages.single.usage;
            const last = if (cap.is_range != 0) cap.usages.range.usage_max else first;
            if (last < first) continue;
            const range_len = @min(@as(usize, last - first) + 1, 128 -| base);
            if (range_len == 0) continue;
            if (cap.report_id != 0 and (report.len == 0 or report[0] != cap.report_id)) {
                base += range_len;
                continue;
            }
            @memset(next[48 + base .. 48 + base + range_len], 0);
            var usages: [128]u16 = undefined;
            var usage_count: u32 = usages.len;
            if (w.HidP_GetUsages(.Input, cap.usage_page, cap.link_collection, @ptrCast(&usages), &usage_count, preparsed, @constCast(report.ptr), @intCast(report.len)) == w.HIDP_STATUS_SUCCESS) {
                for (usages[0..@min(usage_count, usages.len)]) |usage| {
                    if (usage >= first and usage <= last) next[48 + base + usage - first] = 0x80;
                }
            }
            base += range_len;
            if (base == 128) break;
        }
    }

    var value_caps: [32]HidpValueCaps = undefined;
    var value_count: u16 = @min(caps.input_value_caps, value_caps.len);
    if (value_count != 0 and w.HidP_GetValueCaps(.Input, @ptrCast(&value_caps), &value_count, preparsed) == w.HIDP_STATUS_SUCCESS) {
        for (value_caps[0..value_count]) |cap| {
            if (cap.usage_page != 1) continue;
            if (cap.report_id != 0 and (report.len == 0 or report[0] != cap.report_id)) continue;
            const first = if (cap.is_range != 0) cap.usages.range.usage_min else cap.usages.single.usage;
            const last = if (cap.is_range != 0) cap.usages.range.usage_max else first;
            if (last < first) continue;
            for (CONTROLLER_AXES) |axis| {
                const usage = @backingInt(axis.usage);
                if (usage < first or usage > last) continue;
                const offset = @backingInt(axis.offset);
                var value: i32 = 0;
                const status = if (cap.logical_min < 0)
                    w.HidP_GetScaledUsageValue(.Input, cap.usage_page, cap.link_collection, usage, &value, preparsed, @constCast(report.ptr), @intCast(report.len))
                else blk: {
                    var raw_value: u32 = 0;
                    const result = w.HidP_GetUsageValue(.Input, cap.usage_page, cap.link_collection, usage, &raw_value, preparsed, @constCast(report.ptr), @intCast(report.len));
                    value = @bitCast(raw_value);
                    break :blk result;
                };
                if (status != w.HIDP_STATUS_SUCCESS) continue;
                const normalized = if (axis.usage == .hat)
                    if (value <= 0) @as(u32, 0xffff_ffff) else @as(u32, @intCast(@min(value - 1, 7))) * 4500
                else if (cap.logical_min < 0)
                    input.normalizeAxis(value, cap.physical_min, cap.physical_max)
                else
                    input.normalizeAxis(value, cap.logical_min, cap.logical_max);
                std.mem.writeInt(u32, next[offset..][0..4], normalized, .little);
            }
        }
    }

    for (CONTROLLER_AXES) |axis| {
        const offset = @backingInt(axis.offset);
        const before = std.mem.readInt(u32, controller.state[offset..][0..4], .little);
        const after = std.mem.readInt(u32, next[offset..][0..4], .little);
        if (before != after) pushRawEvent(state, &controller.queue, axis.offset, after);
    }
    for (48..176) |offset| if (controller.state[offset] != next[offset]) pushRawEvent(
        state,
        &controller.queue,
        DeviceOffset.at(@intCast(offset)),
        next[offset],
    );
    controller.state = next;
}

// Read and dispatch one WM_INPUT packet, including every batched HID report.
fn processRawInput(in: w.HRAWINPUT) void {
    var required: u32 = 0;
    if (w.GetRawInputData(in, .INPUT, null, &required, 16) == std.math.maxInt(u32) or required < 16 or required > RAW_INPUT_CAPACITY) return;

    const state = lockState();
    defer unlockState();

    var received = required;
    if (w.GetRawInputData(in, .INPUT, &state.raw_input, &received, 16) != received or received < 16 or received > RAW_INPUT_CAPACITY) return;

    const packet = state.raw_input[0..received];
    const input_type: RawInputKind = @fromBackingInt(std.mem.readInt(u32, packet[0..4], .little));
    if (input_type == .keyboard) {
        processRawKeyboard(state, packet[16..]);
        return;
    }
    if (input_type != .hid or packet.len < 24) return;

    const raw_handle: ?w.HANDLE = @ptrFromInt(std.mem.readInt(u32, packet[8..12], .little));
    const report_size = std.mem.readInt(u32, packet[16..20], .little);
    const report_count = std.mem.readInt(u32, packet[20..24], .little);
    if (report_size == 0 or report_count == 0 or @as(u64, report_size) * report_count > packet.len - 24) return;

    var preparsed_size: u32 = PREPARSED_DATA_CAPACITY;
    if (w.GetRawInputDeviceInfoW(raw_handle, .PREPARSEDDATA, &state.preparsed_data, &preparsed_size) == std.math.maxInt(u32) or preparsed_size == 0 or preparsed_size > PREPARSED_DATA_CAPACITY) return;
    const preparsed: isize = @intCast(@intFromPtr(&state.preparsed_data));

    var info: RawDeviceInfo = .{ .size = @sizeOf(RawDeviceInfo), .kind = .mouse, .payload = @splat(0) };
    var info_size: u32 = @sizeOf(RawDeviceInfo);
    const product_id: ProductId = if (w.GetRawInputDeviceInfoW(raw_handle, w.RIDI_DEVICEINFO, &info, &info_size) != std.math.maxInt(u32) and info.kind == .hid)
        .{ .product = @intCast(info.payload[0]), .vendor = @intCast(info.payload[1]) }
    else
        .unknown;

    // The original ignored RAWHID.dwCount and consumed only report zero.
    processHidReport(state, raw_handle, product_id, preparsed, packet[24..][0..report_size]);
}

// Read the wall clock in 100-nanosecond FILETIME ticks.
fn fileTimeNow() u64 {
    var value: w.FILETIME = undefined;
    w.GetSystemTimeAsFileTime(&value);
    return @as(u64, value.dwLowDateTime) | (@as(u64, value.dwHighDateTime) << 32);
}

// Resolve the game's root object through its fixed global holder.
fn gameRoot() GameError!Address {
    const holder = try readAddress(FixedAddress.game_root_holder.address());
    if (@backingInt(holder) < 0x328) return error.InvalidGameRoot;
    return readAddress(holder.sub(0x328));
}

// Resolve the current race object through the game's own getter.
fn currentRace() GameError!Address {
    const root = try gameRoot();
    const manager = try readAddress(root.add(0x454));

    const get_race = FixedAddress.get_race.ptr(GetRaceFn);
    const result = get_race(manager.ptr(?*anyopaque)) orelse return error.NullGamePointer;
    return Address.fromPtr(result);
}

// Read the internal game string used by the replay key derivation.
fn gameString(root: Address) GameError![]const u8 {
    const object = try readAddress(root.add(0x198));
    const get = FixedAddress.game_string_cstr.ptr(GameStringFn);
    return cString(get(object.add(0xdc).ptr(?*anyopaque)), 4096);
}

// Read the current race name from the race object.
fn raceName(race: Address) []const u8 {
    return readCString(race.add(0x2c), 4096);
}

// Find the process's visible top-level game window.
fn enumGameWindow(window: w.HWND, parameter: isize) callconv(.winapi) w.BOOL {
    var process_id: u32 = 0;
    _ = w.GetWindowThreadProcessId(window, &process_id);
    if (process_id != w.GetCurrentProcessId() or w.IsWindowVisible(window) == w.FALSE) return w.TRUE;
    var title: [2]u16 = undefined;
    if (w.GetWindowTextW(window, @ptrCast(&title), title.len) == 0) return w.TRUE;
    const output: *?w.HWND = @ptrFromInt(@as(usize, @bitCast(parameter)));
    output.* = window;
    return w.FALSE;
}

fn windowFromGame() GameError!w.HWND {
    const root = try gameRoot();
    const owner = try readAddress(root.add(0x64));
    const display = try readAddress(owner.add(0x260));
    const handle = try readAddress(display.add(0x90));
    const window = handle.ptr(w.HWND);
    if (w.IsWindow(window) == w.FALSE) return error.WindowNotFound;
    return window;
}

// Resolve the HWND through the game objects, with process enumeration fallback.
fn resolveGameWindow() GameError!w.HWND {
    if (game_window) |window| {
        if (w.IsWindow(window) != w.FALSE) return window;
    }
    const window = windowFromGame() catch {
        var candidate: ?w.HWND = null;
        _ = w.EnumWindows(&enumGameWindow, @bitCast(@intFromPtr(&candidate)));
        game_window = candidate;
        return candidate orelse error.WindowNotFound;
    };
    game_window = window;
    return window;
}

// Append the suffix that the Competition Patch uses to the game window title.
fn applyWindowTitle(window: w.HWND) void {
    if (title_applied) return;
    var title: [256]u16 = undefined;
    const length_i = w.GetWindowTextW(window, @ptrCast(&title), title.len);
    if (length_i <= 0) return;
    const length: usize = @intCast(length_i);
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral(" (Competition Patch " ++ version ++ ")");
    if (std.mem.endsWith(u16, title[0..length], suffix)) {
        title_applied = true;
        return;
    }
    if (length + suffix.len >= title.len) return;
    @memcpy(title[length .. length + suffix.len], suffix);
    title[length + suffix.len] = 0;
    if (w.SetWindowTextW(window, @ptrCast(&title)) != w.FALSE) title_applied = true;
}

// Read a UI object's internal name.
fn uiObjectName(object: Address) []const u8 {
    const get = FixedAddress.game_string_cstr.ptr(GameStringFn);
    return cString(get(object.add(0x18).ptr(?*anyopaque)), 256);
}

// Find a named child in a game UI node.
fn findUiChild(parent: Address, name: []const u8) GameError!Address {
    const count_i = readI32(parent.add(0x144));
    if (count_i <= 0 or count_i > 4096) return error.UiChildNotFound;
    const children = try readAddress(parent.add(0x148));
    for (0..@intCast(count_i)) |index| {
        const child = readAddress(children.add(index * 4)) catch continue;
        if (std.mem.eql(u8, uiObjectName(child), name)) return child;
    }
    return error.UiChildNotFound;
}

// Append the suffix to the FrameMessage/LabelMessage UI label.
fn applyInGameLabel() GameError!void {
    const root = try gameRoot();
    if (readU32(root.add(0xc8)) == 0) return;

    const owner = try readAddress(root.add(0xcc));
    const object = try readAddress(owner);
    const frame = try readAddress(object.add(0x84));
    if (!std.mem.eql(u8, uiObjectName(frame), "FrameMessage")) return;
    const grid = try findUiChild(frame, "GridContent");
    const label = try findUiChild(grid, "LabelMessage");

    const length = readU32(label.add(0x130));
    const pointer = try readAddress(label.add(0x134));
    if (length > 490) return;
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral(" (Competition Patch)");
    const current = pointer.ptr([*]const u16)[0..length];
    if (std.mem.endsWith(u16, current, suffix)) return;

    var text: [512]u16 = undefined;
    @memcpy(text[0..length], current);
    @memcpy(text[length..][0..suffix.len], suffix);
    text[length + suffix.len] = 0;
    const value: GameText = .{ .length = @intCast(length + suffix.len), .pointer = &text };
    const set_label = FixedAddress.game_set_label.ptr(GameSetLabelFn);
    _ = set_label(label.ptr(?*anyopaque), &value);
}

// Clear raw state when the game window loses activation.
fn clearRawState(state: *PatchState) void {
    @memset(&state.raw_keyboard, 0);
    state.raw_keyboard_queue = .{};
    for (state.raw_controllers[0..state.raw_controller_count]) |*controller| controller.reset();
}

// Handle Raw Input and preserve the game's original WndProc chain.
fn rawWindowProc(window: w.HWND, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    if (message == w.WM_ACTIVATE and patch_state != null) {
        const state = lockState();
        state.window_active = (wparam & 0xffff) != 0;
        if (!state.window_active) clearRawState(state);
        unlockState();
    } else if (message == w.WM_INPUT and patch_state != null) {
        const state = lockState();
        const enabled = state.alternate_requested and state.raw_ready;
        unlockState();
        if (enabled) processRawInput(@ptrFromInt(@as(usize, @bitCast(lparam))));
    }
    if (previous_window_proc) |procedure| return w.CallWindowProcW(procedure, window, message, wparam, lparam);
    return w.DefWindowProcW(window, message, wparam, lparam);
}

fn installWindowProc(window: w.HWND) bool {
    if (previous_window_proc != null) return true;
    const replacement: i32 = @bitCast(@intFromPtr(&rawWindowProc));
    const previous = w.SetWindowLongW(window, .P_WNDPROC, replacement);
    if (previous == 0) return false;
    previous_window_proc = @ptrFromInt(@as(u32, @bitCast(previous)));
    return true;
}

// Register joystick, gamepad, and keyboard Raw Input usages.
fn registerRawInput(window: w.HWND) bool {
    var devices: [3]w.RAWINPUTDEVICE = .{
        .{ .usUsagePage = 1, .usUsage = 4, .dwFlags = .{}, .hwndTarget = window },
        .{ .usUsagePage = 1, .usUsage = 5, .dwFlags = .{}, .hwndTarget = window },
        .{ .usUsagePage = 1, .usUsage = 6, .dwFlags = .{}, .hwndTarget = window },
    };
    return w.RegisterRawInputDevices(&devices, devices.len, @sizeOf(w.RAWINPUTDEVICE)) != w.FALSE;
}

// The original registered Raw Input first and ignored subclass failure.
fn updateWindowFeatures() void {
    const window = resolveGameWindow() catch return;
    applyWindowTitle(window);
    if (raw_setup_attempted) return;

    const state = lockState();
    const should_register = state.alternate_requested and !state.raw_ready and !state.raw_failed;
    unlockState();
    if (!should_register) return;

    raw_setup_attempted = true;
    const registered = registerRawInput(window);
    const updated = lockState();
    if (registered) {
        updated.raw_ready = true;
        updated.window_active = true;
    } else {
        updated.raw_failed = true;
        updated.alternate_requested = false;
    }
    unlockState();
    if (!registered) {
        fatal(.raw_input_failed);
        return;
    }
    _ = installWindowProc(window);
}

// Resolve an action-history entry to its registered action name.
fn actionName(race: Address, action_value: HistoryAction) GameError![]const u8 {
    const index = action_value.index;
    const count_i = readI32(race.add(0x370));
    if (count_i <= 0 or index >= count_i) return error.ActionNotFound;

    const table = try readAddress(race.add(0x374));
    const action = try readAddress(table.add(@as(usize, index) * 4));

    const length = @min(readU32(action.add(4)), 128);
    const pointer = try readAddress(action.add(8));
    return bytesAt(pointer, length);
}

fn isDigitalAction(name: []const u8) bool {
    return std.mem.eql(u8, name, "Steer left") or
        std.mem.eql(u8, name, "Steer right") or
        std.mem.eql(u8, name, "Accelerate") or
        std.mem.eql(u8, name, "Brake") or
        std.mem.eql(u8, name, "Respawn");
}
fn isAnalogAction(name: []const u8) bool {
    return std.mem.eql(u8, name, "Steer (analog)") or
        std.mem.eql(u8, name, "Accelerate (analog)");
}

// Find a cached DirectInput device by COM object address.
fn findDevice(state: *PatchState, pointer: *anyopaque) ?*DeviceCache {
    for (state.devices[0..state.device_count]) |*device| {
        if (device.pointer == pointer) return device;
    }
    return null;
}

// Return a cached device slot, creating it on first use.
fn findOrAddDevice(state: *PatchState, pointer: *anyopaque, class: DeviceClass) error{DeviceCacheFull}!*DeviceCache {
    if (findDevice(state, pointer)) |device| {
        if (device.class == .other and class != .other) device.class = class;
        return device;
    }
    if (state.device_count >= MAX_DEVICES) return error.DeviceCacheFull;
    const device = &state.devices[state.device_count];
    state.device_count += 1;
    device.* = .{ .pointer = pointer, .class = class };
    return device;
}

// Record each device identifier once, in first-event order.
fn addUsedDevice(state: *PatchState, pointer: *anyopaque) void {
    const value: u32 = @truncate(@intFromPtr(pointer));
    for (state.used_devices[0..state.used_count]) |known| if (known == value) return;
    if (state.used_count < MAX_DEVICES) {
        state.used_devices[state.used_count] = value;
        state.used_count += 1;
    }
}

// Append a timestamped event, dropping it when the recorder queue is full.
fn appendQueued(state: *PatchState, stamp: i32, kind: InputKind) void {
    if (state.queue_len >= MAX_EVENTS) return;
    state.queue[state.queue_len] = .{ .stamp = stamp, .kind = kind };
    state.queue_len += 1;
}

// Queue a raw input transition with the current in-game race time.
fn enqueue(state: *PatchState, kind: InputKind) GameError!void {
    if (!state.active or state.finished or state.queue_len >= MAX_EVENTS) return;
    const race = try currentRace();
    if (readI32(race.add(0x33c)) != 0) return;
    const stamp = readI32(race.add(0x2b0));
    appendQueued(state, stamp, kind);
}

// Reset the recorder and synthesize events for inputs held at race start.
fn startRace(state: *PatchState) void {
    state.active = true;
    state.finished = false;
    state.last_history_total = 0;
    state.queue_len = 0;
    state.accepted_len = 0;
    state.used_count = 0;
    state.record_len = 0;

    var order: [MAX_DEVICES]usize = undefined;
    for (0..state.device_count) |index| order[index] = index;
    // The original device map is traversed in pointer-key order.
    for (1..state.device_count) |index| {
        const value = order[index];
        var scan = index;
        while (scan > 0 and @intFromPtr(state.devices[order[scan - 1]].pointer) > @intFromPtr(state.devices[value].pointer)) : (scan -= 1) {
            order[scan] = order[scan - 1];
        }
        order[scan] = value;
    }
    for (order[0..state.device_count]) |index| {
        const device = &state.devices[index];
        switch (device.class) {
            .keyboard => for (device.state[0..@min(device.state_len, 256)]) |value| {
                if (value & 0x80 != 0) appendQueued(state, 0, .key_down);
            },
            .controller => {
                for (CONTROLLER_AXES) |axis| {
                    const at = @backingInt(axis.offset);
                    if (at + 4 <= device.state_len and std.mem.readInt(u32, device.state[at..][0..4], .little) != 0) {
                        appendQueued(state, 0, .axis);
                    }
                }
                if (device.state_len > 48) {
                    for (device.state[48..@min(device.state_len, 176)]) |value| {
                        if (value & 0x80 != 0) appendQueued(state, 0, .button_down);
                    }
                }
            },
            .other => {},
        }
    }
    // We start the wall-clock timer *after* collecting the held-input
    // snapshots.
    state.start_ticks = fileTimeNow();
}

// Remove one pending input transition, preserving the order of the rest.
fn removeQueued(state: *PatchState, position: usize) void {
    if (position + 1 < state.queue_len) @memmove(
        state.queue[position .. state.queue_len - 1],
        state.queue[position + 1 .. state.queue_len],
    );
    state.queue_len -= 1;
}

// Match queued input transitions against newly observed game actions.
fn processHistory(state: *PatchState, race: Address) void {
    const total = @max(readI32(race.add(0x350)), 0);
    const delta = if (state.last_history_total <= total) total - state.last_history_total else total;
    const data = readAddress(race.add(0x354)) catch null;
    const start = readI32(race.add(0x35c));
    if (data) |history_data| {
        var i: i32 = 0;
        while (i < delta) : (i += 1) {
            const history_index = std.math.cast(usize, start + delta - 1 - i) orelse continue;
            const action: HistoryAction = @bitCast(readU32(history_data.add(history_index * 8 + 4)));

            const name = actionName(race, action) catch continue;
            const digital = isDigitalAction(name);
            const analog = isAnalogAction(name);
            if (!digital and !analog) continue;

            const pressed = action.value != 0;
            for (state.queue[0..state.queue_len], 0..) |event, index| {
                const matches = if (analog)
                    event.kind == .axis
                else if (pressed)
                    event.kind == .key_down or event.kind == .button_down
                else
                    event.kind == .key_up or event.kind == .button_up;
                if (!matches) continue;

                removeQueued(state, index);
                const kind: i32 = @backingInt(event.kind);
                const encoded = if (event.stamp < 0) event.stamp -% kind else event.stamp +% kind;
                if (state.accepted_len < MAX_EVENTS) {
                    state.accepted[state.accepted_len] = encoded;
                    state.accepted_len += 1;
                }
                break;
            }
        }
    }
    state.last_history_total = total;
}

fn environmentFlags(negative_elapsed: bool, alternate: bool) EnvironmentFlags {
    const ntdll = w.GetModuleHandleA("ntdll.dll");
    return .{
        .wine = ntdll != null and w.GetProcAddress(ntdll, "wine_get_version") != null,
        .negative_elapsed = negative_elapsed,
        .alternate = alternate,
        .debugger = w.IsDebuggerPresent() != w.FALSE,
    };
}

// Derive the key and build the encrypted record when the race finishes.
fn finalizeRecord(state: *PatchState, race: Address) (GameError || protocol.BuildError)!void {
    var elapsed: i64 = @divTrunc(@as(i64, @bitCast(fileTimeNow() -% state.start_ticks)), 10_000);
    if (w.GetModuleHandleA("speedhack-i386.dll") != null) elapsed = 0 -% elapsed;

    const root = try gameRoot();
    const game_id = try gameString(root);
    if (game_id.len == 0) return;

    var key = protocol.initialKey(game_id);
    {
        const count_i = @max(readI32(race.add(0x350)), 0);
        const data = readAddress(race.add(0x354)) catch null;
        const start = readI32(race.add(0x35c));
        if (data) |history_data| {
            if (start >= 0) for (0..@intCast(count_i)) |index| {
                const offset = (@as(usize, @intCast(start)) + index) * 8;
                const history = readU32(history_data.add(offset));
                protocol.mixHistoryEntry(&key, history, index);
            };
        }
    }

    var iv: [16]u8 = undefined;
    _ = w.SystemFunction036(@ptrCast(&iv), iv.len);
    var local_time: w.SYSTEMTIME = undefined;
    w.GetLocalTime(&local_time);

    const elapsed_low: u32 = @truncate(@as(u64, @bitCast(elapsed)));
    const record = try protocol.buildEncryptedRecord(&state.record, .{
        .iv = iv,
        .elapsed_low = elapsed_low,
        .flags = @bitCast(environmentFlags(elapsed < 0, state.alternate_requested)),
        .packed_date = protocol.packDate(local_time.wYear, local_time.wMonth, local_time.wDay),
        .device_ids = state.used_devices[0..state.used_count],
        .encoded_events = state.accepted[0..state.accepted_len],
        .key = key,
    });
    state.record_len = record.len;
    state.finished = true;

    {
        const validation_marker = "TmForeverCompPatch.2.11.26(1.6)";
        const manager = try readAddress(root.add(0x454));
        const collection = try readAddress(manager.add(0xb0));
        const count_i = readI32(collection.add(0x18));
        if (count_i <= 0 or count_i > 4096) return;
        const entries = try readAddress(collection.add(0x1c));

        const marker: GameStringText = .{
            .pointer = validation_marker.ptr,
            .length = validation_marker.len,
        };
        const assign = FixedAddress.game_string_assign.ptr(GameStringAssignFn);
        for (0..@intCast(count_i)) |index| {
            const entry = readAddress(entries.add(index * 4)) catch continue;
            assign(entry.add(0x154).ptr(?*anyopaque), &marker);
        }
    }
}

// Advance the race recorder from the game's per-frame hook.
fn tmcpOnFrame(state_marker: usize) callconv(.c) void {
    if (state_marker != 0x11) return;

    updateWindowFeatures();
    applyInGameLabel() catch {};

    const race = currentRace() catch return;
    const race_time = readI32(race.add(0x2b0));
    const complete = readI32(race.add(0x33c)) != 0;

    const state = lockState();
    defer unlockState();
    // The start callback runs whenever race time is exactly zero.
    if (race_time == 0) startRace(state);
    if (state.active and race_time > 9) processHistory(state, race);
    if (state.active and complete and !state.finished) finalizeRecord(state, race) catch {};
}

// Read the race name carried by a replay serialization object.
fn serializationName(object: Address) []const u8 {
    // This serialization object stores a direct char* at +0xDC. It is not the
    // encoded game-ID field used by gameString(), despite sharing the same
    // offset.
    return readCString(object.add(0xdc), 4096);
}

fn writeValue(writer: GameWriterFn, context: ?*anyopaque, value: u32) void {
    var local = value;
    _ = writer(context, @ptrCast(&local), 4);
}

// Append the custom competition chunk to the matching completed replay.
fn tmcpOnSerialize(object_address: usize, context_address: usize) callconv(.c) void {
    serializeReplay(Address.at(object_address), Address.at(context_address)) catch {};
}

fn serializeReplay(object: Address, writer_context: Address) GameError!void {
    if (object == .none or writer_context == .none) return;

    const vtable = try readAddress(object);
    if (vtable != FixedAddress.serialization_vtable_a.address() and
        vtable != FixedAddress.serialization_vtable_b.address()) return;

    const name = serializationName(object);
    const root = try gameRoot();
    const string = try gameString(root);
    if (string.len == 0) return;

    const live_race = try currentRace();
    const live_name = raceName(live_race);
    if (!std.mem.eql(u8, name, live_name)) return;

    const state = lockState();
    defer unlockState();
    if (state.record_len == 0) return;

    const writer = FixedAddress.game_writer.ptr(GameWriterFn);
    const context = writer_context.ptr(?*anyopaque);
    writeValue(writer, context, protocol.chunk_id);
    writeValue(writer, context, protocol.skip_marker);
    writeValue(writer, context, @as(u32, @intCast(state.record_len)) + 8);
    writeValue(writer, context, protocol.original_code_hash);
    writeValue(writer, context, @intCast(state.record_len));
    _ = writer(context, &state.record, @intCast(state.record_len));
}

// Replay the overwritten frame instructions and call the recorder.
fn frameDetour() callconv(.naked) void {
    asm volatile (
        \\ addl %%eax, %%ecx
        \\ movl %%ecx, -8(%%esi)
        \\ pushal
        \\ pushl %%ebp
        \\ calll %[callback:P]
        \\ addl $4, %%esp
        \\ popal
        \\ pushl %[continuation]
        \\ retl
        :
        : [callback] "X" (&tmcpOnFrame),
          [continuation] "i" (comptime @backingInt(FixedAddress.frame_site.add(5))),
        : .{ .memory = true });
}

// Call the chunk writer, then replay the overwritten serializer instructions.
fn serializationDetour() callconv(.naked) void {
    asm volatile (
        \\ pushal
        \\ pushl %%ecx
        \\ pushl %%edi
        \\ calll %[callback:P]
        \\ addl $8, %%esp
        \\ popal
        \\ movl (%%edi), %%eax
        \\ movl 0x44(%%eax), %%edx
        \\ pushl %[continuation]
        \\ retl
        :
        : [callback] "X" (&tmcpOnSerialize),
          [continuation] "i" (comptime @backingInt(FixedAddress.serialize_site.add(5))),
        : .{ .memory = true });
}

// Reads the launcher's Alternate Method choice from the game input setup.
fn tmcpOnInputSetup(config_addr: usize) callconv(.c) void {
    const configuration = Address.at(config_addr);
    if (configuration == .none) return;
    const alternate = readU32(configuration.add(0x174)) != 0;
    const state = lockState();
    defer unlockState();
    state.alternate_requested = alternate and !state.raw_failed;
}

// Capture the input configuration while replaying the overwritten setup code.
fn inputSetupDetour() callconv(.naked) void {
    asm volatile (
        \\ movl 0x0c(%%esp), %%eax
        \\ pushal
        \\ pushl %%eax
        \\ calll %[callback:P]
        \\ addl $4, %%esp
        \\ popal
        \\ pushl %%esi
        \\ pushl %[continuation]
        \\ retl
        :
        : [callback] "X" (&tmcpOnInputSetup),
          [continuation] "i" (comptime @backingInt(FixedAddress.input_setup_site.add(5))),
        : .{ .memory = true });
}

fn tmcpUpdateAnalogGate() callconv(.c) void {
    const holder = readAddress(FixedAddress.game_root_holder.address()) catch return;
    if (readU32(holder.add(0x0c)) != 0x14) return;
    const state = lockState();
    defer unlockState();
    state.analog_blocked = true;
}

fn analogGateSetDetour() callconv(.naked) void {
    asm volatile (
        \\ pushal
        \\ calll %[callback:P]
        \\ popal
        \\ flds 0x14(%%esp)
        \\ pushl %%ecx
        \\ pushl %[continuation]
        \\ retl
        :
        : [callback] "X" (&tmcpUpdateAnalogGate),
          [continuation] "i" (comptime @backingInt(FixedAddress.analog_gate_set_site.add(5))),
        : .{ .memory = true });
}

fn tmcpClearAnalogGate() callconv(.c) void {
    const state = lockState();
    state.analog_blocked = false;
    unlockState();
}

fn analogGateClearDetour() callconv(.naked) void {
    asm volatile (
        \\ pushal
        \\ calll %[callback:P]
        \\ popal
        \\ movl %%edx, (%%eax)
        \\ movl (%%ebx), %%eax
        \\ movl 0x24(%%eax), %%ecx
        \\ pushl %[continuation]
        \\ retl
        :
        : [callback] "X" (&tmcpClearAnalogGate),
          [continuation] "i" (comptime @backingInt(FixedAddress.analog_gate_clear_site.add(7))),
        : .{ .memory = true });
}

// Apply the unbiased -20..+20 adjustment.
fn tmcpAdjustAnalog(destination: usize, value: *align(1) u32) callconv(.c) void {
    if (FixedAddress.at(destination) != .analog_destination) return;
    {
        const state = lockState();
        defer unlockState();
        if (state.analog_blocked) return;
    }
    const original = value.*;
    if (!input.isAdjustableSigned24(original)) return;

    // Doing rejection sampling, but pretty poorly, idrk.
    // https://github.com/Rexicon226/lean4-weighted-shuffle/blob/0b467f5f9b9871eb33004d862ec99072954cf363/chacha.zig#L181-L241
    // Why checking above threshold?? Why doing mod on the random anyways after??
    const range: u32 = 41;
    const threshold = (0 -% range) % range;
    var random: u32 = 0;
    while (true) {
        if (w.SystemFunction036(@ptrCast(&random), @sizeOf(u32)) == 0) return;
        if (random >= threshold) break;
    }
    const adjustment = @as(i32, @intCast(random % range)) - 20;
    value.* = input.adjustSigned24(original, adjustment);
}

fn analogDetour() callconv(.naked) void {
    asm volatile (
        \\ leal 0x0c(%%esp), %%eax
        \\ pushal
        \\ pushl %%eax
        \\ pushl %%ecx
        \\ calll %[callback:P]
        \\ addl $8, %%esp
        \\ popal
        \\ leal 0x0c(%%esp), %%eax
        \\ pushl %%eax
        \\ pushl %[continuation]
        \\ retl
        :
        : [callback] "X" (&tmcpAdjustAnalog),
          [continuation] "i" (comptime @backingInt(FixedAddress.analog_site.add(5))),
        : .{ .memory = true });
}

fn windowDetour() callconv(.naked) void {
    asm volatile (
        \\ pushal
        \\ calll %[callback:P]
        \\ popal
        \\ movl 0xa4(%%ecx), %%edx
        \\ pushl %[continuation]
        \\ retl
        :
        : [callback] "X" (&updateWindowFeatures),
          [continuation] "i" (comptime @backingInt(FixedAddress.window_site.add(6))),
        : .{ .memory = true });
}

fn hookTableFor(device: ?*anyopaque) error{HookTableNotFound}!*const HookTable {
    const object = device orelse return error.HookTableNotFound;
    const vtable: *const *DeviceVtable = @ptrCast(@alignCast(object));
    w.EnterCriticalSection(&critical);
    defer w.LeaveCriticalSection(&critical);
    for (hook_tables[0..hook_table_count]) |*table| {
        if (table.vtable == vtable.*) return table;
    }
    return error.HookTableNotFound;
}

// Classify and cache a DirectInput device from DIDEVICEINSTANCE.
fn classifyDevice(device: ?*anyopaque) DeviceClass {
    const pointer = device orelse return .other;
    {
        const state = lockState();
        defer unlockState();
        if (findDevice(state, pointer)) |cache| {
            if (cache.class != .other) return cache.class;
        }
    }
    const vtable: *const *const DeviceVtable = @ptrCast(@alignCast(pointer));
    const get_info = vtable.*.get_info;

    var wide: DeviceInstance(u16) = undefined;
    @memset(std.mem.asBytes(&wide), 0);
    wide.size = @sizeOf(@TypeOf(wide));

    var device_type: u32 = 0;
    var product_id: ProductId = .unknown;
    if (!get_info(device, @ptrCast(&wide)).failed) {
        device_type = wide.device_type;
        product_id = @fromBackingInt(wide.guid_product.Ints.a);
    } else {
        // Didn't work, try more standard?
        var ansi: DeviceInstance(u8) = undefined;
        @memset(std.mem.asBytes(&ansi), 0);
        ansi.size = @sizeOf(@TypeOf(ansi));
        if (!get_info(device, @ptrCast(&ansi)).failed) {
            device_type = ansi.device_type;
            product_id = @fromBackingInt(ansi.guid_product.Ints.a);
        }
    }

    const class: DeviceClass = switch (device_type & 0xff) {
        0x13 => .keyboard,
        0x14, 0x15, 0x16, 0x18 => .controller,
        else => .other,
    };
    const state = lockState();
    defer unlockState();
    const cache = findOrAddDevice(state, pointer, class) catch return class;
    cache.product_id = product_id;
    return class;
}

// Cache the latest keyboard or controller state snapshot.
fn processDeviceState(device: ?*anyopaque, bytes: []const u8) error{DeviceCacheFull}!void {
    const class = classifyDevice(device);
    if (class == .other) return;

    const state = lockState();
    defer unlockState();

    const cache = try findOrAddDevice(state, device.?, class);
    const length = @min(bytes.len, cache.state.len);
    @memcpy(cache.state[0..length], bytes[0..length]);
    cache.state_len = length;
}

// Cache and queue one buffered DirectInput event.
fn processDeviceDatum(device: ?*anyopaque, event: *const DeviceObjectData) (GameError || error{DeviceCacheFull})!void {
    const class = classifyDevice(device);
    if (class == .other) return;

    const pointer = device.?;
    const state = lockState();
    defer unlockState();

    const cache = try findOrAddDevice(state, pointer, class);
    if (state.active) addUsedDevice(state, pointer);
    const at = @backingInt(event.offset);
    const is_button = event.offset.isButton();
    const kind: InputKind = switch (class) {
        .keyboard => if (event.data != 0) .key_down else .key_up,
        .controller => if (!is_button) .axis else if (event.data != 0) .button_down else .button_up,
        .other => return,
    };
    switch (class) {
        .keyboard => if (at < 256) {
            cache.ensureStateLength(256);
            cache.state[at] = @truncate(event.data);
        },
        .controller => if (at < 272) {
            cache.ensureStateLength(272);
            if (is_button) {
                cache.state[at] = @truncate(event.data);
            } else if (at + 4 <= cache.state.len) {
                std.mem.writeInt(u32, cache.state[at..][0..4], event.data, .little);
            }
        },
        .other => {},
    }
    try enqueue(state, kind);
}

// Handle Acquire through the Raw Input backend when Alternate Method is active.
fn alternateAcquire(device: ?*anyopaque, acquired: bool) bool {
    const object = device orelse return false;
    const class = classifyDevice(device);
    if (class == .other) return false;

    const state = lockState();
    defer unlockState();

    if (!state.alternate_requested) return false;
    const cache = findOrAddDevice(state, object, class) catch return true;
    cache.acquired = acquired;
    if (!acquired) {
        switch (class) {
            .keyboard => {
                @memset(&state.raw_keyboard, 0);
                state.raw_keyboard_queue = .{};
            },
            .controller => if (rawControllerForDevice(state, cache)) |c| c.reset(),
            .other => {},
        }
        cache.raw_handle = null;
        @memset(&cache.state, 0);
        cache.state_len = 0;
    }
    return true;
}

// Fill GetDeviceState from the safe Raw Input caches.
fn alternateGetState(device: ?*anyopaque, length: u32, data: ?*anyopaque) ?w.HRESULT {
    const object = device orelse return null;
    const class = classifyDevice(device);
    if (class == .other) return null;

    const state = lockState();
    defer unlockState();

    if (!state.alternate_requested) return null;
    const cache = findOrAddDevice(state, object, class) catch return w.E_INVALIDARG;
    if (!state.raw_ready or !state.window_active or !cache.acquired) return w.DIERR_NOTACQUIRED;

    const output = data orelse return w.E_INVALIDARG;
    const bytes = @as([*]u8, @ptrCast(output))[0..length];
    @memset(bytes, 0);
    const source: []const u8 = switch (class) {
        .keyboard => &state.raw_keyboard,
        .controller => if (rawControllerForDevice(state, cache)) |c| &c.state else return w.HRESULT.S_OK,
        .other => unreachable,
    };
    const copied = @min(bytes.len, source.len);
    @memcpy(bytes[0..copied], source[0..copied]);
    return w.HRESULT.S_OK;
}

// Fill GetDeviceData from the bounded Raw Input event queues.
fn alternateGetData(device: ?*anyopaque, object_size: u32, data: ?*DeviceObjectData, count: ?*u32, flags: DeviceDataFlags) ?w.HRESULT {
    const object = device orelse return null;
    const class = classifyDevice(device);
    if (class == .other) return null;

    const state = lockState();
    defer unlockState();

    if (!state.alternate_requested) return null;
    const amount_ptr = count orelse return w.E_INVALIDARG;
    const cache = findOrAddDevice(state, object, class) catch return w.E_INVALIDARG;
    if (!state.raw_ready or !state.window_active or !cache.acquired) {
        amount_ptr.* = 0;
        return w.DIERR_NOTACQUIRED;
    }
    const queue: ?*RawQueue = switch (class) {
        .keyboard => &state.raw_keyboard_queue,
        .controller => if (rawControllerForDevice(state, cache)) |controller| &controller.queue else null,
        .other => null,
    };
    const selected = queue orelse {
        amount_ptr.* = 0;
        return w.HRESULT.S_OK;
    };
    if (data == null) {
        amount_ptr.* = selected.length;
        return w.HRESULT.S_OK;
    }
    if (object_size < 16 or object_size > 256) {
        amount_ptr.* = 0;
        return w.E_INVALIDARG;
    }
    const amount = @min(amount_ptr.*, selected.length);
    const remove = !flags.peek;
    const base = Address.fromPtr(data.?);
    for (0..amount) |event_index| {
        const event = readRawEvent(selected, if (remove) 0 else event_index, remove);
        const destination = base.add(event_index * object_size).ptr([*]u8);
        const source = std.mem.asBytes(&event);
        const copied = @min(object_size, source.len);
        @memcpy(destination[0..copied], source[0..copied]);
    }
    amount_ptr.* = amount;
    return w.HRESULT.S_OK;
}

// Forward IDirectInputDevice8::Acquire.
fn hookedAcquire(device: ?*anyopaque) callconv(.winapi) w.HRESULT {
    if (alternateAcquire(device, true)) return w.HRESULT.S_OK;
    const table = hookTableFor(device) catch return w.HRESULT.fromInt(0xffff_ffff);
    return table.acquire(device);
}

// Forward Unacquire and clear the cached device state on success.
fn hookedUnacquire(device: ?*anyopaque) callconv(.winapi) w.HRESULT {
    if (alternateAcquire(device, false)) return w.HRESULT.S_OK;
    const table = hookTableFor(device) catch return w.HRESULT.fromInt(0xffff_ffff);
    const result = table.unacquire(device);
    if (!result.failed) {
        const state = lockState();
        defer unlockState();
        if (findDevice(state, device.?)) |cache| @memset(&cache.state, 0);
    }
    return result;
}

// Forward IDirectInputDevice8::Poll.
fn hookedPoll(device: ?*anyopaque) callconv(.winapi) w.HRESULT {
    const class = classifyDevice(device);
    if (class != .other) {
        const state = lockState();
        defer unlockState();
        if (state.alternate_requested) return w.HRESULT.S_OK;
    }
    const table = hookTableFor(device) catch return w.HRESULT.fromInt(0xffff_ffff);
    return table.poll(device);
}

// Forward GetDeviceState and cache successful results.
fn hookedGetState(device: ?*anyopaque, length: u32, data: ?*anyopaque) callconv(.winapi) w.HRESULT {
    const result = alternateGetState(device, length, data) orelse blk: {
        const table = hookTableFor(device) catch return w.HRESULT.fromInt(0xffff_ffff);
        break :blk table.get_state(device, length, data);
    };
    if (!result.failed and data != null and length != 0) {
        const capture = @min(length, 272);
        processDeviceState(device, @as([*]const u8, @ptrCast(data.?))[0..capture]) catch {};
    }
    return result;
}

// Forward GetDeviceData and record each returned event.
fn hookedGetData(device: ?*anyopaque, object_size: u32, data: ?*DeviceObjectData, count: ?*u32, flags: u32) callconv(.winapi) w.HRESULT {
    const result = alternateGetData(device, object_size, data, count, @bitCast(flags)) orelse blk: {
        const table = hookTableFor(device) catch return w.HRESULT.fromInt(0xffff_ffff);
        break :blk table.get_data(device, object_size, data, count, flags);
    };
    if (!result.failed and data != null and count != null and object_size >= @sizeOf(DeviceObjectData)) {
        const base = Address.fromPtr(data.?);
        for (0..count.?.*) |index| {
            const event = base.add(index * object_size).ptr(*const DeviceObjectData);
            processDeviceDatum(device, event) catch {};
        }
    }
    return result;
}

/// Install our hooks!
fn patchDirectInputVtable(vtable: *DeviceVtable) bool {
    w.EnterCriticalSection(&critical);
    defer w.LeaveCriticalSection(&critical);
    for (hook_tables[0..hook_table_count]) |table| if (table.vtable == vtable) return true;
    if (hook_table_count >= hook_tables.len) return false;

    const table: HookTable = .{
        .vtable = vtable,
        .acquire = vtable.acquire,
        .unacquire = vtable.unacquire,
        .get_state = vtable.get_state,
        .get_data = vtable.get_data,
        .poll = vtable.poll,
    };
    var old: w.PAGE_PROTECTION_FLAGS = undefined;
    if (w.VirtualProtect(@ptrCast(&vtable.acquire), DEVICE_HOOK_BYTES, .{ .PAGE_EXECUTE_READWRITE = 1 }, &old) == w.FALSE) return false;
    hook_tables[hook_table_count] = table;
    hook_table_count += 1;
    vtable.acquire = &hookedAcquire;
    vtable.unacquire = &hookedUnacquire;
    vtable.get_state = &hookedGetState;
    vtable.get_data = &hookedGetData;
    vtable.poll = &hookedPoll;
    finishCodeWrite(Address.fromPtr(&vtable.acquire), DEVICE_HOOK_BYTES, old);
    return true;
}

fn restoreDirectInputHooks() void {
    w.EnterCriticalSection(&critical);
    defer w.LeaveCriticalSection(&critical);
    while (hook_table_count > 0) {
        const index = hook_table_count - 1;
        const table = hook_tables[index];
        const vtable = table.vtable;

        var old: w.PAGE_PROTECTION_FLAGS = undefined;
        if (w.VirtualProtect(@ptrCast(&vtable.acquire), DEVICE_HOOK_BYTES, .{ .PAGE_EXECUTE_READWRITE = 1 }, &old) == w.FALSE) return;
        if (vtable.acquire == &hookedAcquire) vtable.acquire = table.acquire;
        if (vtable.unacquire == &hookedUnacquire) vtable.unacquire = table.unacquire;
        if (vtable.get_state == &hookedGetState) vtable.get_state = table.get_state;
        if (vtable.get_data == &hookedGetData) vtable.get_data = table.get_data;
        if (vtable.poll == &hookedPoll) vtable.poll = table.poll;

        finishCodeWrite(Address.fromPtr(&vtable.acquire), DEVICE_HOOK_BYTES, old);
        hook_table_count = index;
    }
}

// Create the system keyboard and patch its shared device vtable.
fn hookDirectInputInterface(create: DirectInput8CreateFn, iid: *const w.Guid) bool {
    var direct_input: ?*anyopaque = null;
    if (create(module, 0x800, iid, &direct_input, null).failed or direct_input == null) return false;

    const di_vtable: *const *const DirectInputVtable = @ptrCast(@alignCast(direct_input.?));
    const create_device = di_vtable.*.create_device;
    const release_di = di_vtable.*.release;
    defer _ = release_di(direct_input);

    var keyboard: ?*anyopaque = null;
    if (create_device(direct_input, &w.GUID_SysKeyboard, &keyboard, null).failed or keyboard == null) return false;

    const vtable: *const *DeviceVtable = @ptrCast(@alignCast(keyboard.?));
    const release_keyboard = vtable.*.release;
    defer _ = release_keyboard(keyboard);
    return patchDirectInputVtable(vtable.*);
}

// Load the real dinput8.dll and install ANSI/Unicode hooks.
fn installDirectInputHooks() bool {
    var path: [520]u16 = undefined;
    const length = w.GetSystemDirectoryW(@ptrCast(&path), 500);
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\dinput8.dll");

    if (length == 0 or length + suffix.len + 1 > path.len) return false;
    @memcpy(path[length .. length + suffix.len], suffix);
    path[length + suffix.len] = 0;

    const library = w.LoadLibraryW(@ptrCast(&path));
    if (library == null) return false;
    const entry = w.GetProcAddress(library, "DirectInput8Create") orelse return false;
    const create: DirectInput8CreateFn = @ptrCast(@alignCast(entry));
    return hookDirectInputInterface(create, w.IID_IDirectInput8W) and hookDirectInputInterface(create, w.IID_IDirectInput8A);
}

// Restore protection after a code write, then flush even if restoration fails.
fn finishCodeWrite(site: Address, length: usize, protection: w.PAGE_PROTECTION_FLAGS) void {
    var ignored: w.PAGE_PROTECTION_FLAGS = undefined;
    _ = w.VirtualProtect(site.ptr(?*anyopaque), length, protection, &ignored);
    _ = w.FlushInstructionCache(w.GetCurrentProcess(), site.ptr(?*const anyopaque), length);
}

// Not a single ifence found anywhere!!

fn installJump(site: FixedAddress, expected: []const u8, target: DetourFn) bool {
    if (expected.len < 5 or !bytesEqual(site, expected)) return false;

    var old: w.PAGE_PROTECTION_FLAGS = undefined;
    _ = w.VirtualProtect(site.ptr(?*anyopaque), expected.len, .{ .PAGE_EXECUTE_READWRITE = 1 }, &old);

    const relative: u32 = @truncate(@intFromPtr(target) -% @backingInt(site.add(5)));
    const destination = site.ptr([*]u8)[0..expected.len];
    destination[0] = 0xe9;
    std.mem.writeInt(u32, destination[1..5], relative, .little);
    if (destination.len > 5) @memset(destination[5..], 0x90);

    var ignored: w.PAGE_PROTECTION_FLAGS = undefined;
    _ = w.VirtualProtect(site.ptr(?*anyopaque), expected.len, old, &ignored);
    return true;
}

fn installNops(site: FixedAddress, expected: []const u8) bool {
    if (expected.len == 0 or !bytesEqual(site, expected)) return false;

    var old: w.PAGE_PROTECTION_FLAGS = undefined;
    _ = w.VirtualProtect(site.ptr(?*anyopaque), expected.len, .{ .PAGE_EXECUTE_READWRITE = 1 }, &old);
    @memset(site.ptr([*]u8)[0..expected.len], 0x90);

    var ignored: w.PAGE_PROTECTION_FLAGS = undefined;
    _ = w.VirtualProtect(site.ptr(?*anyopaque), expected.len, old, &ignored);
    return true;
}

fn existingPatchMarker() bool {
    const marker = [_]u8{ 0x31, 0xd2, 0x90 };
    return bytesEqual(.patch_marker_a, &marker) or bytesEqual(.patch_marker_b, &marker);
}

// Validate a bunch of stuff to make sure we're looking in the right places.
fn validateGameImage() bool {
    const base = FixedAddress.at(@intFromPtr(w.GetModuleHandleW(null) orelse return false));
    if (base != .image_base or !bytesEqual(base, "MZ")) return false;

    const pe_offset = @as(usize, readU32(base.add(0x3c).address()));
    if (pe_offset < 0x40 or pe_offset >= 0x1000 or
        !bytesEqual(base.add(pe_offset), "PE\x00\x00") or
        readU32(base.add(pe_offset + 8).address()) != 0x4b9e_8add or
        readU32(base.add(pe_offset + 24 + 56).address()) != 0x00a2_b000) return false;

    if (!bytesEqual(.get_race, &.{ 0x8b, 0x81, 0x30, 0x03, 0x00, 0x00, 0x85, 0xc0 }) or
        !bytesEqual(.game_string_cstr, &.{ 0x8b, 0x01, 0x8b, 0xc8, 0x81, 0xe1, 0x00, 0x00, 0x00, 0xc0 }) or
        !bytesEqual(.game_string_assign, &.{ 0x56, 0x8b, 0x74, 0x24, 0x08, 0x57, 0x8b, 0xf9, 0x8b, 0x47, 0x04 }) or
        !bytesEqual(.game_writer, &.{ 0x56, 0x8b, 0xf1, 0x83, 0x7e, 0x08, 0x00, 0x74, 0x08 }) or
        !bytesEqual(.game_set_label, &.{ 0x83, 0xec, 0x0c, 0x56, 0x8b, 0x74, 0x24, 0x14 })) return false;

    for (GAME_HOOKS) |hook| {
        if (!bytesEqual(hook.site, hook.original)) return false;
    }
    return true;
}

fn restoreBytes(site: FixedAddress, original: []const u8) void {
    var old: w.PAGE_PROTECTION_FLAGS = undefined;
    if (w.VirtualProtect(site.ptr(?*anyopaque), original.len, .{ .PAGE_EXECUTE_READWRITE = 1 }, &old) == w.FALSE) return;
    @memcpy(site.ptr([*]u8)[0..original.len], original);
    finishCodeWrite(site.address(), original.len, old);
}

const GameHook = struct {
    site: FixedAddress,
    original: []const u8,
    detour: ?DetourFn,
};

// A null detour means the original instructions are replaced entirely by NOPs.
const GAME_HOOKS: [9]GameHook = .{
    // zig fmt: off
    .{ .site = .frame_site,             .original = &.{ 0x03, 0xc8, 0x89, 0x4e, 0xf8 },             .detour = &frameDetour },
    .{ .site = .serialize_site,         .original = &.{ 0x8b, 0x07, 0x8b, 0x50, 0x44 },             .detour = &serializationDetour },
    .{ .site = .input_setup_site,       .original = &.{ 0x8b, 0x44, 0x24, 0x0c, 0x56 },             .detour = &inputSetupDetour },
    .{ .site = .analog_site,            .original = &.{ 0x8d, 0x44, 0x24, 0x0c, 0x50 },             .detour = &analogDetour },
    .{ .site = .analog_gate_set_site,   .original = &.{ 0xd9, 0x44, 0x24, 0x14, 0x51 },             .detour = &analogGateSetDetour },
    .{ .site = .analog_gate_clear_site, .original = &.{ 0x89, 0x10, 0x8b, 0x03, 0x8b, 0x48, 0x24 }, .detour = &analogGateClearDetour },
    .{ .site = .window_site,            .original = &.{ 0x8b, 0x91, 0xa4, 0x00, 0x00, 0x00 },       .detour = &windowDetour },
    .{ .site = .force_update_site,      .original = &.{ 0x0f, 0x84, 0x10, 0x01, 0x00, 0x00 },       .detour = null },
    .{ .site = .disable_call_site,      .original = &.{ 0xe8, 0xe6, 0x33, 0xff, 0xff },             .detour = null },
    // zig fmt: on
};

// There is a check for patch installation failed, but it would leave previous
// ones enabled.
fn installGameHooks() bool {
    for (GAME_HOOKS) |hook| {
        const installed = if (hook.detour) |detour|
            installJump(hook.site, hook.original, detour)
        else
            installNops(hook.site, hook.original);
        if (!installed) return false;
    }
    return true;
}

const FatalKind = enum {
    unsupported_game,
    allocation_failed,
    direct_input_failed,
    detour_failed,
    raw_input_failed,
};

fn fatal(comptime kind: FatalKind) void {
    const text: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral(switch (kind) {
        .unsupported_game => "Could not start: game executable not compatible with Competition Patch.",
        .allocation_failed => "Competition Patch could not allocate its replay state.",
        .direct_input_failed => "The competition patch could not hook DirectInput.",
        .detour_failed => "The competition patch could not install its game detours.",
        .raw_input_failed => "Could not detect devices. Toggle off the Alternate Method option in the game launcher if this problem persists.",
    });
    _ = w.MessageBoxW(null, text, std.unicode.utf8ToUtf16LeStringLiteral("Competition Patch Error"), w.MB_ICONERROR);
    _ = w.TerminateProcess(w.GetCurrentProcess(), 1);
}

// Validate the process, allocate state, and install all hooks.
fn initialize(_: ?*anyopaque) callconv(.winapi) u32 {
    if (w.GetAsyncKeyState(@backingInt(w.VK_PAUSE)) != 0 or existingPatchMarker()) return 0;
    if (!validateGameImage()) {
        fatal(.unsupported_game);
        return 0;
    }
    w.InitializeCriticalSection(&critical);
    const memory = w.VirtualAlloc(null, @sizeOf(PatchState), .{ .RESERVE = 1, .COMMIT = 1 }, w.PAGE_READWRITE) orelse {
        fatal(.allocation_failed);
        return 0;
    };
    // VirtualAlloc zeroes the state and leaves large buffers demand-paged.
    patch_state = @ptrCast(@alignCast(memory));
    patch_state.?.window_active = true;
    if (!installDirectInputHooks()) {
        fatal(.direct_input_failed);
        return 0;
    }
    if (!installGameHooks()) {
        fatal(.detour_failed);
        return 0;
    }
    return 0;
}

// The entire initialization is done under the loader lock??
pub fn DllMain(instance: w.HINSTANCE, reason: u32, _: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL {
    if (reason == w.DLL_PROCESS_ATTACH) {
        module = instance;
        _ = w.DisableThreadLibraryCalls(instance);
        _ = initialize(null);
    }
    return .TRUE;
}
