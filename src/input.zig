const std = @import("std");

pub const Flags = packed struct(u16) {
    @"break": bool,
    e0: bool,
    e1: bool,
    _unused2: u13,
};

/// Converts a Raw Input make code to the corresponding DirectInput offset.
pub fn rawKeyOffset(make_code: u16, flags: Flags, virtual_key: u16) ?u8 {
    if (virtual_key == 0xFF) return null;
    if (make_code == 0 or make_code > std.math.maxInt(u7)) return null;

    var offset: u8 = @intCast(make_code);
    if (flags.e1 or (flags.e0 and make_code != 0x45)) offset |= 0x80;
    return offset;
}

/// Normalizes a HID logical/physical range to DirectInput's [0, 65535) range.
pub fn normalizeAxis(value: i32, minimum: i32, maximum: i32) u32 {
    if (minimum >= maximum) return 0x7fff;
    const clamped = std.math.clamp(value, minimum, maximum);
    const numerator = @as(i64, clamped) - minimum;
    const denominator = @as(i64, maximum) - minimum;
    return @intCast(@divTrunc(numerator * 0xffff, denominator));
}

/// Reports whether the low signed 24 bits receive the random adjustment.
pub fn isAdjustableSigned24(original: u32) bool {
    const low = original & 0x00ff_ffff;
    const extended = if (low & 0x0080_0000 != 0) low | 0xff00_0000 else low;
    const signed: i32 = @bitCast(extended);
    return signed != 0 and signed != -0x10000 and signed != 0x10000;
}

/// Applies the original signed-24-bit adjustment while preserving the high byte.
pub fn adjustSigned24(original: u32, adjustment: i32) u32 {
    const low = original & 0x00ff_ffff;
    const extended = if (low & 0x0080_0000 != 0) low | 0xff00_0000 else low;
    const signed: i32 = @bitCast(extended);
    if (!isAdjustableSigned24(original)) return original;
    const adjusted = std.math.clamp(signed - adjustment, -0x10000, 0x10000);
    return (original & 0xff00_0000) | (@as(u32, @bitCast(adjusted)) & 0x00ff_ffff);
}
