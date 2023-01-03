const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const net = std.net;
const windows = std.os.windows;
const winsock = @import("./winsock.zig");

const Request = @import("./http/Request.zig");
const Response = @import("./http/Response.zig");

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
    reading,
    writing,
};

pub const WindowsClient = struct {
    socket: os.socket_t,
    request: Request,
    response: Response.FixedBufferWriter,
    buffer: [4096]u8 = undefined,
    len: usize = 0,
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

    pub fn deinit(client: *WindowsClient) void {
        // Shutdown the socket before closing it to ensure that nobody is currently using the socket
        switch (os.windows.ws2_32.shutdown(client.socket, 1)) {
            0 => {
                _ = os.windows.ws2_32.closesocket(client.socket);
            },
            os.windows.ws2_32.SOCKET_ERROR => switch (os.windows.ws2_32.WSAGetLastError()) {
                .WSAENOTSOCK => {
                    std.log.warn("Tried to close a handle that is not a socket: {*}\nRetrying...", .{client.socket});
                },
                else => {},
            },
            else => unreachable,
        }

        client.state = .idle;
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
        };

        // Init all clients to a mostly empty, but usable, state
        for (server.clients) |*client| {
            client.* = WindowsClient{
                .socket = undefined,
                .request = undefined,
                .response = undefined,
            };
        }

        const flags = os.windows.ws2_32.WSA_FLAG_OVERLAPPED | os.windows.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT;
        const socket = try os.windows.WSASocketW(@intCast(i32, address.any.family), @as(i32, os.SOCK.STREAM), @as(i32, os.IPPROTO.TCP), null, 0, flags);
        errdefer |err| {
            std.log.err("Error occurred while listening on address {}: {}", .{ address, err });
            os.windows.closesocket(socket) catch unreachable;
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
        return server;
    }

    pub fn deinit(server: *WindowsServer) void {
        os.closeSocket(server.socket);
        server.socket = undefined;
        server.listen_address = undefined;
    }

    pub fn accept(server: *WindowsServer) !*WindowsClient {
        const client_sock = try std.os.accept(server.socket, null, null, 0);
        if (server.findIdleClient()) |client| {
            _ = try windows.CreateIoCompletionPort(client_sock, server.io_port, undefined, 0);
            client.* = WindowsClient{
                .socket = client_sock,
                .request = undefined,
                .response = undefined,
            };
            return client;
        }

        return error.Busy;
    }

    pub fn getCompletion(server: *WindowsServer) !?*Client {
        var completion_key: usize = undefined;
        var overlapped: ?*windows.OVERLAPPED = undefined;

        var bytes_transferred = try winsock.getQueuedCompletionStatus(server.io_port, &completion_key, &overlapped, false);
        if (overlapped) |o| {
            var client = @fieldParentPtr(Client, "overlapped", o);
            client.len = @intCast(usize, bytes_transferred);
            return client;
        }

        return null;
    }

    fn findIdleClient(server: *WindowsServer) ?*Client {
        for (server.clients[0..]) |*client| {
            if (client.state == .idle) return client;
        }
        return null;
    }
};

const LinuxClient = struct {
    socket: os.socket_t,
    request: Request,
    response: Response.FixedBufferWriter,
    buffer: [4096]u8 = undefined,
    len: usize = 0,
    state: ClientState = .idle,

    io_uring: *std.os.linux.IO_Uring,

    pub fn deinit(client: *LinuxClient) void {
        std.os.closeSocket(client.socket);
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

        const socket_flags = std.os.SOCK.STREAM | std.os.SOCK.CLOEXEC | std.os.SOCK.NONBLOCK;
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

    pub fn accept(server: *LinuxServer) !*LinuxClient {
        const client_sock = try std.os.accept(server.socket, null, null, 0);
        if (server.findIdleClient()) |client| {
            client.* = LinuxClient{
                .socket = client_sock,
                .io_uring = &server.io_uring,
                .request = undefined,
                .response = undefined,
            };
            return client;
        }

        return error.Busy;
    }

    pub fn getCompletion(server: *LinuxServer) !?*Client {
        var cqes: [16]std.os.linux.io_uring_cqe = undefined;

        const count = try server.io_uring.copy_cqes(&cqes, 0);
        if (count == 0) return error.WouldBlock;
        for (cqes[0..count]) |cqe| {
            switch (cqe.err()) {
                .SUCCESS => {
                    var client = @intToPtr(?*LinuxClient, @intCast(usize, cqe.user_data)) orelse return null;
                    client.len = @intCast(usize, cqe.res);
                    return client;
                },
                else => {},
            }
        }

        return null;
    }

    fn findIdleClient(server: *LinuxServer) ?*Client {
        for (server.clients[0..]) |*client| {
            if (client.state == .idle) return client;
        }
        return null;
    }
};
