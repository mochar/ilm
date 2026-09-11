const std = @import("std");
const known_folders = @import("known-folders");
const Core = @import("ilm").Core;

pub fn main(init: std.process.Init) !void {
    const data_path = (try known_folders.getPath(init.io, init.gpa, init.environ_map, .data)) orelse return error.FolderNotFound;
    var core = try Core.init(init.gpa, init.io, data_path, .{});
    defer core.deinit();

    var read_buf: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &read_buf);

    var write_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &write_buf);

    _ = try stdout_writer.interface.write("> ");
    try stdout_writer.flush();

    while (try stdin_reader.interface.takeDelimiter('\n')) |input| {
        _ = input;
        // if (std.meta.stringToEnum(enum { concepts, }, input)) |cmd| {
        //     switch (cmd) {
        //         .concepts => _ = core.increment(),
        //     }
        // } else {
        //     try stdout_writer.interface.print("Unknown command\n", .{});
        // }
        _ = try stdout_writer.interface.write("> ");
        try stdout_writer.flush();
    }
}
