const std = @import("std");
const known_folders = @import("known-folders");
const ilm = @import("ilm");
const Core = @import("ilm").Core;
const iroh = @import("iroh");

pub fn main(init: std.process.Init) !void {
    const data_path = (try known_folders.getPath(init.io, init.gpa, init.environ_map, .data)) orelse return error.FolderNotFound;
    defer init.gpa.free(data_path);

    var core = try Core.init(init.gpa, init.io, data_path, .{ .spawn_p2p_thread = true });
    defer core.deinit();

    // const secret_key = iroh.SecretKey.generate();
    // defer secret_key.deinit();
    // std.log.info("Secret key hex: {s}", .{secret_key.asHex()});

    var read_buf: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &read_buf);
    const stdin = &stdin_reader.interface;

    var write_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &write_buf);
    const stdout = &stdout_writer.interface;

    _ = try stdout.write("> ");
    try stdout.flush();

    while (try stdin.takeDelimiter('\n')) |input| {
        var parser = std.mem.splitScalar(u8, input, ' ');
        const command = parser.first();
        if (std.meta.stringToEnum(enum { connect }, command)) |cmd| {
            switch (cmd) {
                .connect => {
                    const endpoint_id = parser.next() orelse core.p2p.endpoint.state.online.id;
                    connect(endpoint_id, init.gpa) catch {};
                },
            }
        } else {
            try stdout.print("Unknown command\n", .{});
        }
        _ = try stdout.write("> ");
        try stdout.flush();
    }
}

fn connect(endpoint_id: []const u8, gpa: std.mem.Allocator) !void {
    const public_key: iroh.PublicKey = try .fromEndpointId(endpoint_id);
    defer public_key.deinit();

    const addr: iroh.EndpointAddr = .fromPublicKey(&public_key);
    defer addr.deinit();

    var endpoint: iroh.Endpoint = try .init(gpa, ilm.P2p.ALPN);
    // var endpoint: iroh.Endpoint = .init(gpa, ilm.P2p.ALPN) catch |err| {
    //     std.log.err("Endpoint failed: {t}", .{err});
    //     return err;
    // };
    defer endpoint.deinit();

    var conn = try endpoint.connect(&addr);
    defer conn.deinit();
}
