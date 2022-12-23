const std = @import("std");
const epoch = std.time.epoch;

pub const ParseError = error{InvalidTimestamp};
const Timestamp = @This();

year: u16 = 0,
month: u8 = 0,
day: u8 = 0,

hour: u8 = 0,
minute: u8 = 0,
second: u8 = 0,

pub fn parse(timestamp_string: []const u8) ParseError!Timestamp {
    var timestamp: Timestamp = undefined;

    if (!std.mem.endsWith(u8, timestamp_string, "Z")) return error.InvalidTimestamp;

    var parts = std.mem.split(u8, timestamp_string[0..timestamp_string.len - 1], "T");

    // parse date
    var date = parts.next() orelse return error.InvalidTimestamp;
    var date_parts = std.mem.split(u8, date, "-");
    const year = date_parts.next() orelse return error.InvalidTimestamp;
    const month = date_parts.next() orelse return error.InvalidTimestamp;
    const day = date_parts.next() orelse return error.InvalidTimestamp;
    if (date_parts.next()) |_| return error.InvalidTimestamp;

    try timestamp.setDate(year, month, day);

    var time = parts.next() orelse return error.InvalidTimestamp;
    var time_parts = std.mem.split(u8, time, ":");
    const hour = time_parts.next() orelse return error.InvalidTimestamp;
    const minute = time_parts.next() orelse return error.InvalidTimestamp;
    const second = time_parts.next() orelse return error.InvalidTimestamp;
    if (time_parts.next()) |_| return error.InvalidTimestamp;

    try timestamp.setTime(hour, minute, second);

    if (parts.next()) |_| return error.InvalidTimestamp;

    return timestamp;
}

pub fn now() Timestamp {
    return fromEpochSeconds(@intCast(u64, std.time.timestamp()));
}

pub fn fromEpochSeconds(seconds: u64) Timestamp {
    var timestamp: Timestamp = undefined;

    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = seconds };
    const day_secs = epoch_secs.getDaySeconds();
    timestamp.second = @intCast(u8, day_secs.getSecondsIntoMinute());
    timestamp.minute = @intCast(u8, day_secs.getMinutesIntoHour());
    timestamp.hour = @intCast(u8, day_secs.getHoursIntoDay());

    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    timestamp.year = year_day.year;
    timestamp.month = @enumToInt(month_day.month);
    timestamp.day = @intCast(u8, month_day.day_index) + 1;

    return timestamp;
}

pub fn toEpochSeconds(timestamp: Timestamp) u64 {
    const day_seconds = 86400;
    const year_seconds = day_seconds * 365;
    const leap_year_seconds = day_seconds * 366;

    var seconds: u64 = 0;
    
    var year_to_check: u16 = 1970;
    while (year_to_check < timestamp.year) : (year_to_check += 1) {
        if (std.time.epoch.isLeapYear(year_to_check)) {
            seconds += leap_year_seconds;
        } else {
            seconds += year_seconds;
        }
    }

    var month_to_check: u8 = 1;
    while (month_to_check < timestamp.month) : (month_to_check += 1) {
        const leap_kind: std.time.epoch.YearLeapKind = if (std.time.epoch.isLeapYear(timestamp.year)) .leap else .not_leap;
        const days_in_month = std.time.epoch.getDaysInMonth(leap_kind, @intToEnum(std.time.epoch.Month, month_to_check));
        seconds += @intCast(u64, days_in_month) * day_seconds;
    }

    seconds += @intCast(u64, timestamp.day - 1) * day_seconds;
    seconds += @intCast(u64, timestamp.hour) * 3600;
    seconds += @intCast(u64, timestamp.minute) * 60;
    seconds += @intCast(u64, timestamp.second);

    return seconds;
}

pub fn addOrSubtractDays(timestamp: Timestamp, days_to_change: i32) Timestamp {
    const seconds_in_day = 86400;
    const seconds_to_change = days_to_change * seconds_in_day;
    const new_timestamp_seconds = if (seconds_to_change >= 0) 
        timestamp.toEpochSeconds() + @intCast(u64, seconds_to_change)
    else
        timestamp.toEpochSeconds() -% @intCast(u64, -1 * seconds_to_change);

    return Timestamp.fromEpochSeconds(@intCast(u64, new_timestamp_seconds));
}

fn getDaysInMonth(year: u16, month: u8) u8 {
    const leap_kind: std.time.epoch.YearLeapKind = if (std.time.epoch.isLeapYear(year)) .leap else .not_leap;
    return @intCast(u8, std.time.epoch.getDaysInMonth(leap_kind, @intToEnum(std.time.epoch.Month, month)));
}

/// Return 1 if `self` comes after `other`, -1 if `other` comes after `self`, and 0 if they are equal.
pub fn compare(self: Timestamp, other: Timestamp) i8 {
    const self_seconds = self.toEpochSeconds();
    const other_seconds = other.toEpochSeconds();

    if (self_seconds > other_seconds) return 1;
    if (self_seconds < other_seconds) return -1;
    return 0;
}

pub fn format(value: Timestamp, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;
    try value.print(writer);
}

pub fn print(timestamp: Timestamp, writer: anytype) !void {
    try writer.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{timestamp.year, timestamp.month, timestamp.day, timestamp.hour, timestamp.minute, timestamp.second});
}

fn setDate(timestamp: *Timestamp, year: []const u8, month: []const u8, day: []const u8) ParseError!void {
    timestamp.year = std.fmt.parseInt(u16, year, 10) catch return error.InvalidTimestamp;
    timestamp.month = std.fmt.parseInt(u8, month, 10) catch return error.InvalidTimestamp;
    timestamp.day = std.fmt.parseInt(u8, day, 10) catch return error.InvalidTimestamp;

    if (timestamp.month == 0 or timestamp.day == 0) return error.InvalidTimestamp;

    const max_days_in_month: u8 = switch (timestamp.month) {
        4, 6, 9, 11 => @as(u8, 30),
        1, 3, 5, 7, 8, 10, 12 => @as(u8, 31),
        2 => if (std.time.epoch.isLeapYear(timestamp.year)) @as(u8, 29) else @as(u8, 28),
        else => return error.InvalidTimestamp, 
    };

    if (timestamp.day > max_days_in_month) return error.InvalidTimestamp;
}

fn setTime(timestamp: *Timestamp, hour: []const u8, minute: []const u8, second: []const u8) ParseError!void {
    timestamp.hour = std.fmt.parseInt(u8, hour, 10) catch return error.InvalidTimestamp;
    timestamp.minute = std.fmt.parseInt(u8, minute, 10) catch return error.InvalidTimestamp;
    timestamp.second = std.fmt.parseInt(u8, second, 10) catch return error.InvalidTimestamp;

    if (timestamp.hour > 23 or timestamp.minute > 59 or timestamp.second > 59) return error.InvalidTimestamp;
}

fn testDate(timestamp: Timestamp, expected_year: u16, expected_month: u8, expected_day: u8) !void {
    try std.testing.expectEqual(expected_year, timestamp.year);
    try std.testing.expectEqual(expected_month, timestamp.month);
    try std.testing.expectEqual(expected_day, timestamp.day);
}

fn testTime(timestamp: Timestamp, expected_hour: u8, expected_minute: u8, expected_second: u8) !void {
    try std.testing.expectEqual(expected_hour, timestamp.hour);
    try std.testing.expectEqual(expected_minute, timestamp.minute);
    try std.testing.expectEqual(expected_second, timestamp.second);
}


test "gets timestamp from epoch seconds" {
    // This value was retrieved at 3:57:54 pm. CST, or 21:57:54 UTC on 2022-11-20
    const seconds: u64 = 1668981474;
    const timestamp = Timestamp.fromEpochSeconds(seconds);

    try testDate(timestamp, 2022, 11, 20);
    try testTime(timestamp, 21, 57, 54);
}

test "converts timestamp to epoch seconds" {
    const timestamp = Timestamp{
        .year = 2022,
        .month = 11,
        .day = 20,
        .hour = 21,
        .minute = 57,
        .second = 54,
    };
    const seconds = timestamp.toEpochSeconds();
    try std.testing.expectEqual(@as(u64, 1668981474), seconds);
}

test "parses valid ISO 8601 timestamp" {
    const time = "2022-05-14T16:40:25Z";
    const timestamp = try Timestamp.parse(time);

    try testDate(timestamp, 2022, 5, 14);
    try testTime(timestamp, 16, 40, 25);
}

test "expects exactly 1 'T' in date string" {
    const time = "2022-05-14TT16:40:25Z";
    try std.testing.expectError(error.InvalidTimestamp, Timestamp.parse(time));
}

test "expects date string to end in 'Z'" {
    const time = "2022-05-14T16:40:25";
    try std.testing.expectError(error.InvalidTimestamp, Timestamp.parse(time));
}

test "expects time and date" {
    const time = "2022-05-14";
    try std.testing.expectError(error.InvalidTimestamp, Timestamp.parse(time));
}

test "gets valid dates" {
    var timestamp: Timestamp = undefined;
    try timestamp.setDate("2022", "07", "17");

    try testDate(timestamp, 2022, 7, 17);
}

test "rejects dates with days exceeding max" {
    var timestamp: Timestamp = undefined;
    try std.testing.expectError(error.InvalidTimestamp, timestamp.setDate("2022", "08", "41"));
}

test "rejects non-numeric values in dates" {
    var timestamp: Timestamp = undefined;
    try std.testing.expectError(error.InvalidTimestamp, timestamp.setDate("20xx", "08", "13"));
}

test "computes new days over year boundary" {
    var timestamp = Timestamp{
        .year = 2022,
        .month = 12,
        .day = 25,
    };

    const days_to_increment = 10;
    const expected_timestamp = Timestamp{
        .year = 2023,
        .month = 1,
        .day = 4,
    };

    const new_timestamp = timestamp.addOrSubtractDays(days_to_increment);

    try std.testing.expectEqual(@as(i8, 0), new_timestamp.compare(expected_timestamp));
}

test "should print the timestamp correctly" {
    const timestamp = Timestamp{
        .year = 2022,
        .month = 5,
        .day = 1,
        .hour = 16,
        .minute = 40,
        .second = 5,
    };
    const expected_string = "2022-05-01T16:40:05Z";

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var writer = buffer.writer();
    try writer.print("{}", .{timestamp});

    try std.testing.expectEqualStrings(expected_string, buffer.items);
}