const std = @import("std");

pub const Args = union(enum) {
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