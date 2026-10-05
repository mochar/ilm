const std = @import("std");
const known_folders = @import("known-folders");
const ilm = @import("ilm");
const Core = @import("ilm").Core;
const iroh = @import("iroh");

const log = std.log.scoped(.cli);

const Command = enum { pair, info };

pub fn main(init: std.process.Init) !void {
    const data_path = (try known_folders.getPath(init.io, init.gpa, init.environ_map, .data)) orelse return error.FolderNotFound;
    defer init.gpa.free(data_path);
    // const data_path = "/home/mochar/tmp/ilm";

    var core = try Core.create(.{ .gpa = init.gpa, .io = init.io, .data_dir = data_path });
    defer core.destroy();
    core.setup() catch |err| log.err("Failed to setup core: {t}", .{err});

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
        if (std.meta.stringToEnum(Command, command)) |cmd| {
            switch (cmd) {
                .pair => {
                    const endpoint_id_hex = parser.next() orelse "1914aeae12e05b2e0b0bd1a81e17caa95795ed76bbd4bddedb5e801f96da42c3";
                    pair(&core.router, endpoint_id_hex) catch |err| log.err("Pair err: {t}", .{err});
                },
                .info => printInfo(core, stdout, init.arena.allocator()) catch {},
            }
        } else {
            try stdout.print("Unknown command\n", .{});
        }
        _ = try stdout.write("> ");
        try stdout.flush();
    }
}

fn printInfo(core: *Core, stdout: *std.Io.Writer, arena: std.mem.Allocator) !void {
    try stdout.print("Router status: ", .{});
    if (core.router.endpoint.checkOnline(.{})) {
        try stdout.print("Online\n", .{});
    } else |err| {
        try stdout.print("Offline! {t}\n", .{err});
    }

    try stdout.print("Peers:\n", .{});
    const peers = try ilm.p2p.peer.getAll(&core.db, arena);
    for (peers) |peer| {
        const peer_conn = core.router.connections.peers.getPtr(peer.id);
        try stdout.print("  - {s} {s}: {x} \n", .{ if (peer_conn == null) "○" else "●", peer.name, peer.id.bytes });
    }
}

fn pair(router: *ilm.p2p.Router, endpoint_id_hex: []const u8) !void {
    var endpoint_id_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&endpoint_id_bytes, endpoint_id_hex);
    const peer_id: ilm.p2p.Peer.Id = .{ .bytes = endpoint_id_bytes };
    var recv_buf: [512]u8 = undefined;
    const name = try ilm.p2p.protocols.PairProtocol.request(router, peer_id, &recv_buf);
    _ = name;
}
