const std = @import("std");
const KeyPair = @import("../KeyPair.zig");

pub fn run() !void {
    var key_pair = try KeyPair.generate(8);

    var writer = std.io.getStdOut().writer();
    
    var public_key_bytes = key_pair.public_key.toBytes();
    var secret_key_bytes = key_pair.secret_key.toBytes();

    try writer.print("Public Key: {}\n", .{std.fmt.fmtSliceHexLower(&public_key_bytes)});
    try writer.print("Secret Key: {}\n", .{std.fmt.fmtSliceHexLower(&secret_key_bytes)});

}