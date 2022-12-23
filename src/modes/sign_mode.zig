const std = @import("std");
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;

const Args = @import("../args.zig").Args;
const KeyPair = @import("../KeyPair.zig");
const Board = @import("../Board.zig");
const Timestamp = @import("../Timestamp.zig");

pub fn run(allocator: Allocator, sign_args: Args.SignArgs) !void {
    const cwd = std.fs.cwd();

    var key_file = try cwd.openFile(sign_args.key_file, .{});
    defer key_file.close();

    const secret_key_len = Ed25519.SecretKey.encoded_length;
    const ascii_len = secret_key_len * 2;

    var key_bytes_ascii: [ascii_len]u8 = undefined; 
    _ = try key_file.read(&key_bytes_ascii);

    var key = try Ed25519.KeyPair.fromSecretKey(try KeyPair.secretKeyFromHexString(&key_bytes_ascii));
    
    var board_buffer = try std.ArrayList(u8).initCapacity(allocator, Board.board_size);
    defer board_buffer.deinit();

    var board_slice: [Board.board_size]u8 = undefined;
    const board = try cwd.readFile(sign_args.board, &board_slice);
    board_buffer.appendSliceAssumeCapacity(board);

    if (sign_args.append_timestamp) {
        var new_ts = Timestamp.now();
        try board_buffer.writer().print("<time datetime=\"{}\">", .{new_ts});

        var board_file = try cwd.createFile(sign_args.board, .{});
        try board_file.writeAll(board_buffer.items);
    }

    var signature = try key.sign(board_buffer.items, null);

    var writer = std.io.getStdOut().writer();

    try writer.print("Board signature is: {}\n", .{std.fmt.fmtSliceHexLower(&signature.toBytes())});
}