const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Thread = std.Thread;

const ThreadContext = struct {
    found_key: bool = false,
    key: ?Ed25519.KeyPair = null,
    now: KeyMonthYear,
};

pub const KeyMonthYear = struct {
    month: u8 = 0,
    year: u16 = 0,

    pub fn fromKey(key: [32]u8) !KeyMonthYear {
        var result = KeyMonthYear{};

        result.month = switch (key[30]) {
            1...0x09 => |m| m,
            0x10 => 10,
            0x11 => 11,
            0x12 => 12,
            else => return error.InvalidMonth,
        };

        const year_byte = key[31];
        const year_first_digit = (year_byte & 0xF0) >> 4;
        const year_second_digit = year_byte & 0x0F;

        if (year_first_digit >= 0x0a or year_second_digit >= 0x0a) {
            return error.InvalidYear;
        }

        result.year = 2000 + @intCast(u16, year_first_digit * 10 + year_second_digit);
        return result;
    }

    pub fn fromMs(ms: u64) KeyMonthYear {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @divFloor(ms, std.time.ms_per_s) };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return KeyMonthYear{
            .month = @enumToInt(month_day.month),
            .year = year_day.year,
        };
    }

    /// Check if `self` is valid on the date represented by `other`.
    pub fn checkExpirationDate(self: KeyMonthYear, other: KeyMonthYear) bool {
        // If self.year is in the past (relative to other), then it cannot be valid
        if (self.year < other.year) return false;

        const year_diff = self.year - other.year;

        return switch (year_diff) {
            0 => self.month >= other.month,
            1 => true,
            2 => self.month <= other.month,
            else => false,
        };
    }
};

pub fn generate(comptime thread_count: usize) !Ed25519.KeyPair {
    if (thread_count <= 1) {
        while (true) {
            if (tryGenerate()) |key_pair| {
                return key_pair;
            }
        }
    }

    const now = std.time.milliTimestamp();

    var context = ThreadContext{
        .now = KeyMonthYear.fromMs(@intCast(u64, now)),
    };

    std.log.debug("It is currently {}/{}", .{ context.now.month, context.now.year });

    var threads: [thread_count]Thread = undefined;
    for (threads) |*thread| {
        thread.* = try Thread.spawn(.{}, generateValidKeyPairThreaded, .{&context});
    }

    for (threads) |thread| {
        thread.join();
    }

    return context.key.?;
}

pub fn isValid(key: [32]u8) bool {
    if (!hasMagicIdentifier(key)) return false;

    const key_month_year = KeyMonthYear.fromKey(key) catch return false;
    const current_date = KeyMonthYear.fromMs(@intCast(u64, std.time.milliTimestamp()));

    return key_month_year.checkExpirationDate(current_date);
}

pub fn printKey(key: []const u8, writer: anytype) !void {
    try writer.writeAll("0x");
    for (key) |byte| {
        const first_digit = (byte & 0xf0) >> 4;
        const second_digit = byte & 0x0f;
        try writer.print("{x}{x}", .{ first_digit, second_digit });
    }
}

pub fn secretKeyFromHexString(hex: []const u8) !Ed25519.SecretKey {
    var key_buf: [Ed25519.SecretKey.encoded_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key_buf, hex);
    return try Ed25519.SecretKey.fromBytes(key_buf);
}

pub fn publicKeyFromHexString(hex: []const u8) !Ed25519.PublicKey {
    var key_buf: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key_buf, hex);
    return try Ed25519.PublicKey.fromBytes(key_buf);
}

pub fn signatureFromHexString(hex: []const u8) !Ed25519.Signature {
    var key_buf: [Ed25519.Signature.encoded_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key_buf, hex);
    return Ed25519.Signature.fromBytes(key_buf);
}

fn generateValidKeyPairThreaded(context: *ThreadContext) !void {
    // Run this loop as long as context.found_key is false
    while (!@atomicLoad(bool, &context.found_key, .Acquire)) {
        if (tryGenerate(context.now)) |key_pair| {
            // Once a valid key is found, signal that to the other threads by trying to atomically load true into context.found_key.
            // If that succeeds, then set context.key_pair to the genereated key. Otherwise, another thread has already found a valid key
            // and this thread is going to exit
            if (@cmpxchgStrong(bool, &context.found_key, false, true, .SeqCst, .SeqCst) == null) {
                context.key = key_pair;
                return;
            }
        }
    }
}

fn tryGenerate(current_date: KeyMonthYear) ?Ed25519.KeyPair {
    const key_pair = Ed25519.KeyPair.create(null) catch return null;
    if (hasMagicIdentifier(key_pair.public_key.toBytes())) {
        // Try to get a valid year from the public key
        const key_month_year = KeyMonthYear.fromKey(key_pair.public_key.toBytes()) catch return null;
        if (key_month_year.checkExpirationDate(current_date)) {
            return key_pair;
        }
    }
    return null;
}

fn hasMagicIdentifier(key: [32]u8) bool {
    return key[28] & 0x0F == 0x08 and key[29] == 0x3e;
}

/// For use in tests - create a default key with a valid magic identifier and the given year/month bytes.
fn buildTestKey(month_byte: u8, year_byte: u8) [32]u8 {
    var default = [_]u8{0} ** 32;
    default[28] = 0x08;
    default[29] = 0x3e;
    default[30] = month_byte;
    default[31] = year_byte;
    return default;
}

test "KeyMonthYear gets correct month and year values from key" {
    const key = buildTestKey(0x09, 0x22);
    const key_month_year = try KeyMonthYear.fromKey(key);
    try std.testing.expectEqual(@as(u8, 9), key_month_year.month);
    try std.testing.expectEqual(@as(u16, 2022), key_month_year.year);
}

test "should catch invalid month when month is > 12" {
    const key = buildTestKey(0x15, 0x22);
    const key_month_year = KeyMonthYear.fromKey(key);
    try std.testing.expectError(error.InvalidMonth, key_month_year);
}

test "october (0x10) should be a valid month, but 0x00 shouldn't" {
    const valid_key = buildTestKey(0x10, 0x22);
    const valid_key_month_year = try KeyMonthYear.fromKey(valid_key);
    try std.testing.expectEqual(@as(u8, 10), valid_key_month_year.month);

    const invalid_key = buildTestKey(0x00, 0x22);
    const invalid_key_month_year = KeyMonthYear.fromKey(invalid_key);
    try std.testing.expectError(error.InvalidMonth, invalid_key_month_year);
}

test "key should be valid in the same year it expires if the month is greater" {
    const test_key = try KeyMonthYear.fromKey(buildTestKey(0x11, 0x22));
    const current_date = KeyMonthYear{ .month = 8, .year = 2022 };

    const is_key_valid = test_key.checkExpirationDate(current_date);
    try std.testing.expect(is_key_valid);
}

test "key should be valid in two calendar years if the month is less" {
    const test_key = try KeyMonthYear.fromKey(buildTestKey(0x5, 0x24));
    const current_date = KeyMonthYear{ .month = 6, .year = 2022 };

    const is_key_valid = test_key.checkExpirationDate(current_date);
    try std.testing.expect(is_key_valid);
}

test "key should not be valid in the current year if the month is less" {
    const test_key = try KeyMonthYear.fromKey(buildTestKey(0x5, 0x22));
    const current_date = KeyMonthYear{ .month = 6, .year = 2022 };

    const is_key_valid = test_key.checkExpirationDate(current_date);
    try std.testing.expect(!is_key_valid);
}
