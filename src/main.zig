const std = @import("std");
const soundio = @import("soundio.zig");
const sndfile = @import("sndfile");
const hzzp = @import("hzzp");
const c = sndfile.c;

const VirtualContext = struct {
    fd: std.os.fd_t,
    cursor: usize = 0,
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
        std.debug.warn("read FAIL {}\n", .{err});
        ctx.read_error = err;
        return @as(i64, 0);
    };

    std.debug.warn("os.read {}\n", .{
        read_bytes,
    });
    ctx.cursor += read_bytes;

    return @intCast(i64, read_bytes);
}

fn virtualLength(_: ?*c_void) callconv(.C) sndfile.c.sf_count_t {
    std.debug.warn("length\n", .{});
    return @intCast(i64, 0xffffff2);
}

fn virtualSeek(offset: sndfile.c.sf_count_t, whence: c_int, user_data: ?*c_void) callconv(.C) sndfile.c.sf_count_t {
    std.debug.warn("seek {} {}\n", .{ offset, whence });
    return offset;
}

fn virtualTell(user_ptr: ?*c_void) callconv(.C) sndfile.c.sf_count_t {
    const ctx = @ptrCast(*VirtualContext, @alignCast(@alignOf(VirtualContext), user_ptr));
    std.debug.warn("tell {}\n", .{ctx.cursor});
    return @intCast(sndfile.c.sf_count_t, ctx.cursor);
    // return 0;
}

const Result = struct {
    state: *soundio.c.SoundIo,
    device: *soundio.c.SoundIoDevice,
    stream: *soundio.c.SoundIoOutStream,
};

fn initSoundIo() !Result {
    var soundio_opt = soundio.c.soundio_create();
    if (soundio_opt == null) {
        std.debug.warn("libsoundio fail: out of memory\n", .{});
        return error.OutOfMemory;
    }

    var soundio_state = soundio_opt.?;
    var err = soundio.c.soundio_connect(soundio_state);
    if (err != 0) {
        const msg = std.mem.spanZ(soundio.c.soundio_strerror(err));
        std.debug.warn("error connecting: {}\n", .{msg});
        return error.ConnectError;
    }

    _ = soundio.c.soundio_flush_events(soundio_state);

    const default_out_device_index = soundio.c.soundio_default_output_device_index(soundio_state);
    if (default_out_device_index < 0) {
        std.debug.warn("no output device connected\n", .{});
        return error.NoDevice;
    }

    var device_opt = soundio.c.soundio_get_output_device(soundio_state, default_out_device_index);
    if (device_opt == null) {
        std.debug.warn("failed to get output device: out of memory\n", .{});
        return error.OutOfMemory;
    }

    var device = device_opt.?;

    std.debug.warn("output device: {}\n", .{device.*.name});

    var outstream_opt = soundio.c.soundio_outstream_create(device);
    if (outstream_opt == null) {
        std.debug.warn("failed to get output stream: out of memory\n", .{});
        return error.OutOfMemory;
    }

    return Result{
        .state = soundio_state,
        .device = device,
        .stream = outstream_opt.?,
    };
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

    var result = try initSoundIo();
    defer {
        soundio.c.soundio_outstream_destroy(result.stream);
        soundio.c.soundio_device_unref(result.device);
        soundio.c.soundio_destroy(result.state);
    }
    std.debug.warn("initialized libsoundio\n", .{});

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

    var read_buffer: [128]u8 = undefined;

    var client = hzzp.base.Client.create(&read_buffer, sock.reader(), sock.writer());
    try client.writeHead("GET", path);
    try client.writeHeaderValueFormat("Host", "http://{s}", .{host});

    var status_event = (try client.readEvent()).?;
    std.testing.expect(status_event == .status);
    std.debug.warn("http: got status: {}\n", .{status_event.status.code});

    while (true) {
        const event = (try client.readEvent()).?;
        if (event != .head_complete) {
            std.debug.warn("http: got head_complete\n", .{});
            break;
        }
        std.testing.expect(event == .header);
        std.debug.warn("http: got header: {}: {}\n", .{ event.header.name, event.header.value });
    }

    var buf: [50]u8 = undefined;
    const off1 = try sock.read(&buf);
    std.debug.warn("data: {}\n", .{buf[0..off1]});

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
    defer {
        _ = sndfile.c.sf_close(file);
    }

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

    var audio_buf: [1024]f64 = undefined;
    while (true) {
        std.debug.warn("==reading\n", .{});
        const frames = sndfile.c.sf_readf_double(file, &audio_buf, 1024);
        std.debug.warn("read {} frames\n", .{frames});
        if (frames == 0) {
            if (virtual_ctx.read_error) |err| {
                std.debug.warn("read error {}\n", .{err});
            } else {
                std.debug.warn("finished read\n", .{});
            }

            break;
        }

        const actual_frames = audio_buf[0..@intCast(usize, frames)];
    }

    return 0;
}
