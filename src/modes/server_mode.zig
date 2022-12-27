const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

const server_lib = @import("../server.zig");
const Server = server_lib.Server;
const Client = server_lib.Client;

const Args = @import("../args.zig").Args;

const KeyPair = @import("../KeyPair.zig");
const Board = @import("../Board.zig");
const Timestamp = @import("../Timestamp.zig");

const Request = @import("../http/Request.zig");
const Response = @import("../http/Response.zig");

const log = std.log.scoped(.server);

// This key pair is defined by the spec to be used to sign a test board. Boards should not be allowed to be uploaded
// using this key.
const test_public_key_hex = "ab589f4dde9fce4180fcf42c7b05185b0a02a5d682e353fa39177995083e0583";
const test_secret_key = KeyPair.secretKeyFromHexString("3371f8b011f51632fea33ed0a3688c26a45498205c6097c352bd4d079d224419" ++ test_public_key_hex) catch unreachable;

pub fn run(args: Args.ServerArgs) !void {
    var localhost = try std.net.Address.parseIp("0.0.0.0", args.port);

    var server = try Server.init(localhost);

    const cwd = std.fs.cwd();
    cwd.makeDir(args.board_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            log.info("Note: Tried to create board directory at \"{s}\", but the directory already exists.", .{args.board_dir});
        },
        else => {
            log.err("Fatal error: Could not create the board directory at \"{s}\" - {}", .{args.board_dir, err});
            return err;
        },
    };

    log.info("Boards will be stored at path \"{s}\"", .{args.board_dir});
    log.info("Listening on port {}", .{args.port});

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
                var fbs = std.io.fixedBufferStream(&client.buffer);
                client.response = Response.writer(fbs.writer());
                
                client.request = Request{ .data = client.buffer[0..client.len] };
                handleIncomingRequest(client, args.board_dir) catch |err| {
                    log.debug("Error handling incoming message: {}\n", .{err});
                    const status: Response.ResponseStatus = switch (err) {
                        Request.GeneralError.ParseError => .bad_request,
                        else => .internal_server_error,
                    };

                    client.response.writeStatus(status) catch {};
                };

                client.response.complete() catch {};
                client.len = fbs.pos;
                client.send() catch {};
            } else {
                client.deinit();
            }
        }
        
    }
}

fn handleIncomingRequest(client: *Client, board_directory: []const u8) !void {
    const method = try client.request.getMethod();
    const path = try client.request.getPath(); 

    switch (method) {
        .get => {
            if (std.mem.eql(u8, path, "/")) {
                return try handleGetIndex(client);
            }

            // getting a board
            return try handleGetBoard(client, path, board_directory);
        },
        .put => return try handlePutBoard(client, path, board_directory),
        .options => {
            try client.response.writeStatus(.no_content);
            try client.response.writeHeader("Access-Control-Allow-Methods", "GET, OPTIONS, PUT");
            try client.response.writeHeader("Access-Control-Allow-Origin", "*");
            try client.response.writeHeader("Access-Control-Allow-Headers", "Content-Type, If-Modified-Since, Spring-Signature, Spring-Version");
            try client.response.writeHeader("Access-Control-Expose-Headers", "Content-Type, Last-Modified, Spring-Signature, Spring-Version");
        },
        else => {
            try client.response.writeStatus(.method_not_allowed);
        }
    }
}

/// GET /. Returns the main index.html page.
fn handleGetIndex(client: *Client) !void {
    const cwd = std.fs.cwd();
    var index_file = try cwd.openFile("static/index.html", .{});
    defer index_file.close();

    try client.response.writeStatus(.ok);
    try client.response.writeHeader("Content-Type", "text/html");
    
    var index_buffer: [2048]u8 = undefined;
    const index_len = try index_file.readAll(&index_buffer);
    try client.response.writeBody(index_buffer[0..index_len]);
}

/// GET /{key}. Tries to return the board uploaded under the specified key, if it exists.
fn handleGetBoard(client: *Client, path: []const u8, board_directory: []const u8) !void {
    // @todo Validate the board signature here, so that the client doesn't have to do it.
    // Return some kind of error code in case the signature doesn't match the board content. 
    const public_key = path[1..];

    if (std.mem.eql(u8, public_key, test_public_key_hex)) {
        return try createAndSendTestBoard(client);
    }

    const cwd = std.fs.cwd();
    const board_dir = try cwd.openDir(board_directory, .{});
    var board_file = board_dir.openFile(public_key, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.warn("Tried to get non-existant board", .{});
            try client.response.writeStatus(.not_found);
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

        try client.response.writeStatus(.not_found);
        return;
    };
    
    var board_buf: [Board.board_size]u8 = undefined;
    const board_len = board_reader.readAll(&board_buf) catch |err| {
        log.warn("Error reading board content: {} | Board = {s}", .{err, public_key});
        try client.response.writeStatus(.internal_server_error);
        return;
    };

    const board = Board.init(board_buf[0..board_len]) catch |err| {
        log.warn("Tried loading an invalid board: Err = {} | Board = {s}", .{err, public_key});
        try client.response.writeStatus(.not_found);
        return;
    };

    // Check if the board is newer than the 'If-Modified-Since' header, if the header was provided by
    // the client.
    if (client.request.findHeader("If-Modified-Since")) |if_modified| {
        // Parse the header value. If the provided value is not a valid timestamp, just abort
        // this check and pretend the header wasn't provided at all.
        if (Timestamp.parse(if_modified)) |last_modified_ts| {
            // The timestamp can't be invalid here because it would have been caught in the board
            // initialization above.
            const board_ts = board.getTimestamp() catch unreachable;
            if (board_ts.compare(last_modified_ts) <= 0) {
                // Board is older than if-modified-since, so the server should respond with 304
                try client.response.writeStatus(.not_modified);
                return;
            }
        } else |_| {}
    }

    try client.response.writeStatus(.ok);
    try client.response.writeHeader("Content-Type", "text/html;charset=utf-8");
    try client.response.writeHeader("Spring-Version", "83");
    try client.response.writeHeader("Spring-Signature", signature);
    try client.response.writeHeader("Content-Length", board_len);
    try client.response.writeBody(board_buf[0..board_len]);
}

fn createAndSendTestBoard(client: *Client) !void {
    const now_ts = Timestamp.now();

    var board_buffer: [128]u8 = undefined;
    const board_content = try std.fmt.bufPrint(&board_buffer, "<time datetime=\"{}\">", .{now_ts});

    const key_pair = try Ed25519.KeyPair.fromSecretKey(test_secret_key);

    var signature = try key_pair.sign(board_content, null);

    var sig_hex_buf: [128]u8 = undefined;
    const sig_hex = try std.fmt.bufPrint(&sig_hex_buf, "{}", .{std.fmt.fmtSliceHexLower(&signature.toBytes())});

    try client.response.writeStatus(.ok);
    try client.response.writeHeader("Content-Type", "text/html;charset=utf-8");
    try client.response.writeHeader("Spring-Version", "83");
    try client.response.writeHeader("Spring-Signature", sig_hex);
    try client.response.writeHeader("Content-Length", board_content.len);
    try client.response.writeBody(board_content);
}

/// PUT /{key}. Upload or replace a board under the given key. The request must include the board's signature,
/// and the signature must match the given key.
fn handlePutBoard(client: *Client, path: []const u8, board_directory: []const u8) !void {
    const public_key = path[1..];

    // Parse + validate the key part of the request path.
    var pub_key = getPublicKeyFromUri(path) catch {
        log.warn("Invalid public key", .{});
        try client.response.writeStatus(.forbidden);
        return;
    };
    
    // Make sure that the key hasn't been added to the denylist.
    if (try denylistContainsKey("denylist.txt", public_key)) {
        log.warn("Key belongs to denylist, board upload is forbidden", .{});
        try client.response.writeStatus(.forbidden);
        return;
    }
    
    // Make sure that the user actually sent a board in the request body
    const body = client.request.getBody();
    if (body.len == 0) {
        log.warn("No body sent in request", .{});
        try client.response.writeStatus(.bad_request);
        return;
    }

    // Make sure that a signature was provided and, if so, that it is the valid signature
    // for the board as given.
    const signature = client.request.findHeader("Spring-Signature") orelse {
        log.warn("No board signature provided", .{});
        try client.response.writeStatus(.bad_request);
        return;
    };

    // Validate the new board. If there are any validation errors then abort the upload and return
    // the proper status code.
    const board = validateIncomingBoard(body, signature, pub_key) catch |err| switch (err) {
        error.TooLarge => {
            log.warn("Client tried to upload jumbo board", .{});
            try client.response.writeStatus(.payload_too_large);
            return;
        },
        error.InvalidPublicKey, error.InvalidTimestamp => {
            log.warn("Board timestamp was invalid", .{});
            try client.response.writeStatus(.bad_request);
            return;
        },
        error.InvalidSignature => {
            log.warn("Board signature was invalid", .{});
            try client.response.writeStatus(.forbidden);
            return;
        },
        error.OutdatedTimestamp => {
            log.warn("Board already exists and existing timestamp is newer", .{});
            try client.response.writeStatus(.conflict);
            return;
        },
    };

    log.info("Creating board at boards/{s}", .{public_key});
    
    // const board_path_buf = getBoardPath("boards/", public_key);
    const cwd = std.fs.cwd();
    const board_dir = try cwd.openDir(board_directory, .{});
    var board_file = try board_dir.createFile(public_key, .{});
    defer board_file.close();

    var board_writer = board_file.writer();
    try board_writer.print("{s}\n", .{signature});
    try board_writer.writeAll(board.content[0..board.len]);
    
    try client.response.writeStatus(.created);
}

/// Given a URI like '/{key}', where 'key' is a hex string representing a public key,
/// try to parse the value into a valid public key.
fn getPublicKeyFromUri(uri: []const u8) !Ed25519.PublicKey {
    var pub_key = KeyPair.publicKeyFromHexString(uri[1..]) catch return error.InvalidKey;

    // Make sure that the key conforms to the Spring83 standard
    if (!KeyPair.isValid(pub_key.toBytes())) return error.InvalidKey;

    return pub_key;
}

/// Read the denylist and determine if the given public key is included.
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
