const std = @import("std");
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;

const server_lib = @import("../server.zig");
const Server = server_lib.Server;
const Client = server_lib.Client;

const KeyPair = @import("../KeyPair.zig");
const Board = @import("../Board.zig");
const Timestamp = @import("../Timestamp.zig");

const http = @import("tortie").http;

const log = std.log.scoped(.server);

pub fn run(allocator: Allocator, port: u16) !void {
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
                    log.debug("Error handling incoming message: {}\n", .{err});
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
                log.info("Response len = {}", .{client.len});  
                
                try client.send();
                return;
            }

            // getting a board
            const public_key = request.uri[1..];
            const cwd = std.fs.cwd();

            const board_path_buf = getBoardPath("boards/", public_key);
            var board_file = cwd.openFile(&board_path_buf, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    log.warn("Tried to get non-existant board", .{});
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
                log.warn("Error reading board content: {} | Board = {s}", .{err, public_key});
                try writer.writeAll("HTTP/1.1 500 Internal Server Error\r\n\r\n");
                client.len = fbs.pos;
                try client.send();
                return;
            };

            const board = Board.init(board_buf[0..board_len]) catch |err| {
                log.warn("Tried loading an invalid board: Err = {} | Board = {s}", .{err, public_key});
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

            var pub_key = getPublicKeyFromUri(request.uri) catch {
                log.warn("Invalid public key", .{});
                try writer.writeAll("HTTP/1.1 403 Forbidden\r\n\r\n");
                client.len = fbs.pos;
                try client.send();
                return;
            };
            
            if (try denylistContainsKey("denylist.txt", public_key)) {
                log.warn("Key belongs to denylist, board upload is forbidden", .{});
                try writer.writeAll("HTTP/1.1 403 Forbidden\r\n\r\n");
                client.len = fbs.pos;
                try client.send();
                return;
            }
            
            // Make sure that the user actually sent a board in the request body
            if (request.body == null) {
                log.warn("No body sent in request", .{});
                try writer.writeAll("HTTP/1.1 400 Bad Request\r\n\r\n");
                try client.send();
                return;
            }

            // Make sure that a signature was provided and, if so, that it is the valid signature
            // for the board as given.
            const signature = request.headers.getFirstValue("Spring-Signature") orelse {
                log.warn("No board signature provided", .{});
                try writer.writeAll("HTTP/1.1 400 Bad Request\r\n\r\n");
                client.len = fbs.pos;
                try client.send();
                return;
            };

            const board = validateIncomingBoard(request.body.?, signature, pub_key) catch |err| switch (err) {
                error.TooLarge => {
                    try writer.writeAll("HTTP/1.1 413 Payload Too Large\r\n\r\n");
                    client.len = fbs.pos;
                    try client.send();
                    return;
                },
                error.InvalidPublicKey, error.InvalidTimestamp => {
                    log.warn("Board timestamp was invalid", .{});
                    try writer.writeAll("HTTP/1.1 400 Bad Request\r\n\r\n");
                    client.len = fbs.pos;
                    try client.send();
                    return;
                },
                error.InvalidSignature => {
                    log.warn("Board signature was invalid", .{});
                    try writer.writeAll("HTTP/1.1 403 Forbidden\r\n\r\n");
                    client.len = fbs.pos;
                    try client.send();
                    return;
                },
                error.OutdatedTimestamp => {
                    log.warn("Board already exists and existing timestamp is newer", .{});
                    try writer.writeAll("HTTP/1.1 409 Conflict\r\n\r\n");
                    client.len = fbs.pos;
                    try client.send();
                    return;
                },
            };

            log.info("Creating board at boards/{s}", .{public_key});
            
            const board_path_buf = getBoardPath("boards/", public_key);
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

fn getPublicKeyFromUri(uri: []const u8) !Ed25519.PublicKey {
    var pub_key = KeyPair.publicKeyFromHexString(uri[1..]) catch return error.InvalidKey;

    // Make sure that the key conforms to the Spring83 standard
    if (!KeyPair.isValid(pub_key.toBytes())) return error.InvalidKey;

    return pub_key;
}

fn denylistContainsKey(denylist_filename: []const u8, public_key: []const u8) !bool {
    // Check the denylist to see if this key is on it.
    const cwd = std.fs.cwd();
    var denylist_file = try cwd.openFile(denylist_filename, .{});
    defer denylist_file.close();

    var denylist_buf: [65]u8 = undefined;
    while (denylist_file.read(&denylist_buf)) |len| {
        if (len == 0) return false;
        if (std.mem.eql(u8, denylist_buf[0..64][0..], public_key)) return true;
    } else |_| return false;
}

const BoardValidationError = error{
    TooLarge,
    InvalidTimestamp,
    InvalidPublicKey,
    InvalidSignature,
    OutdatedTimestamp,
};

fn validateIncomingBoard(board_content: []const u8, signature: []const u8, public_key: Ed25519.PublicKey) BoardValidationError!Board {
    // Make sure that the board is not too large and contains a valid <time> element
    var board = Board.init(board_content) catch |err| switch (err) {
        error.TooLarge => return BoardValidationError.TooLarge,
        error.InvalidTimestamp => return BoardValidationError.InvalidTimestamp,
    };
    
    board.verifySignature(signature, public_key) catch return error.InvalidSignature;

    var board_path_buf: [200]u8 = undefined;
    const board_path = std.fmt.bufPrint(&board_path_buf, "boards/{}", .{std.fmt.fmtSliceHexLower(&public_key.toBytes())}) catch return error.InvalidPublicKey;

    const cwd = std.fs.cwd();
    if (cwd.openFile(board_path, .{})) |existing_board_file| blk: {
        defer existing_board_file.close();

        // The final step is to check the existing board timestamp. If the board does not exist yet,
        // then there's nothing else to do and we can just write the file. Otherwise, we have to make
        // sure that the new board's timestamp comes _after_ the existing board's timestamp.
        var existing_board_buf: [Board.board_size]u8 = undefined;
        var existing_board_len = existing_board_file.readAll(&existing_board_buf) catch break :blk;
        
        var existing_board = Board.init(existing_board_buf[0..existing_board_len]) catch {
            std.log.info("An error was found while validating an existing board. The board will be replaced.", .{});
            break :blk;
        };
        // These can't fail because we've already validated the timestamp in Board.init()
        var existing_board_timestamp = existing_board.getTimestamp() catch unreachable;
        var new_board_timestamp = board.getTimestamp() catch unreachable;
        
        // If this is true, then the existing board has a timestamp that is either the same or in
        // the future from the incoming board's timestamp, which is not allowed to happen.
        if (existing_board_timestamp.compare(new_board_timestamp) >= 0) {
            return error.OutdatedTimestamp;
        }
    } else |_| {}

    return board;
}

fn getBoardPath(comptime board_path_prefix: []const u8, public_key: []const u8) [board_path_prefix.len + 64]u8 {
    var path: [board_path_prefix.len + 64]u8 = undefined;
    std.mem.copy(u8, &path, board_path_prefix);
    std.mem.copy(u8, path[board_path_prefix.len..], public_key);
    return path;
}