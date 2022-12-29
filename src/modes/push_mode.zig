const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const Ed25519 = std.crypto.sign.Ed25519;

const Args = @import("../args.zig").Args;
const KeyPair = @import("../KeyPair.zig");
const Board = @import("../Board.zig");
const Request = @import("../http/Request.zig");
const Response = @import("../http/Response.zig");

// @fixme Right now push mode is in an awkward state where the user will (likely) still have to run sign mode to append a current timestamp
//        to their board. This might feel redundant because push mode will _also_ sign their board, and there's no way to specify your own
//        signature. I think the easiest solution would be to allow users to ask push mode to append a timestamp as well.

/// Push mode allows a user to automatically push their board to their desired server. In addition to specifying a board to upload and
/// a server to upload to, the user also specifies their key file (easily generated with key mode). Springboard will use the key to sign
/// the board and to create the PUT request path.
pub fn run(in_allocator: Allocator, push_args: Args.PushArgs) !void {
    var arena = std.heap.ArenaAllocator.init(in_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const cwd = std.fs.cwd();

    var secret_key_hex = try cwd.readFileAlloc(allocator, push_args.key_file, 128);

    const secret_key = try KeyPair.secretKeyFromHexString(secret_key_hex);
    const key_pair = try Ed25519.KeyPair.fromSecretKey(secret_key);
    const public_key = key_pair.public_key;

    // We could clamp the max_bytes of this read to Board.board_size, but then we wouldn't be able to easily tell the user
    // that the board they provided was too large. Instead, we would just cut off the board content and fail silently.
    var board_content = try cwd.readFileAlloc(allocator, push_args.board, std.math.maxInt(u32));
    // Validate board timestamp & size
    _ = try Board.init(board_content);

    var signature = try key_pair.sign(board_content, null);

    _ = try std.os.windows.WSAStartup(2, 2);
    var server_connection = try net.tcpConnectToHost(allocator, push_args.server, push_args.port);
    defer server_connection.close();

    var request_buffer = std.ArrayList(u8).init(allocator);

    var path = try std.fmt.allocPrint(allocator, "/{}", .{std.fmt.fmtSliceHexLower(&public_key.toBytes())});
    var signature_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&signature.toBytes())});

    var writer = Request.writer(request_buffer.writer());
    try writer.writeStatus(.put, path);
    try writer.writeHeader("Spring-Version", "83");
    try writer.writeHeader("Spring-Signature", signature_hex);
    try writer.writeBody(board_content);
    try writer.complete();

    try server_connection.writer().writeAll(request_buffer.items);

    var response_content = try server_connection.reader().readAllAlloc(allocator, 1024);

    // @todo Parse response and show helpful messages
    try std.io.getStdOut().writer().writeAll(response_content);
}
