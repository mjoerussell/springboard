const std = @import("std");
const Allocator = std.mem.Allocator;

const http = @import("tortie").http;

const KeyPair = @import("KeyPair.zig");
const Board = @import("Board.zig");
const Timestamp = @import("Timestamp.zig");
const server_lib = @import("server.zig");
const Client = server_lib.Client;
const Server = server_lib.Server;

pub const log_level = .debug;

const log = std.log.scoped(.main);

const Args = union(enum) {
    server: ServerArgs,
    key: KeyArgs,
    sign: SignArgs,
    // push: PushArgs,

    pub const ServerArgs = struct {
        port: u16,

        pub fn init(args: [][]const u8) !ServerArgs {
            for (args) |arg, index| {
                if (index == args.len - 1) return error.ExpectedFollowUp;
                if (std.mem.eql(u8, arg, "--port")) {
                    return ServerArgs{
                        .port = try std.fmt.parseInt(u16, args[index + 1], 10),
                    };
                }
            }

            return error.MissingArg;
        }
    };

    pub const KeyArgs = struct {
        pub fn init(args: [][]const u8) !KeyArgs {
            _ = args;
            return KeyArgs{};
        }
    };

    pub const SignArgs = struct {
        board: []const u8,
        key_file: []const u8,
        append_timestamp: bool = false,

        pub fn init(args: [][]const u8) !SignArgs {
            var init_tracker: u8 = 0;
            var sign_args: SignArgs = undefined;
            for (args) |arg, index| {
                if (std.mem.eql(u8, arg, "--board")) {
                    if (index == args.len - 1) return error.ExpectedFollowUp;
                    sign_args.board = args[index + 1];
                    init_tracker |= 1;
                } else if (std.mem.eql(u8, arg, "--key-file")) {
                    if (index == args.len - 1) return error.ExpectedFollowUp;
                    sign_args.key_file = args[index + 1];
                    init_tracker |= 2;
                } else if (std.mem.eql(u8, arg, "--append-timestamp")) {
                    if (index == args.len - 1) return error.ExpectedFollowUp;
                    sign_args.append_timestamp = std.ascii.eqlIgnoreCase(args[index + 1], "true");
                    init_tracker |= 4;
                }
            }

            if (init_tracker == 8 or init_tracker == 3) return sign_args;
            return error.MissingArg;
        }
    };

    // pub const PushArgs = struct {
    //     .server_path: []const u8,
    //     .board: []const u8,

    //     pub fn init(args: [][]const u8) !PushArgs {
            
    //     }
    // }

    pub fn init(args: [][]const u8) !Args {
        if (args.len < 2) return error.NoArgs;

        const args_type = args[1];

        inline for (std.meta.fields(Args)) |field| {
            if (std.mem.eql(u8, args_type, field.name)) {
                var initialized_args = try field.type.init(args[2..]);
                return @unionInit(Args, field.name, initialized_args);
            }
        }

        return error.InvalidOperation;
    }
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var spring_args = try Args.init(args);
    switch (spring_args) {
        .server => |server_args| try runServerMode(allocator, server_args.port),
        .key => try runKeyMode(allocator),
        .sign => |sign_args| try runSignMode(allocator, sign_args),
    }

    // try runServerMode(allocator, 8000);
}

fn runKeyMode(allocator: Allocator) !void {
    _ = allocator;
    var key_pair = try KeyPair.generate(8);

    var writer = std.io.getStdOut().writer();
    
    var public_key_bytes = key_pair.public_key.toBytes();
    var secret_key_bytes = key_pair.secret_key.toBytes();

    try writer.print("Public Key: {}\n", .{std.fmt.fmtSliceHexLower(&public_key_bytes)});
    try writer.print("Secret Key: {}\n", .{std.fmt.fmtSliceHexLower(&secret_key_bytes)});

}

fn runSignMode(allocator: Allocator, sign_args: Args.SignArgs) !void {
    const Ed25519 = std.crypto.sign.Ed25519;
    const cwd = std.fs.cwd();


    var key_file = try cwd.openFile(sign_args.key_file, .{});
    defer key_file.close();

    const secret_key_len = Ed25519.SecretKey.encoded_length;
    const ascii_len = secret_key_len * 2;

    var key_bytes_ascii: [ascii_len]u8 = undefined; 
    _ = try key_file.read(&key_bytes_ascii);

    var key = try Ed25519.KeyPair.fromSecretKey(try KeyPair.secretKeyFromHexString(&key_bytes_ascii));

    var board_file = try cwd.openFile(sign_args.board, .{});
    defer board_file.close();
    
    var board = try board_file.readToEndAlloc(allocator, Board.board_size);
    defer allocator.free(board);

    var signature = try key.sign(board, null);

    var writer = std.io.getStdOut().writer();

    try writer.print("Board signature is: {}\n", .{std.fmt.fmtSliceHexLower(&signature.toBytes())});
}

fn runServerMode(allocator: Allocator, port: u16) !void {
    var localhost = try std.net.Address.parseIp("0.0.0.0", port);

    var server = try Server.init(localhost);

    while (true) {
        if (server.accept()) |client| {
            try client.recv();
        } else |err| {
            if (err != error.WouldBlock) return err;
        }

        var maybe_client = server.getCompletion() catch |err| switch (err) {
            error.WouldBlock, error.Eof => continue,
            else => return err,
        };

        if (maybe_client) |client| {
            if (client.is_reading) {
                handleIncomingRequest(allocator, client) catch |err| {
                    std.debug.print("Error handling incoming message: {}\n", .{err});
                };
            } else {
                client.deinit();
            }
        }
        
    }
}

fn handleIncomingRequest(allocator: Allocator, client: *Client) !void {
    var fbs = std.io.fixedBufferStream(&client.buffer);
    var writer = fbs.writer();
    
    var request = http.Request.parse(allocator, client.buffer[0..client.len]) catch {
        try writer.writeAll("HTTP/1.1 400 Bad Request\r\n\r\n");
        try client.send();
        return;
    };

    switch (request.method) {
        .get => {
            if (std.mem.eql(u8, request.uri, "/")) {
                const cwd = std.fs.cwd();
                var index_file = try cwd.openFile("static/index.html", .{});
                defer index_file.close();

                var response = try http.Response.initStatus(allocator, .ok);
                try response.addHeader("Content-Type", "text/html");
                
                var index_buffer: [2048]u8 = undefined;
                const index_len = try index_file.readAll(&index_buffer);
                response.body = index_buffer[0..index_len];

                try response.write(writer);
                client.len = fbs.pos;
                std.log.info("Response len = {}", .{client.len});  
                
                try client.send();
                return;
            }

            // getting a board
            const public_key = request.uri[1..];
            const cwd = std.fs.cwd();

            const board_path_buf = getBoardPath("boards/", public_key);
            var board_file = cwd.openFile(&board_path_buf, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    std.log.warn("Tried to get non-existant board", .{});
                    try writer.writeAll("HTTP/1.1 404 Not Found\r\n\r\n");
                    client.len = fbs.pos;
                    try client.send();
                    return;
                },
                else => return err,
            };

            var board_reader = board_file.reader();

            var sig_buf: [129]u8 = undefined;
            const signature = board_reader.readUntilDelimiter(&sig_buf, '\n') catch |err| {
                switch (err) {
                    error.EndOfStream => std.log.warn("Board is corrupted - could not read entire signature. Board = {s}", .{public_key}),
                    error.StreamTooLong => std.log.warn("Board is corrupted - signature value is too long, or is not properly terminated. Board = {s}", .{public_key}),
                    else => std.log.warn("Unexpected error when reading board signature. Err = {} | Board = {s}", .{err, public_key}),
                }

                try writer.writeAll("HTTP/1.1 404 Not Found\r\n\r\n");
                client.len = fbs.pos;
                try client.send();
                return;
            };
            
            var board_buf: [Board.board_size]u8 = undefined;
            const board_len = board_reader.readAll(&board_buf) catch |err| {
                std.log.warn("Error reading board content: {} | Board = {s}", .{err, public_key});
                try writer.writeAll("HTTP/1.1 500 Internal Server Error\r\n\r\n");
                client.len = fbs.pos;
                try client.send();
                return;
            };

            const board = Board.init(board_buf[0..board_len]) catch |err| {
                std.log.warn("Tried loading an invalid board: Err = {} | Board = {s}", .{err, public_key});
                try writer.writeAll("HTTP/1.1 404 Not Found\r\n\r\n");
                client.len = fbs.pos;
                try client.send();
                return;
            };

            // Check if the board is newer than the 'If-Modified-Since' header, if the header was provided by
            // the client.
            if (request.headers.getFirstValue("If-Modified-Since")) |if_modified| {
                // Parse the header value. If the provided value is not a valid timestamp, just abort
                // this check and pretend the header wasn't provided at all.
                if (Timestamp.parse(if_modified)) |last_modified_ts| {
                    // The timestamp can't be invalid here because it would have been caught in the board
                    // initialization above.
                    const board_ts = board.getTimestamp() catch unreachable;
                    if (board_ts.compare(last_modified_ts) <= 0) {
                        // Board is older than if-modified-since, so the server should respond with 304
                        try writer.writeAll("HTTP/1.1 304 Not Modified\r\n\r\n");
                        client.len = fbs.pos;
                        try client.send();
                        return;
                    }
                } else |_| {}
            }

            var response = try http.Response.initStatus(allocator, .ok);
            defer response.deinit();

            try response.addHeader("Content-Type", "text/html;charset=utf-8");
            try response.addHeader("Spring-Version", "83");
            try response.addHeader("Spring-Signature", signature);
            try response.addHeader("Content-Length", board_len);
            response.body = board_buf[0..board_len];
            
            try response.write(writer);
            client.len = fbs.pos;
            try client.send();
        },
        .put => {
            const cwd = std.fs.cwd();
            const public_key = request.uri[1..];

            // TODO: duplicate of above
            var pub_key = KeyPair.publicKeyFromHexString(public_key) catch {
                std.log.warn("Invalid public key", .{});
                try writer.writeAll("HTTP/1.1 403 Forbidden\r\n\r\n");
                client.len = fbs.pos;
                try client.send();
                return;
            };

            // Make sure that the key conforms to the Spring83 standard
            if (!KeyPair.isValid(pub_key.toBytes())) {
                std.log.warn("Invalid public key", .{});
                try writer.writeAll("HTTP/1.1 403 Forbidden\r\n\r\n");
                client.len = fbs.pos;
                try client.send();
                return;
            }
            
            // Check the denylist to see if this key is on it.
            var denylist_file = try cwd.openFile("denylist.txt", .{});
            defer denylist_file.close();

            var denylist = try denylist_file.readToEndAlloc(allocator, std.math.maxInt(u32));
            defer allocator.free(denylist);

            var invalid_keys = std.mem.split(u8, denylist, "\n");
            while (invalid_keys.next()) |invalid_key| {
                if (std.mem.eql(u8, invalid_key, public_key)) {
                    try writer.writeAll("HTTP/1.1 403 Forbidden\r\n\r\n");
                    client.len = fbs.pos;
                    try client.send();
                    return;
                }
            }
            
            // Make sure that the user actually sent a board in the request body
            if (request.body == null) {
                std.log.warn("No body sent in request", .{});
                try writer.writeAll("HTTP/1.1 400 Bad Request\r\n\r\n");
                try client.send();
                return;
            }

            // Make sure that the board is not too large and contains a valid <time> element
            var board = Board.init(request.body.?) catch |err| switch (err) {
                error.TooLarge => {
                    try writer.writeAll("HTTP/1.1 413 Payload Too Large\r\n\r\n");
                    client.len = fbs.pos;
                    try client.send();
                    return;
                },
                error.InvalidTimestamp => {
                    std.log.warn("Board timestamp was invalid", .{});
                    try writer.writeAll("HTTP/1.1 400 Bad Request\r\n\r\n");
                    client.len = fbs.pos;
                    try client.send();
                    return;
                }
            };
            
            // Make sure that a signature was provided and, if so, that it is the valid signature
            // for the board as given.
            const signature = request.headers.getFirstValue("Spring-Signature") orelse {
                std.log.warn("No board signature provided", .{});
                try writer.writeAll("HTTP/1.1 400 Bad Request\r\n\r\n");
                client.len = fbs.pos;
                try client.send();
                return;
            };

            board.verifySignature(signature, pub_key) catch {
                std.log.warn("Board signature was invalid", .{});
                try writer.writeAll("HTTP/1.1 403 Forbidden\r\n\r\n");
                client.len = fbs.pos;
                try client.send();
                return;
            };

            const board_path_buf = getBoardPath("boards/", public_key);

            // The final step is to check the existing board timestamp. If the board does not exist yet,
            // then there's nothing else to do and we can just write the file. Otherwise, we have to make
            // sure that the new board's timestamp comes _after_ the existing board's timestamp.
            if (cwd.openFile(&board_path_buf, .{})) |existing_board_file| {
                var existing_board_buf: [Board.board_size]u8 = undefined;
                var existing_board_len = try existing_board_file.readAll(&existing_board_buf);
                
                var existing_board = try Board.init(existing_board_buf[0..existing_board_len]);
                // These can't fail because we've already validated the timestamp in Board.init()
                var existing_board_timestamp = existing_board.getTimestamp() catch unreachable;
                var new_board_timestamp = board.getTimestamp() catch unreachable;
                // If this is true, then the existing board has a timestamp that is either the same or in
                // the future from the incoming board's timestamp, which is not allowed to happen.
                if (existing_board_timestamp.compare(new_board_timestamp) >= 0) {
                    std.log.warn("Board already exists and existing timestamp is newer", .{});
                    try writer.writeAll("HTTP/1.1 409 Conflict\r\n\r\n");
                    client.len = fbs.pos;
                    try client.send();
                    return;
                }

            } else |err| {
                if (err != error.FileNotFound) return err;
            }

            std.log.info("Creating board at boards/{s}", .{public_key});
            
            var board_file = try cwd.createFile(&board_path_buf, .{});
            defer board_file.close();

            var board_writer = board_file.writer();
            try board_writer.print("{s}\n", .{signature});
            try board_writer.writeAll(board.content[0..board.len]);
            
            try writer.writeAll("HTTP/1.1 201 Created\r\n\r\n");
            client.len = fbs.pos;
            try client.send();
            return;
        },
        .options => {
            try writer.writeAll(
                \\HTTP/1.1 204 No Content
                \\Access-Control-Allow-Methods: GET, OPTIONS, PUT
                \\Access-Control-Allow-Origin: *
                \\Access-Control-Allow-Headers: Content-Type, If-Modified-Since, Spring-Signature, Spring-Version
                \\Access-Control-Expose-Headers: Content-Type, Last-Modified, Spring-Signature, Spring-Version
            );

            client.len = fbs.pos;
            try client.send();
        },
        else => {
            try writer.writeAll("HTTP/1.1 405 Method Not Allowed\r\n\r\n");
            try client.send();
        }
    }
}

fn getBoardPath(comptime board_path_prefix: []const u8, public_key: []const u8) [board_path_prefix.len + 64]u8 {
    var path: [board_path_prefix.len + 64]u8 = undefined;
    std.mem.copy(u8, &path, board_path_prefix);
    std.mem.copy(u8, path[board_path_prefix.len..], public_key);
    return path;
}




