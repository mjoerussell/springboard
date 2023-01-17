const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const net = std.net;
const windows = std.os.windows;
const winsock = @import("./winsock.zig");

const Request = @import("./http/Request.zig");
const Response = @import("./http/Response.zig");

const log = std.log.scoped(.server);

// @todo Better async handling. Right now there's no way to create a sequence of async events on a single client.
//       The read and write parts much each be one-shot operations.

// @todo Mac implementation
pub const Server = switch (builtin.os.tag) {
    .windows => WindowsServer,
    .linux => LinuxServer,
    else => @compileError("Platform not supported"),
};

pub const Client = switch (builtin.os.tag) {
    .windows => WindowsClient,
    .linux => LinuxClient,
    else => @compileError("Platform not supported"),
};

pub const ClientState = enum {
    idle,
    accepting,
    reading,
    writing,
    disconnecting,
};

pub const WindowsClient = struct {
    socket: os.socket_t,
    request: Request,
    response: Response.FixedBufferWriter,
    buffer: [4096]u8 = undefined,
    len: usize = 0,
    start_ts: i64 = 0,
    state: ClientState = .idle,

    overlapped: windows.OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{
            .DUMMYSTRUCTNAME = .{
                .Offset = 0,
                .OffsetHigh = 0,
            },
        },
        .hEvent = null,
    },

    // fn reset(client: *WindowsClient, new_socket: ?os.socket_t) void {
    fn zero(client: *WindowsClient) void {
        // 0-init read/write buffer
        for (client.buffer) |*b| b.* = 0;
        // if (new_socket) |socket| {
        //     client.socket = socket;
        //     client.state = .accepting;
        // } else {
        //     // client.socket = undefined;
        //     client.state = .idle;
        // }
        client.len = 0;
        client.state = .idle;
        client.request = undefined;
        client.response = undefined;
        client.overlapped = .{
            .Internal = 0,
            .InternalHigh = 0,
            .DUMMYUNIONNAME = .{
                .DUMMYSTRUCTNAME = .{
                    .Offset = 0,
                    .OffsetHigh = 0,
                },
            },
            .hEvent = null,
        };
    }

    pub fn deinit(client: *WindowsClient) void {
        // os.closeSocket(client.socket);
        winsock.disconnectEx(client.socket, &client.overlapped, true) catch |err| {
            switch (err) {
                error.IoPending => {
                    // Disconnect in progress, socket can be reused after it's completed
                    client.state = .disconnecting;
                },
                else => {
                    log.err("Error disconnecting client: {}", .{err});

                    // Since we couldn't gracefully disconnect the client, we'll shut down its socket and re-create
                    // it.
                    os.closeSocket(client.socket);
                    client.zero();
                },
            }

            const end_ts = std.time.microTimestamp();
            const duration = @intToFloat(f64, end_ts - client.start_ts) / std.time.us_per_ms;
            std.log.info("Request completed in {d:4}ms", .{duration});
            return;
        };
        // client.state = .idle;
    }

    pub fn recv(client: *WindowsClient) !void {
        client.state = .reading;

        winsock.wsaRecv(client.socket, &client.buffer, &client.overlapped) catch |err| switch (err) {
            error.IoPending => return,
            else => return err,
        };
    }

    pub fn send(client: *WindowsClient) !void {
        client.state = .writing;

        log.debug("Client: {*}", .{client});
        log.debug("Writing {} bytes from buffer at {*}", .{ client.len, &client.buffer });
        winsock.wsaSend(client.socket, client.buffer[0..client.len], &client.overlapped) catch |err| switch (err) {
            error.IoPending => return,
            else => return err,
        };
    }
};

const WindowsServer = struct {
    socket: os.socket_t = undefined,
    clients: [256]WindowsClient = undefined,
    client_count: usize = 0,
    listen_address: net.Address = undefined,
    io_port: os.windows.HANDLE,

    pub fn init(address: net.Address) !WindowsServer {
        var server = WindowsServer{
            .io_port = try windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, undefined, undefined),
            .listen_address = address,
        };

        const socket = try server.getSocket();
        errdefer |err| {
            std.log.err("Error occurred while listening on address {}: {}", .{ address, err });
            os.closeSocket(socket);
        }

        var io_mode: u32 = 1;
        _ = os.windows.ws2_32.ioctlsocket(socket, os.windows.ws2_32.FIONBIO, &io_mode);

        server.socket = socket;
        errdefer server.deinit();

        var socklen = address.getOsSockLen();
        try os.bind(socket, &address.any, socklen);
        try os.listen(socket, 128);
        try os.getsockname(socket, &server.listen_address.any, &socklen);

        _ = try os.windows.CreateIoCompletionPort(socket, server.io_port, undefined, 0);

        // Init all clients to a mostly empty, but usable, state
        for (server.clients) |*client| {
            // client.zero();
            client.socket = try server.getSocket();
            // client.* = WindowsClient{
            //     // .socket = try server.getSocket(),
            //     .socket = undefined,
            //     .request = undefined,
            //     .response = undefined,
            // };
            _ = try windows.CreateIoCompletionPort(client.socket, server.io_port, undefined, 0);
            try server.acceptClient(client);
        }

        return server;
    }

    pub fn deinit(server: *WindowsServer) void {
        os.closeSocket(server.socket);
        server.socket = undefined;
        server.listen_address = undefined;
    }

    pub fn accept(server: *WindowsServer) !void {
        var client = server.findIdleClient() orelse return error.Busy;
        // client.* = .{
        //     .socket = try server.getSocket(),
        //     .state = .accepting,
        //     .request = undefined,
        //     .response = undefined,
        // };
        try server.acceptClient(client);
    }

    pub fn reuseClient(server: *WindowsServer, client: *WindowsClient) !void {
        client.deinit();
        try server.acceptClient(client);
    }

    pub fn acceptClient(server: *WindowsServer, client: *WindowsClient) !void {
        // client.reset(null);
        client.zero();
        errdefer client.deinit();
        client.state = .accepting;

        // _ = try windows.CreateIoCompletionPort(client.socket, server.io_port, undefined, 0);
        winsock.acceptEx(server.socket, client.socket, &client.buffer, &client.len, &client.overlapped) catch |err| switch (err) {
            error.IoPending => log.debug("Accept successfully posted and pending completion", .{}),
            error.ConnectionReset => log.debug("Peer terminated connection before accept could complete", .{}),
            else => log.warn("Error occurred during acceptEx(): {}", .{err}),
        };
    }

    pub fn getCompletions(server: *WindowsServer, clients: []*Client) !usize {
        var overlapped_entries: [16]windows.OVERLAPPED_ENTRY = undefined;
        var client_count: usize = 0;
        var entries_removed = try winsock.getQueuedCompletionStatusEx(server.io_port, &overlapped_entries, null, false);
        for (overlapped_entries[0..entries_removed]) |entry| {
            var client = @fieldParentPtr(Client, "overlapped", entry.lpOverlapped);
            client.len = @intCast(usize, entry.dwNumberOfBytesTransferred);
            if (client.state == .accepting) {
                os.setsockopt(client.socket, os.windows.ws2_32.SOL.SOCKET, os.windows.ws2_32.SO.UPDATE_ACCEPT_CONTEXT, &std.mem.toBytes(server.socket)) catch |err| {
                    std.log.err("Error during setsockopt: {}", .{err});
                };
            }
            clients[client_count] = client;
            client_count += 1;
        }

        return client_count;
    }

    fn findIdleClient(server: *WindowsServer) ?*Client {
        for (server.clients[0..]) |*client| {
            // std.log.debug("Client state: {}", .{client.state});
            if (client.state == .idle) return client;
        }
        return null;
    }

    fn getSocket(server: WindowsServer) !os.socket_t {
        // const flags = os.windows.ws2_32.WSA_FLAG_OVERLAPPED | os.windows.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT;
        const flags = os.windows.ws2_32.WSA_FLAG_OVERLAPPED;
        return try os.windows.WSASocketW(@intCast(i32, server.listen_address.any.family), @as(i32, os.SOCK.STREAM), @as(i32, os.IPPROTO.TCP), null, 0, flags);
    }
};

const LinuxClient = struct {
    socket: os.socket_t,
    address: os.sockaddr = undefined,
    address_len: os.socklen_t = @sizeOf(std.net.Address),
    request: Request,
    response: Response.FixedBufferWriter,
    buffer: [4096]u8 = undefined,
    len: usize = 0,
    start_ts: i64 = 0,
    state: ClientState = .idle,

    io_uring: *std.os.linux.IO_Uring,

    pub fn deinit(client: *LinuxClient) void {
        client.state = .idle;
        std.os.closeSocket(client.socket);
        const end_ts = std.time.microTimestamp();
        const duration = end_ts - client.start_ts;
        std.log.info("Request completed in {}us", .{duration});
    }

    pub fn recv(client: *LinuxClient) !void {
        client.state = .reading;

        const flags = std.os.linux.IOSQE_ASYNC;
        _ = try client.io_uring.recv(@intCast(u64, @ptrToInt(client)), client.socket, .{ .buffer = &client.buffer }, flags);
        _ = try client.io_uring.submit();
    }

    pub fn send(client: *LinuxClient) !void {
        client.state = .writing;

        const flags = std.os.linux.IOSQE_ASYNC;
        _ = try client.io_uring.send(@intCast(u64, @ptrToInt(client)), client.socket, client.buffer[0..client.len], flags);
        _ = try client.io_uring.submit();
    }
};

const LinuxServer = struct {
    socket: os.socket_t = undefined,
    clients: [256]LinuxClient = undefined,
    client_count: usize = 0,
    listen_address: net.Address = undefined,
    io_uring: std.os.linux.IO_Uring,

    pub fn init(address: net.Address) !LinuxServer {
        var server: LinuxServer = undefined;

        var entries: u16 = 4096;
        server.io_uring = while (entries > 1) {
            if (std.os.linux.IO_Uring.init(@intCast(u13, entries), 0)) |ring| {
                break ring;
            } else |err| switch (err) {
                error.SystemResources => {
                    entries /= 2;
                    continue;
                },
                else => return err,
            }
        };

        for (server.clients) |*client| {
            client.* = LinuxClient{
                .socket = undefined,
                .io_uring = undefined,
                .request = undefined,
                .response = undefined,
            };
        }

        server.listen_address = address;

        const socket_flags = std.os.SOCK.STREAM | std.os.SOCK.NONBLOCK;
        server.socket = try std.os.socket(address.any.family, socket_flags, std.os.IPPROTO.TCP);
        errdefer os.closeSocket(server.socket);

        var socklen = address.getOsSockLen();
        try os.bind(server.socket, &address.any, socklen);
        try os.listen(server.socket, 128);
        try os.getsockname(server.socket, &server.listen_address.any, &socklen);

        return server;
    }

    pub fn deinit(server: *LinuxServer) void {
        os.closeSocket(server.socket);
        server.socket = undefined;
        server.listen_address = undefined;
    }

    pub fn accept(server: *LinuxServer) !void {
        var client = server.findIdleClient() orelse return error.Busy;
        client.* = LinuxClient{
            .io_uring = &server.io_uring,
            .state = .accepting,
            .socket = undefined,
            .request = undefined,
            .response = undefined,
        };

        _ = try server.io_uring.accept(@intCast(u64, @ptrToInt(client)), server.socket, &client.address, &client.address_len, 0);
        _ = try server.io_uring.submit();
    }

    pub fn getCompletions(server: *LinuxServer, clients: []*Client) !usize {
        var client_count: usize = 0;

        // @todo Even though the user is giving us a slice of clients to fetch, we're still capping the max at 16
        var cqes: [16]std.os.linux.io_uring_cqe = undefined;
        const count = try server.io_uring.copy_cqes(&cqes, 16);
        if (count == 0) return error.WouldBlock;
        for (cqes[0..count]) |cqe| {
            switch (cqe.err()) {
                .SUCCESS => {
                    var client = @intToPtr(?*LinuxClient, @intCast(usize, cqe.user_data)) orelse continue;
                    if (client.state == .accepting) {
                        client.socket = cqe.res;
                    } else {
                        client.len = @intCast(usize, cqe.res);
                    }
                    clients[client_count] = client;
                    client_count += 1;
                },
                .AGAIN => {
                    var client = @intToPtr(?*LinuxClient, @intCast(usize, cqe.user_data));
                    if (client) |c| {
                        if (c.state == .accepting) {
                            c.state = .idle;
                            try server.accept();
                        }
                    }
                },
                else => |err| {
                    std.log.err("getCompletion error: {}", .{err});
                },
            }
        }

        return client_count;
    }

    fn findIdleClient(server: *LinuxServer) ?*Client {
        for (server.clients[0..]) |*client| {
            if (client.state == .idle) return client;
        }
        return null;
    }
};
