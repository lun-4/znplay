const std = @import("std");
const soundio = @import("soundio.zig");
const sndfile = @import("sndfile");
const c = sndfile.c;

const VirtualContext = struct {
    fd: std.os.fd_t,
    write_error: ?std.os.SendError = null,
    read_error: ?std.os.ReadError = null,
};

fn virtualWrite(data_ptr: ?*const c_void, bytes: sndfile.c.sf_count_t, user_ptr: ?*c_void) callconv(.C) sndfile.c.sf_count_t {
    const ctx = @ptrCast(*VirtualContext, @alignCast(@alignOf(VirtualContext), user_ptr));
    const data = @ptrCast([*]const u8, @alignCast(@alignOf(u8), data_ptr));
    const sliced = data[0..@intCast(usize, bytes)];

    ctx.write_error = null;
    const sent_bytes = std.os.sendto(ctx.fd, sliced, std.os.MSG_NOSIGNAL, null, 0) catch |err| {
        ctx.write_error = err;
        return @as(i64, 0);
    };

    return @intCast(i64, sent_bytes);
}

fn virtualRead(data_ptr: ?*c_void, bytes: sndfile.c.sf_count_t, user_ptr: ?*c_void) callconv(.C) sndfile.c.sf_count_t {
    const ctx = @ptrCast(*VirtualContext, @alignCast(@alignOf(VirtualContext), user_ptr));
    const data = @ptrCast([*]u8, @alignCast(@alignOf(u8), data_ptr));
    var buf = data[0..@intCast(usize, bytes)];

    ctx.read_error = null;
    const read_bytes = std.os.read(ctx.fd, buf) catch |err| {
        ctx.read_error = err;
        return @as(i64, 0);
    };

    return @intCast(i64, read_bytes);
}

// make those functions return whatever. libsndfile wants them, even though
// it won't care about them when writing. i should fix it upstream.
fn virtualLength(_: ?*c_void) callconv(.C) sndfile.c.sf_count_t {
    return @intCast(i64, 100000000000);
}

fn virtualSeek(offset: sndfile.c.sf_count_t, whence: c_int, user_data: ?*c_void) callconv(.C) sndfile.c.sf_count_t {
    return offset;
}

fn virtualTell(user_data: ?*c_void) callconv(.C) sndfile.c.sf_count_t {
    return 0;
}

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

    try sock.writer().print(
        "GET {} HTTP/1.1\r\n" ++
            "Host: http://{}\r\n" ++
            "\r\n\r\n",
        .{ path, host },
    );

    var buf: [128]u8 = undefined;
    const data = try sock.read(&buf);
    std.debug.warn("data: {}\n", .{data});

    // setup libsndfile based on sock
    var virtual = sndfile.c.SF_VIRTUAL_IO{
        .get_filelen = virtualLength,
        .seek = virtualSeek,
        .read = virtualRead,
        .write = virtualWrite,
        .tell = virtualTell,
    };

    var virtual_ctx = VirtualContext{ .fd = sock.handle };
    var info = std.mem.zeroes(sndfile.Info);
    var file = sndfile.c.sf_open_virtual(
        &virtual,
        @enumToInt(sndfile.Mode.Read),
        @ptrCast(*sndfile.c.SF_INFO, &info),
        @ptrCast(*c_void, &virtual_ctx),
    );

    const status = sndfile.c.sf_error(file);
    if (status != 0) {
        const err = std.mem.spanZ(sndfile.c.sf_error_number(status));
        std.debug.warn("failed to open read fd {} ({})\n", .{ sock.handle, err });

        var logbuf: [10 * 1024]u8 = undefined;
        const count = sndfile.c.sf_command(
            file,
            sndfile.c.SFC_GET_LOG_INFO,
            &logbuf,
            10 * 1024,
        );
        const msgs = logbuf[0..@intCast(usize, count)];
        std.debug.warn("libsndfile log {}\n", .{msgs});

        return 1;
    }

    var audio_buf: [32]f64 = undefined;
    while (true) {
        const bytes = sndfile.c.sf_readf_double(file, &audio_buf, 32);
        if (bytes == 0) {
            std.debug.warn("finished read\n", .{});
            break;
        }

        std.debug.warn("read {}\n", .{bytes});
    }

    return 0;
}
