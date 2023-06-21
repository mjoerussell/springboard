const std = @import("std");

// @todo Validate mode. This mode should validate an input board and explain to the user what is wrong with it, if anything, in
//       easy-to-understand language.
// @todo Client mode. In this mode, springboard should act like a headless client, retrieving & validating boards from other
//       spring83 servers.

fn parseArguments(comptime ArgsDef: type, input_args: []const []const u8) !ArgsDef {
    if (@typeInfo(ArgsDef) != .Struct) {
        @compileError("Arguments expects a struct containing expected arguments.");
    }

    const PresentFlag = enum {
        present,
        missing_required,
        missing_optional,
    };

    comptime var flag_type = @typeInfo(struct {});

    comptime var flag_fields: [@typeInfo(ArgsDef).Struct.fields.len]std.builtin.Type.StructField = undefined;
    inline for (@typeInfo(ArgsDef).Struct.fields, 0..) |field, field_index| {
        flag_fields[field_index] = .{
            .name = field.name,
            .type = PresentFlag,
            .default_value = &PresentFlag.missing_required,
            .is_comptime = false,
            .alignment = @alignOf(PresentFlag),
        };
    }

    flag_type.Struct.fields = &flag_fields;

    const PresentFlags = @Type(flag_type);

    var args_result: ArgsDef = undefined;
    var args_present = PresentFlags{};

    var in_arg_index: usize = 0;
    while (in_arg_index < input_args.len) : (in_arg_index += 1) {
        inline for (@typeInfo(ArgsDef).Struct.fields) |arg_field| {
            if (argFieldCliEql(arg_field.name, input_args[in_arg_index])) {
                in_arg_index += 1;

                const in_arg_value = input_args[in_arg_index];
                @field(args_result, arg_field.name) = switch (@typeInfo(arg_field.type)) {
                    .Int => try std.fmt.parseInt(arg_field.type, in_arg_value, 10),
                    .Float => try std.fmt.parseFloat(arg_field.type, in_arg_value),
                    .Bool => blk: {
                        in_arg_index -= 1;
                        break :blk true;
                    },
                    else => in_arg_value,
                };

                @field(args_present, arg_field.name) = .present;
            }
        }
    }

    var is_missing_required = false;
    inline for (@typeInfo(PresentFlags).Struct.fields) |present_flag_field| {
        if (@field(args_present, present_flag_field.name) == .missing_required) {
            const arg_info = std.meta.fieldInfo(ArgsDef, std.meta.stringToEnum(std.meta.FieldEnum(ArgsDef), present_flag_field.name).?);

            if (arg_info.default_value) |default| {
                @field(args_result, present_flag_field.name) = @ptrCast(*const arg_info.type, @alignCast(@alignOf(arg_info.type), default)).*;
                @field(args_present, present_flag_field.name) = .present;
            } else if (@typeInfo(arg_info.type) == .Optional) {
                @field(args_present, present_flag_field.name) = .missing_optional;
            } else {
                std.log.err("Missing required field " ++ present_flag_field.name, .{});
                is_missing_required = true;
            }
        }
    }

    if (is_missing_required) {
        return error.MissingRequired;
    }

    return args_result;
}

fn argFieldCliEql(arg_field_name: []const u8, cli_input: []const u8) bool {
    const cli_start: usize = if (std.mem.startsWith(u8, cli_input, "--")) 2 else 0;

    for (arg_field_name, 0..) |afn_char, index| {
        const cli_char = cli_input[index + cli_start];
        if (cli_char == afn_char) continue;
        if (cli_char == '-' and afn_char == '_') continue;
        return false;
    }

    return true;
}

pub const Args = union(enum) {
    // @todo Help text
    server: ServerArgs,
    key: KeyArgs,
    sign: SignArgs,
    push: PushArgs,

    pub const ServerArgs = struct {
        // @todo Allow the user to specify the board TTL
        port: u16,
        board_dir: []const u8 = "boards",
    };

    pub const KeyArgs = struct {};

    pub const SignArgs = struct {
        board: []const u8,
        key_file: []const u8,
        append_timestamp: bool = false,
    };

    pub const PushArgs = struct {
        // @todo Parse port from server arg
        // @todo Allow user to specify a sub-path in the server arg to push boards to
        server: []const u8,
        port: u16,
        board: []const u8,
        key_file: []const u8,
    };

    pub fn init(args: [][]const u8) !Args {
        if (args.len < 2) return error.NoArgs;

        const args_type = args[1];

        inline for (std.meta.fields(Args)) |field| {
            if (std.mem.eql(u8, args_type, field.name)) {
                var initialized_args = try parseArguments(field.type, args[2..]);
                return @unionInit(Args, field.name, initialized_args);
            }
        }

        return error.InvalidOperation;
    }
};
