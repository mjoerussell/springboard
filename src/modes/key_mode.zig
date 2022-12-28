const std = @import("std");
const KeyPair = @import("../KeyPair.zig");

// @todo Provide options to generate keys without any additional user input, such as `springboard key --min-exp 7 --print`

/// Generate a new key that can be used to sign a Spring83 board. This key conforms to the Spring83 spec as described
/// in this document: https://github.com/robinsloan/spring-83/blob/main/draft-20220629.md#generating-conforming-keys.
///
/// The key generator will run until it finds a key that expires in the future, but not more than two years in the future
/// (keys are only valid within 2 years of their expiration). The user can then decide if they want to use that key.
/// If not, then the key generation will run again until another key is found.
///
/// Once a valid key is chosen, the user can choose to write the key to a file or to print to stdout. Keys that are written
/// to a file should be able to be used with sign mode without further modification.
pub fn run() !void {
    var stdout_writer = std.io.getStdOut().writer();
    var stdin_reader = std.io.getStdIn().reader();

    var input_buffer: [128]u8 = undefined;

    while (true) {
        const key_pair = try KeyPair.generate(8);

        const public_key_bytes = key_pair.public_key.toBytes();
        const key_expiration_ts = KeyPair.KeyMonthYear.fromKey(public_key_bytes) catch continue;

        try stdout_writer.print("Found a key that expires on {}/{}\n", .{key_expiration_ts.month, key_expiration_ts.year});
        try stdout_writer.writeAll("Use this key? (y/n): ");

        const input = try nextLine(stdin_reader, &input_buffer);
        if (std.ascii.eqlIgnoreCase(input, "y")) {
            const secret_key_bytes = key_pair.secret_key.toBytes();
            const fmt_secret_key = std.fmt.fmtSliceHexLower(&secret_key_bytes);
    
            try stdout_writer.writeAll("Save this key to a file? Enter filename to create, or hit 'Enter' to print instead: ");
    
            const filename = try nextLine(stdin_reader, &input_buffer);
            if (filename.len == 0) {
                try stdout_writer.print("{}\n", .{fmt_secret_key});
            } else {
                const cwd = std.fs.cwd();
                var key_file = try cwd.createFile(filename, .{});
                defer key_file.close();

                try key_file.writer().print("{}", .{fmt_secret_key});
            }

            return;
        }
    }
}

fn nextLine(reader: anytype, buffer: []u8) ![]const u8 {
    var maybe_line = try reader.readUntilDelimiterOrEof(buffer, '\n'); 
    if (maybe_line) |line| {
        if (@import("builtin").os.tag == .windows) {
            return std.mem.trimRight(u8, line, "\r");
        } else {
            return line;
        }
    } else {
        return buffer[0..0];
    }
}