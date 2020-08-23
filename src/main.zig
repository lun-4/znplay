const std = @import("std");

pub fn main() anyerror!void {
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
    std.debug.warn("host: {}\n", .{host});

    const path = try (args_it.next(allocator) orelse @panic("expected path arg"));
    defer allocator.free(path);
    std.debug.warn("path: {}\n", .{path});
}
