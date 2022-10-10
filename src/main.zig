const std = @import("std");

const KeyPair = @import("KeyPair.zig");

pub const log_level = .debug;

pub fn main() anyerror!void {
    const writer = std.io.getStdOut().writer();

    var timer = try std.time.Timer.start();
    const start = timer.read();

    const key_pair = try KeyPair.generate(16);
    const end = timer.read();

    try writer.print("Took {d:.4} seconds to find a valid key\n", .{@divFloor(end - start, std.time.ns_per_s)});
    try writer.writeAll("Public key is : ");
    try KeyPair.printKey(key_pair.public_key[0..], writer);
}
