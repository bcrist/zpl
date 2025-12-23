pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var printer_name: []const u8 = "";
    var prefix: []const u8 = "";
    var first_number: usize = 1;
    var count: usize = 32;

    var arg_iter = try std.process.argsWithAllocator(gpa);
    defer arg_iter.deinit();
    _ = arg_iter.next(); // self
    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--printer")) {
            printer_name = arg_iter.next() orelse return error.ExpectedPrinterName;
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            prefix = arg_iter.next() orelse return error.ExpectedPrefix;
        } else if (std.mem.eql(u8, arg, "--first")) {
            first_number = try std.fmt.parseUnsigned(usize, arg_iter.next() orelse return error.ExpectedBaseNumber, 10);
        } else {
            count = try std.fmt.parseUnsigned(usize, arg, 10);
        }
    }
    
    if (printer_name.len == 0) {
        try enumerate_printers(gpa);
        std.log.err("Use `--printer \"Printer Name\"` to specify the ZPL-compatible printer name, or `--printer stdout` to dump raw ZPL commands", .{});
        std.process.exit(2);
    }

    var printer_buf: [16384]u8 = undefined;
    var printer: Printer = .dummy;
    if (!std.mem.eql(u8, printer_name, "stdout")) printer = try .init(gpa, printer_name, &printer_buf);
    defer printer.deinit();

    var stdout_buf: [64]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);

    const writer: *std.io.Writer = if (std.mem.eql(u8, printer_name, "stdout")) &stdout.interface else &printer.writer;
    var zb: zpl.Builder = .init(gpa, writer, .{ .dpmm = 8 });
    defer zb.deinit();

    var temp_buf: [4096]u8 = undefined;
    var temp = std.io.Writer.fixed(&temp_buf);

    for (0..count) |i| {
        const label_offset: usize = i % 32;
        const row: usize = label_offset / 8;
        const col: usize = label_offset % 8;

        if (label_offset == 0) {
            if (i != 0) try zb.end();
            try zb.label();
        }

        const n = first_number + i;
        temp.end = 0;
        try temp.print("{s}{d}\n", .{ prefix, n });
        const str = temp.buffered();

        const x = 10 + col * 99;
        const y = 5 + row * 99;

        try zb.box(.{
            .origin = .{ .absolute = .{ x, y } },
            .width = .{ .dots = 100 },
            .height = .{ .dots = 100 },
        });

        try zb.data_matrix(str[0 .. str.len - 1], .{
            .origin = .{ .absolute = .{ x + 20, y + 10 } },
            .pixel_height = .{ .dots = 5 },
            .quality = 200,
            .columns = 12,
            .rows = 12,
        });

        try zb.field(str, .{
            .typeset = .{
                .x = .{ .dots = x },
                .y = .{ .dots = y + 90 },
            },
            .block = .{
                .width = .{ .dots = 100 },
                .alignment = .center,
            },
            .font = .scalable(.{
                .width = .{ .dots = 24 },
                .height = .{ .dots = 16 },
            }),
        });
    }

    try zb.end_all();
    try writer.flush();
}

const Printer = @import("printer.zig").Printer;
const enumerate_printers = @import("printer.zig").enumerate_printers;

const zpl = @import("zpl");
const std = @import("std");
