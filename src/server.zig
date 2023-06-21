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

    fn zero(client: *WindowsClient) void {
        // 0-init read/write buffer
        for (&client.buffer) |*b| b.* = 0;
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
        for (&server.clients) |*client| {
            client.socket = try server.getSocket();
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

    pub fn deinitClient(server: *WindowsServer, client: *WindowsClient) void {
        _ = server;
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
    }

    pub fn recv(server: *WindowsServer, client: *WindowsClient) !void {
        _ = server;
        client.state = .reading;

        winsock.wsaRecv(client.socket, &client.buffer, &client.overlapped) catch |err| switch (err) {
            error.IoPending => return,
            else => return err,
        };
    }

    pub fn send(server: *WindowsServer, client: *WindowsClient) !void {
        _ = server;
        client.state = .writing;

        winsock.wsaSend(client.socket, client.buffer[0..client.len], &client.overlapped) catch |err| switch (err) {
            error.IoPending => return,
            else => return err,
        };
    }

    pub fn acceptClient(server: *WindowsServer, client: *WindowsClient) !void {
        client.zero();
        client.state = .accepting;

        winsock.acceptEx(server.socket, client.socket, &client.buffer, &client.len, &client.overlapped) catch |err| switch (err) {
            error.IoPending, error.ConnectionReset => {},
            else => {
                log.warn("Error occurred during acceptEx(): {}", .{err});
                return err;
            },
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

    fn getSocket(server: WindowsServer) !os.socket_t {
        const flags = os.windows.ws2_32.WSA_FLAG_OVERLAPPED;
        return try os.windows.WSASocketW(@intCast(i32, server.listen_address.any.family), @as(i32, os.SOCK.STREAM), @as(i32, os.IPPROTO.TCP), null, 0, flags);
    }
};

const LinuxClient = struct {
    socket: os.socket_t,
    request: Request,
    response: Response.FixedBufferWriter,

    address: os.sockaddr = undefined,
    address_len: os.socklen_t = @sizeOf(std.net.Address),
    buffer: [4096]u8 = undefined,
    len: usize = 0,
    start_ts: i64 = 0,
    state: ClientState = .idle,

    fn zero(client: *LinuxClient) void {
        client.* = .{
            .socket = undefined,
            .request = undefined,
            .response = undefined,
        };
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

        const flags = 0;
        var entries: u16 = 4096;
        server.io_uring = while (entries > 1) {
            if (std.os.linux.IO_Uring.init(@intCast(u13, entries), flags)) |ring| {
                log.info("Submission queue created with {} entries", .{entries});
                break ring;
            } else |err| switch (err) {
                error.SystemResources => {
                    entries /= 2;
                    continue;
                },
                else => return err,
            }
        };

        server.listen_address = address;

        const socket_flags = os.SOCK.STREAM;
        server.socket = try os.socket(address.any.family, socket_flags, os.IPPROTO.TCP);
        errdefer os.closeSocket(server.socket);

        var enable: u32 = 1;
        try std.os.setsockopt(server.socket, os.SOL.SOCKET, os.SO.REUSEADDR, std.mem.asBytes(&enable));

        var socklen = address.getOsSockLen();
        try os.bind(server.socket, &address.any, socklen);
        try os.listen(server.socket, 128);
        try os.getsockname(server.socket, &server.listen_address.any, &socklen);

        for (&server.clients) |*client| {
            try server.acceptClient(client);
        }

        _ = try server.io_uring.submit();

        return server;
    }

    pub fn deinit(server: *LinuxServer) void {
        os.closeSocket(server.socket);
        server.socket = undefined;
        server.listen_address = undefined;
    }

    pub fn deinitClient(server: *LinuxServer, client: *LinuxClient) void {
        client.state = .disconnecting;
        _ = server.io_uring.close(@intCast(u64, @ptrToInt(client)), client.socket) catch |err| {
            std.log.err("Error submiting SQE for close(): {}", .{err});
            return;
        };
        _ = server.io_uring.submit() catch |err| {
            log.err("Error while trying to close client: {}", .{err});
        };
        const end_ts = std.time.microTimestamp();
        const duration = end_ts - client.start_ts;
        log.info("Request completed in {}ms", .{@divFloor(duration, std.time.us_per_ms)});
    }

    pub fn recv(server: *LinuxServer, client: *LinuxClient) !void {
        client.state = .reading;

        const flags = 0;

        _ = try server.io_uring.recv(@intCast(u64, @ptrToInt(client)), client.socket, .{ .buffer = &client.buffer }, flags);
    }

    pub fn send(server: *LinuxServer, client: *LinuxClient) !void {
        client.state = .writing;

        const flags = 0;

        _ = try server.io_uring.send(@intCast(u64, @ptrToInt(client)), client.socket, client.buffer[0..client.len], flags);
    }

    pub fn acceptClient(server: *LinuxServer, client: *LinuxClient) !void {
        client.zero();
        client.state = .accepting;
        const flags = os.SOCK.CLOEXEC | os.SOCK.NONBLOCK;

        _ = server.io_uring.accept(@intCast(u64, @ptrToInt(client)), server.socket, null, null, flags) catch |err| {
            log.err("Error while trying to accept client: {}", .{err});
            return err;
        };
    }

    pub fn getCompletions(server: *LinuxServer, clients: []*Client) !usize {
        var client_count: usize = 0;

        _ = server.io_uring.submit() catch |err| {
            log.err("Error submitting SQEs: {}", .{err});
            return err;
        };

        // @todo Even though the user is giving us a slice of clients to fetch, we're still capping the max at 16
        var cqes: [16]std.os.linux.io_uring_cqe = undefined;
        const count = server.io_uring.copy_cqes(&cqes, 1) catch |err| {
            log.err("Error while copying CQEs: {}", .{err});
            return err;
        };
        if (count == 0) return error.WouldBlock;
        for (cqes[0..count]) |cqe| {
            var client = @intToPtr(?*LinuxClient, @intCast(usize, cqe.user_data)) orelse continue;
            switch (cqe.err()) {
                .SUCCESS => {
                    if (client.state == .accepting) {
                        client.socket = cqe.res;
                    } else {
                        client.len = @intCast(usize, cqe.res);
                    }
                    clients[client_count] = client;
                    client_count += 1;
                },
                .AGAIN => {
                    if (client.state == .accepting) {
                        try server.acceptClient(client);
                    }
                },
                else => |err| {
                    log.err("getCompletion error: {} (during state {})", .{ err, client.state });
                },
            }
        }

        return client_count;
    }
};
