const std = @import("std");
const Timestamp = @import("./Timestamp.zig");
const KeyPair = @import("./KeyPair.zig");
const Ed25519 = std.crypto.sign.Ed25519;

pub const InvalidBoardError = error{
    TooLarge,
    InvalidTimestamp,
};

const Board = @This();

pub const board_size = 2217;

content: [board_size]u8 = undefined,
len: usize = 0,

pub fn init(content: []const u8) InvalidBoardError!Board {
    if (content.len > board_size) return InvalidBoardError.TooLarge;

    var board = Board{
        .len = content.len,
    };

    std.mem.copy(u8, board.content[0..], content);

    try board.validateTimestamp();
    return board;
}

pub fn verifySignature(board: Board, signature: []const u8, public_key: Ed25519.PublicKey) error{InvalidSignature}!void {
    const sig = KeyPair.signatureFromHexString(signature) catch return error.InvalidSignature;
    // Try to validate the signature of the board being uploaded. 
    sig.verify(board.content[0..board.len], public_key) catch return error.InvalidSignature;
}

pub fn getTimestamp(board: Board) error{InvalidTimestamp}!Timestamp {
    const time_prefix = "<time datetime=\"";
    const time_prefix_index = std.mem.indexOf(u8, &board.content, time_prefix) orelse return error.InvalidTimestamp;
    const time_index = time_prefix_index + time_prefix.len;
    const timestamp_string = board.content[time_index..time_index + 20];

    return Timestamp.parse(timestamp_string) catch return error.InvalidTimestamp;
}

fn validateTimestamp(board: Board) error{InvalidTimestamp}!void {
    const timestamp = try board.getTimestamp();
    const now_timestamp = Timestamp.now();
    if (timestamp.compare(now_timestamp) > 0) return error.InvalidTimestamp;
    
    const max_past_timestamp = timestamp.addOrSubtractDays(-22);
    if (timestamp.compare(max_past_timestamp) < 0) return error.InvalidTimestamp;
}

test "should extract a valid timestamp" {
    _ = try Board.init("<time datetime=\"2022-04-15T12:44:21Z\">");
    _ = try Board.init(
        \\<p>something</p>
        \\<time datetime="2022-04-15T12:44:21Z">
        \\<h1>something else</h1>
    );
}