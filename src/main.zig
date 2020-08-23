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

    const url = try (args_it.next(allocator) orelse @panic("expected url arg"));
    defer allocator.free(url);

    std.debug.warn("url: {}\n", .{url});
}
