const std = @import("std");

pub const original_code_hash: u32 = 0xc08e_f69c;
pub const chunk_id: u32 = 0x0304_f001;
pub const skip_marker: u32 = @bitCast([_]u8{ 'P', 'I', 'K', 'S' });

const Date = packed struct(u32) {
    year: u7,
    month: u4,
    day: u5,
    _unused: u16 = 0,
};

pub fn packDate(year: u16, month: u16, day: u16) u32 {
    return @backingInt(Date{
        .year = @truncate(year -% 60),
        .month = @intCast(month),
        .day = @intCast(day),
    });
}

fn mixLane(value: u32) u32 {
    var mixed = value;
    mixed ^= mixed >> 16;
    mixed *%= 0x045d_9f3b;
    mixed ^= mixed >> 16;
    mixed *%= 0x045d_9f3b;
    mixed ^= mixed >> 16;
    return mixed;
}

/// Identical to how 1.5.1 key derivation works. `history` contains the first
/// u32 from each eight-byte race-history entry in chronological storage order.
pub fn deriveKey(game_string: []const u8, history: []const u32) [16]u8 {
    var key = initialKey(game_string);
    for (history, 0..) |entry, index| mixHistoryEntry(&key, entry, index);
    return key;
}

pub fn initialKey(game_string: []const u8) [16]u8 {
    const split = game_string.len / 2;
    const seed: u64 = original_code_hash;
    const h0 = std.hash.XxHash64.hash(seed, game_string[0..split]);
    const h1 = std.hash.XxHash64.hash(seed, game_string[split..]);
    var key: [16]u8 = undefined;
    std.mem.writeInt(u64, key[0..8], h0, .little);
    std.mem.writeInt(u64, key[8..16], h1, .little);
    return key;
}

pub fn mixHistoryEntry(key: *[16]u8, entry: u32, index: usize) void {
    const at = (index & 3) * 4;
    const lane = std.mem.readInt(u32, key[at..][0..4], .little);
    std.mem.writeInt(u32, key[at..][0..4], mixLane(lane +% entry), .little);
}

/// AES-128-CFB128, we don't got it in the stdlib cuz it's a pretty mid mode.
pub fn encryptCfb128(data: []u8, key: [16]u8, iv: [16]u8) void {
    var feedback = iv;
    var offset: usize = 0;
    var aes = std.crypto.core.aes.Aes128.initEnc(key);
    while (offset < data.len) {
        var stream: [16]u8 = undefined;
        aes.encrypt(&stream, &feedback);
        const take = @min(16, data.len - offset);
        for (0..take) |index| {
            data[offset + index] ^= stream[index];
            feedback[index] = data[offset + index];
        }
        offset += take;
    }
}

pub const RecordInput = struct {
    iv: [16]u8,
    elapsed_low: u32,
    flags: u32,
    packed_date: u32,
    device_ids: []const u32,
    encoded_events: []const i32,
    key: [16]u8,
};

pub const BuildError = error{BufferTooSmall};

/// Builds only the record payload, written after the clear protocol hash and
/// encrypted-length fields. The returned bytes begin with the clear 16-byte IV.
pub fn buildEncryptedRecord(output: []u8, record: RecordInput) BuildError![]u8 {
    const word_count = 8 + record.device_ids.len + record.encoded_events.len;
    const required = word_count * 4;
    if (output.len < required) return error.BufferTooSmall;

    @memcpy(output[0..16], &record.iv);
    var at: usize = 16;
    write(output, &at, record.elapsed_low);
    write(output, &at, record.flags);
    write(output, &at, record.packed_date);
    write(output, &at, @intCast(record.device_ids.len));
    for (record.device_ids) |device| write(output, &at, device);
    for (record.encoded_events) |event| write(output, &at, @bitCast(event));

    encryptCfb128(output[16..required], record.key, record.iv);
    return output[0..required];
}

fn write(output: []u8, at: *usize, value: u32) void {
    std.mem.writeInt(u32, output[at.*..][0..4], value, .little);
    at.* += 4;
}
