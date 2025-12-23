pub const Printer = switch (builtin.os.tag) {
    .windows => Windows_Printer,
    else => @compileError("Unsupported OS"),
};

pub const enumerate_printers = switch (builtin.os.tag) {
    .windows => enumerate_printers_windows,
    else => @compileError("Unsupported OS"),
};

fn enumerate_printers_windows(gpa: std.mem.Allocator) !void {
    var bytes_needed: win.DWORD = 0;
    var count: win.DWORD = 0;
    if (win.EnumPrintersW(win.PRINTER_ENUM_LOCAL | win.PRINTER_ENUM_CONNECTIONS, null, 1, null, 0, &bytes_needed, &count) == 0) {
        const err: std.os.windows.Win32Error = win.GetLastError();
        if (err != .INSUFFICIENT_BUFFER) {
            std.log.err("Failed to enumerate printers: {}", .{ err });
            std.process.exit(20);
        }
    }

    const buf = try gpa.alloc(win.PRINTER_INFO_1W, bytes_needed / @sizeOf(win.PRINTER_INFO_1W));
    defer gpa.free(buf);

    if (win.EnumPrintersW(win.PRINTER_ENUM_LOCAL | win.PRINTER_ENUM_CONNECTIONS, null, 1, buf.ptr, @intCast(buf.len * @sizeOf(win.PRINTER_INFO_1W)), &bytes_needed, &count) == 0) {
        std.log.err("Failed to enumerate printers: {}", .{ win.GetLastError() });
        std.process.exit(21);
    }

    for (buf[0..count]) |printer| {
        const name = try std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.sliceTo(printer.name, 0));
        defer gpa.free(name);

        const desc = try std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.sliceTo(printer.description, 0));
        defer gpa.free(desc);

        const comment = try std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.sliceTo(printer.comment, 0));
        defer gpa.free(comment);

        if (desc.len > 0) {
            if (comment.len > 0) {
                std.log.info(
                    \\Found printer: "{s}"
                    \\  Description: {s}
                    \\      Comment: {s}
                , .{ name, desc, comment });
            } else {
                std.log.info(
                    \\Found printer: "{s}"
                    \\  Description: {s}
                , .{ name, desc });
            }
        } else if (comment.len > 0) {
            std.log.info(
                \\Found printer: "{s}"
                \\      Comment: {s}
            , .{ name, comment });
        } else {
            std.log.info("Found printer: \"{s}\"", .{ name });
        }
    }
}

const Windows_Printer = struct {
    h: ?win.HANDLE,
    job: ?win.DWORD,
    page_started: bool,
    writer: std.io.Writer,

    pub const dummy: Windows_Printer = .{
        .h = null,
        .job = null,
        .page_started = false,
        .writer = .{
            .vtable = &.{
                .drain = drain,
            },
            .buffer = &.{},
        },
    };

    pub fn init(gpa: std.mem.Allocator, printer_name: []const u8, buffer: []u8) !Windows_Printer {
        const printer_name_wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, printer_name);
        defer gpa.free(printer_name_wide);

        var maybe_handle: ?win.HANDLE = null;
        var handle: win.HANDLE = undefined;
        if (win.OpenPrinterW(printer_name_wide.ptr, &handle, null) == 0) {
            std.log.err("Failed to open printer: {}", .{ win.GetLastError() });
        } else {
            maybe_handle = handle;
        }

        var self: Windows_Printer = .{
            .h = maybe_handle,
            .job = null,
            .page_started = false,
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = buffer,
            },
        };
        errdefer self.deinit();

        try self.start_job();
        try self.start_page();

        return self;
    }
    pub fn deinit(self: *Windows_Printer) void {
        self.end_job();
        if (self.h) |handle| {
            if (win.ClosePrinter(handle) == 0) {
                std.log.err("Failed to close printer: {}", .{ win.GetLastError() });
            }
            self.h = null;
        }
    }

    pub fn start_job(self: *Windows_Printer) !void {
        if (self.job != null) self.end_job();
        if (self.h) |handle| {
            const job_number = win.StartDocPrinterW(handle, 1, &.{
                .doc_name = std.unicode.utf8ToUtf16LeStringLiteral("ZPL Label Job"),
                .output_file = null,
                .datatype = std.unicode.utf8ToUtf16LeStringLiteral("RAW"),
            });
            if (job_number == 0) {
                std.log.err("Failed to begin print job: {}", .{ win.GetLastError() });
                return error.Unexpected;
            } else {
                self.job = job_number;
            }
        } else {
            self.job = 0;
        }
    }
    pub fn end_job(self: *Windows_Printer) void {
        if (self.page_started) self.end_page();
        if (self.job == null) return;
        if (self.h) |handle| {
            if (win.EndDocPrinter(handle) == 0) {
                std.log.err("Failed to end print job: {}", .{ win.GetLastError() });
            }
        }
        self.job = null;
    }

    fn start_page(self: *Windows_Printer) !void {
        if (self.job == null) try self.start_job();
        if (self.page_started) self.end_page();
        if (self.h) |handle| {
            if (win.StartPagePrinter(handle) == 0) {
                std.log.err("Failed to begin page: {}", .{ win.GetLastError() });
                return error.Unexpected;
            }
        }
        self.page_started = true;
    }
    fn end_page(self: *Windows_Printer) void {
        if (!self.page_started) return;
        if (self.h) |handle| {
            if (win.EndPagePrinter(handle) == 0) {
                std.log.err("Failed to end page: {}", .{ win.GetLastError() });
            }
        }
        self.page_started = false;
    }

    fn drain(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
        const printer: *Windows_Printer = @fieldParentPtr("writer", w);
        var total_bytes_written: usize = 0;

        var bytes_written = try printer.write(w.buffer[0..w.end]);
        total_bytes_written += bytes_written;
        if (bytes_written < w.end) {
            @memmove(w.buffer.ptr, w.buffer[bytes_written..w.end]);
            w.end -= bytes_written;
            return total_bytes_written;
        } else {
            w.end = 0;
        }

        if (data.len > 1) {
            for (data[0 .. data.len - 1]) |bytes| {
                bytes_written = try printer.write(bytes);
                total_bytes_written += bytes_written;
                if (bytes_written < bytes.len) return total_bytes_written;
            }
        }
        const bytes = data[data.len - 1];
        for (0..splat) |_| {
            bytes_written = try printer.write(bytes);
            total_bytes_written += bytes_written;
            if (bytes_written < bytes.len) return total_bytes_written;
        }
        return total_bytes_written;
    }

    fn write(self: *Windows_Printer, data: []const u8) std.io.Writer.Error!usize {
        if (self.h) |handle| {
            var bytes_written: win.DWORD = 0;
            if (win.WritePrinter(handle, data.ptr, @intCast(@min(data.len, std.math.maxInt(u32))), &bytes_written) == 0) {
                std.log.err("Failed to write to printer: {}", .{ win.GetLastError() });
                return error.WriteFailed;
            }
            return bytes_written;
        } else return data.len;
    }
};

const win = struct {
    extern "winspool" fn EnumPrintersW(
        flags: DWORD,
        name: ?LPCWSTR,
        level: DWORD,
        out: ?LPVOID,
        out_size_bytes: DWORD,
        bytes_needed: *DWORD,
        count: *DWORD,
    ) callconv(.winapi) BOOL;

    extern "winspool" fn OpenPrinterW(
        printer_name: LPCWSTR,
        out: *HANDLE,
        defaults: ?*PRINTER_DEFAULTSW,
    ) callconv(.winapi) BOOL;

    extern "winspool" fn ClosePrinter(printer: HANDLE) callconv(.winapi) BOOL;

    extern "winspool" fn StartDocPrinterW(printer: HANDLE, level: DWORD, doc_info: *const DOC_INFO_1W) callconv(.winapi) DWORD;
    extern "winspool" fn EndDocPrinter(printer: HANDLE) callconv(.winapi) BOOL;
    extern "winspool" fn StartPagePrinter(printer: HANDLE) callconv(.winapi) BOOL;
    extern "winspool" fn EndPagePrinter(printer: HANDLE) callconv(.winapi) BOOL;

    extern "winspool" fn WritePrinter(
        printer: HANDLE,
        data: *const anyopaque,
        len: DWORD,
        bytes_written: *DWORD,
    ) callconv(.winapi) BOOL;

    const PRINTER_INFO_1W = extern struct {
        flags: DWORD,
        description: LPCWSTR,
        name: LPCWSTR,
        comment: LPCWSTR,
    };

    const PRINTER_DEFAULTSW = extern struct {
        datatype: LPCWSTR,
        devmode: LPVOID,
        desired_access: ACCESS_MASK,
    };

    const DOC_INFO_1W = extern struct {
        doc_name: LPCWSTR,
        output_file: ?LPCWSTR,
        datatype: LPCWSTR,
    };

    const PRINTER_ENUM_LOCAL: DWORD = 2;
    const PRINTER_ENUM_NAME: DWORD = 8;
    const PRINTER_ENUM_SHARED: DWORD = 0x20;
    const PRINTER_ENUM_CONNECTIONS: DWORD = 4;
    const PRINTER_ENUM_NETWORK: DWORD = 0x40;
    const PRINTER_ENUM_REMOTE: DWORD = 0x10;

    const GetLastError = std.os.windows.GetLastError;

    const BOOL = std.os.windows.BOOL;
    const DWORD = std.os.windows.DWORD;
    const LPVOID = std.os.windows.LPVOID;
    const LPCWSTR = std.os.windows.LPCWSTR;
    const HANDLE = std.os.windows.HANDLE;
    const ACCESS_MASK = std.os.windows.ACCESS_MASK;
};

const builtin = @import("builtin");
const std = @import("std");
