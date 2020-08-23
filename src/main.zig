const std = @import("std");
const soundio = @import("soundio.zig");
const sndfile = @import("sndfile");

pub fn main() anyerror!u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    var allocator = &gpa.allocator;

    var args_it = std.process.args();
    defer args_it.deinit();

    std.debug.assert(args_it.skip() == true);

    const host = try (args_it.next(allocator) orelse @panic("expected host arg"));
    defer allocator.free(host);

    const path = try (args_it.next(allocator) orelse @panic("expected path arg"));
    defer allocator.free(path);
    std.debug.warn("path: {}\n", .{path});

    var soundio_opt = soundio.c.soundio_create();
    if (soundio_opt == null) {
        std.debug.warn("libsoundio fail: out of memory\n", .{});
        return 1;
    }

    // var info = std.mem.zeroes(sndfile.Info);
    // const f = try sndfile.SoundFile.open(allocator, "test.wav", .Read, &info);

    // var soundio_state = soundio_opt.?;
    // defer soundio.c.soundio_destroy(soundio_state);
    // std.debug.warn("initialized libsoundio\n", .{});

    var it = std.mem.split(host, ":");
    const actual_host = it.next().?;

    var actual_port: u16 = undefined;
    if (it.next()) |port_str| {
        actual_port = try std.fmt.parseInt(u16, port_str, 10);
    } else {
        actual_port = 80;
    }
    std.debug.warn("host: {}\n", .{actual_host});
    std.debug.warn("port: {}\n", .{actual_port});
    std.debug.warn("path: {}\n", .{path});

    const sock = try std.net.tcpConnectToHost(allocator, actual_host, actual_port);
    defer sock.close();

    return 0;
}
