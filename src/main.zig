const std = @import("std");
const soundio = @import("soundio.zig");
const sndfile = @import("sndfile");
const hzzp = @import("hzzp");

const ao = struct {
    pub const c = @cImport({
        @cInclude("ao/ao.h");
    });
};

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
    var backend_count = @intCast(usize, soundio.c.soundio_backend_count(soundio_state));
    var i: usize = 0;
    while (i < backend_count) : (i += 1) {
        var backend = soundio.c.soundio_get_backend(soundio_state, @intCast(c_int, i));
        std.debug.warn("backend {} {}\n", .{ i, backend });
    }

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

const Samples = std.fifo.LinearFifo(f32, .Dynamic);
var samples: Samples = undefined;

// I'm going to assume PulseAudio and so, assume frame_count_min == 0, and you
// can't stop me.
fn write_callback(
    stream: [*c]soundio.c.SoundIoOutStream,
    frame_count_min: c_int,
    frame_count_max: c_int,
) callconv(.C) void {
    std.debug.warn("write_callback(min={} max={})\n", .{ frame_count_min, frame_count_max });
    var areas: [*c]soundio.c.SoundIoChannelArea = undefined;

    const available_samples = samples.readableLength();
    if (available_samples == 0) {
        std.debug.warn("--> no frames\n", .{});
        return;
    }

    const wanted_samples = std.math.min(available_samples, @intCast(usize, frame_count_max));

    var allowed_write_c: i64 = @intCast(i64, wanted_samples);
    var err = soundio.c.soundio_outstream_begin_write(
        stream,
        &areas,
        @ptrCast(*c_int, &allowed_write_c),
    );
    if (err != 0) {
        const msg = std.mem.spanZ(soundio.c.soundio_strerror(err));
        std.debug.warn("unrecoverable stream error (begin): {}\n", .{msg});
        std.os.exit(1);
    }

    const allowed_write = @intCast(usize, allowed_write_c);

    var write_buffer = samples.allocator.alloc(
        f32,
        allowed_write,
    ) catch @panic("out of memory");
    defer samples.allocator.free(write_buffer);
    const actually_read = samples.read(write_buffer);
    std.debug.assert(actually_read == allowed_write);

    std.debug.warn("got {} write frames\n", .{actually_read});
    std.debug.warn("{} frames allowed to write\n", .{allowed_write});
    var frames_to_write = write_buffer[0..allowed_write];

    var layout = &stream.*.layout;
    var frame: usize = 0;
    while (frame < allowed_write) : (frame += 1) {
        if (frame % 300 == 0) {
            std.debug.warn("frame: {} read: {}\n", .{ frame, allowed_write });
        }

        var channel: usize = 0;
        while (channel < layout.channel_count) : (channel += 1) {
            var wanted_ptr = @ptrCast([*c]f32, @alignCast(@alignOf(f32), areas[channel].ptr));

            // prevent invalid access
            if (frame > (frames_to_write.len - 1)) {
                wanted_ptr.* = 0;
            } else {
                wanted_ptr.* = frames_to_write[frame];
            }
        }
    }

    err = soundio.c.soundio_outstream_end_write(stream);
    if (err != 0) {
        if (err == soundio.c.SoundIoErrorUnderflow)
            return;

        const msg = std.mem.spanZ(soundio.c.soundio_strerror(err));
        std.debug.warn("unrecoverable stream error (end): {}\n", .{msg});
        std.os.exit(1);
    }

    std.debug.warn("write_callback(...) = done\n", .{});
}

fn initStream(stream: *soundio.c.SoundIoOutStream) !void {
    var err = soundio.c.soundio_outstream_open(stream);
    if (err != 0) {
        const msg = std.mem.spanZ(soundio.c.soundio_strerror(err));
        std.debug.warn("unable to open device ({}): {}\n", .{ err, msg });
        return error.OpenError;
    }

    if (stream.layout_error != 0) {
        const msg = std.mem.spanZ(soundio.c.soundio_strerror(stream.layout_error));
        std.debug.warn("unable to set channel layout: {}\n", .{msg});
        return error.LayoutError;
    }

    err = soundio.c.soundio_outstream_start(stream);
    if (err != 0) {
        const msg = std.mem.spanZ(soundio.c.soundio_strerror(err));
        std.debug.warn("unable to start device: {}\n", .{msg});
        return error.StartError;
    }
}

pub fn main() anyerror!u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    var allocator = &gpa.allocator;

    samples = Samples.init(allocator);
    defer samples.deinit();

    var args_it = std.process.args();
    defer args_it.deinit();

    std.debug.assert(args_it.skip() == true);

    const host = try (args_it.next(allocator) orelse @panic("expected host arg"));
    defer allocator.free(host);

    const path = try (args_it.next(allocator) orelse @panic("expected path arg"));
    defer allocator.free(path);

    ao.c.ao_initialize();
    defer ao.c.ao_shutdown();
    std.debug.warn("initialized libao\n", .{});

    const driver_id = ao.c.ao_driver_id("pulse");
    // const driver_id = ao.c.ao_default_driver_id();
    if (driver_id == -1) {
        std.debug.warn("libao error: failed to get default driver\n", .{});
        return 1;
    }

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

    var matrix = try allocator.dupe(u8, "M");
    defer allocator.free(matrix);

    var matrix_c = try std.cstr.addNullByte(allocator, matrix);
    defer allocator.free(matrix_c);

    var sample_format = std.mem.zeroes(ao.c.ao_sample_format);
    sample_format.bits = 16;
    sample_format.rate = info.samplerate;
    sample_format.channels = 1;
    sample_format.byte_format = ao.c.AO_FMT_NATIVE;
    // sample_format.matrix = matrix_c.ptr;

    var device = ao.c.ao_open_live(driver_id, &sample_format, null);
    if (device == null) {
        const errno = std.c._errno().*;
        std.debug.warn("failed to open libao device: errno {}\n", .{errno});
        return 1;
    }
    defer {
        _ = ao.c.ao_close(device);
    }

    const samplerate = @intCast(usize, info.samplerate);
    var audio_read_buffer = try allocator.alloc(i16, samplerate);
    defer allocator.free(audio_read_buffer);

    var pulse_buffer = try allocator.alloc(u8, samplerate * 2);
    defer allocator.free(pulse_buffer);

    while (true) {
        std.debug.warn("==reading\n", .{});

        const frames = @intCast(usize, sndfile.c.sf_readf_short(
            file,
            audio_read_buffer.ptr,
            @intCast(i64, audio_read_buffer.len),
        ));

        std.debug.warn("==got {} frames\n", .{frames});
        if (frames == 0) {
            if (virtual_ctx.read_error) |err| {
                std.debug.warn("read error {}\n", .{err});
            } else {
                std.debug.warn("finished read\n", .{});
            }

            break;
        }

        var proper_buffer = audio_read_buffer[0..frames];

        const res = ao.c.ao_play(
            device,
            @ptrCast([*c]u8, proper_buffer.ptr),
            @intCast(c_uint, proper_buffer.len * 2),
        );
        if (res == 0) {
            const errno = std.c._errno().*;
            std.debug.warn("ao_play fail: errno {}\n", .{errno});
            return 1;
        }
        std.debug.warn("ao_play result: {}\n", .{res});
    }

    return 0;
}
