const std = @import("std");
const Allocator = std.mem.Allocator;

const http = @import("tortie").http;

const KeyPair = @import("KeyPair.zig");
const Board = @import("Board.zig");
const Timestamp = @import("Timestamp.zig");
const server_lib = @import("server.zig");
const Client = server_lib.Client;
const Server = server_lib.Server;

const Args = @import("args.zig").Args;

const key_mode = @import("modes/key_mode.zig");
const sign_mode = @import("modes/sign_mode.zig");
const server_mode = @import("modes/server_mode.zig");

pub const log_level = .debug;

const log = std.log.scoped(.main);

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var spring_args = Args.init(args) catch |err| switch (err) {
        error.NoArgs => {
            log.err("A run mode must be specified", .{});
            return;
        },
        else => return err,
    };

    switch (spring_args) {
        .server => |server_args| try server_mode.run(server_args.port),
        .key => try key_mode.run(),
        .sign => |sign_args| try sign_mode.run(allocator, sign_args),
    }
}
