pub const Builder = struct {
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    dots_per_um: f32,
    relative_origin: Point,
    end_stack: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, writer: *std.io.Writer, resolution: Resolution) Builder {
        return .{
            .allocator = allocator,
            .writer = writer,
            .dots_per_um = @floatFromInt(switch (resolution) {
                .dpi => |v| v * inches_to_um,
                .dpmm => |v| v * mm_to_um,
                .dpum => |v| v,
            }),
            .relative_origin = @splat(0),
            .end_stack = .empty,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.end_stack.deinit(self.allocator);
    }

    pub fn end(self: *Builder) !void {
        const command = self.end_stack.pop() orelse return error.NoStartedCommand;
        try self.writer.writeAll(command);
    }

    pub fn end_all(self: *Builder) !void {
        while (self.end_stack.pop()) |command| {
            if (std.mem.endsWith(u8, command, "\x00")) {
                try self.writer.writeAll(command[0 .. command.len - 1]);
                try self.writer.flush();
            } else {
                try self.writer.writeAll(command);
            }
        }
    }

    pub fn label(self: *Builder) !void {
        try self.end_stack.ensureUnusedCapacity(self.allocator, 2);
        try self.writer.writeAll("^XA\n");
        self.end_stack.appendAssumeCapacity("^XZ\n\x00");
    }

    pub fn field(self: *Builder, data: []const u8, options: Field_Options) !void {
        if (options.leave_open) try self.end_stack.ensureUnusedCapacity(self.allocator, 1);
        if (options.origin) |o| try self.field_origin(o);
        if (options.typeset) |ft| try self.field_typeset(ft);
        if (options.block) |fb| try self.field_block(fb);
        if (options.font) |f| try self.font(f);
        if (data.len > 0) try self.field_data(data);
        if (options.leave_open) {
            self.end_stack.appendAssumeCapacity("^FS\n");
        } else {
            try self.writer.writeAll("^FS\n");
        }
    }

    pub fn field_origin(self: *Builder, fo: Field_Origin) !void {
        const origin: Point = switch (fo) {
            .absolute => |p| p,
            .absolute_inches => |p| .{
                @intFromFloat(@round(p[0] * inches_to_um / self.dots_per_um)),
                @intFromFloat(@round(p[1] * inches_to_um / self.dots_per_um)),
            },
            .absolute_mm => |p| .{
                @intFromFloat(@round(p[0] * mm_to_um / self.dots_per_um)),
                @intFromFloat(@round(p[1] * mm_to_um / self.dots_per_um)),
            },
            .relative => |p| self.relative_origin + p,
            .relative_inches => |p| self.relative_origin + Point {
                @intFromFloat(@round(p[0] * inches_to_um / self.dots_per_um)),
                @intFromFloat(@round(p[1] * inches_to_um / self.dots_per_um)),
            },
            .relative_mm => |p| self.relative_origin + Point {
                @intFromFloat(@round(p[0] * mm_to_um / self.dots_per_um)),
                @intFromFloat(@round(p[1] * mm_to_um / self.dots_per_um)),
            },
        };
        try self.writer.print("^FO{d},{d}", .{ origin[0], origin[1] });
        self.relative_origin = origin;
    }

    // works similarly to field_origin, but positions text relative to the baseline rather than the top of the em box
    pub fn field_typeset(self: *Builder, ft: Field_Typeset) !void {
        if (ft.y) |y| {
            if (ft.x) |x| {
                try self.writer.print("^FT{d},{d}", .{
                    x.to_dots(self.dots_per_um),
                    y.to_dots(self.dots_per_um),
                });
            } else {
                try self.writer.print("^FT,{d}", .{ y.to_dots(self.dots_per_um) });
            }
        } else if (ft.x) |x| {
            try self.writer.print("^FT{d}", .{ x.to_dots(self.dots_per_um) });
        } else {
            try self.writer.writeAll("^FT");
        }
    }

    pub fn field_block(self: *Builder, fb: Field_Block) !void {
        try self.writer.print("^FB{d}", .{ fb.width.to_dots(self.dots_per_um) });
        const line_height_adjust = fb.line_height_adjust.to_dots(self.dots_per_um);
        const hanging_indent = fb.hanging_indent.to_dots(self.dots_per_um);
        if (fb.lines == 1 and line_height_adjust == 0 and fb.alignment == .left and hanging_indent == 0) return;
        try self.writer.writeByte(',');
        if (fb.lines != 1) try self.writer.print("{d}", .{ fb.lines });
        if (line_height_adjust == 0 and fb.alignment == .left and hanging_indent == 0) return;
        try self.writer.writeByte(',');
        if (line_height_adjust != 0) try self.writer.print("{d}", .{ line_height_adjust });
        if (fb.alignment == .left and hanging_indent == 0) return;
        try self.writer.writeByte(',');
        switch (fb.alignment) {
            .left => try self.writer.writeByte('L'),
            .center => try self.writer.writeByte('C'),
            .right => try self.writer.writeByte('R'),
            .justified => try self.writer.writeByte('J'),
        }
        if (hanging_indent == 0) return;
        try self.writer.print(",{d}", .{ hanging_indent });
    }

    pub fn field_data(self: *Builder, data: []const u8) !void {
        try self.writer.print("^FH^FD{f}", .{ fmt_data(data) });
    }

    pub fn font(self: *Builder, f: Font) !void {
        try self.writer.writeAll("^A");
        try self.writer.writeByte(f.name);
        if (f.orientation) |orientation| try self.writer.writeByte(switch (orientation) {
            .normal => 'N',
            .inverted => 'I',
            .cw => 'R',
            .ccw => 'B',
        });
        if (f.height) |height| {
            try self.writer.print(",{d}", .{ height.to_dots(self.dots_per_um) });
            if (f.width) |width| {
                try self.writer.print(",{d}", .{ width.to_dots(self.dots_per_um) });
            }
        } else if (f.width) |width| {
            try self.writer.print(",,{d}", .{ width.to_dots(self.dots_per_um) });
        }
        const character_spacing_adjust = f.character_spacing_adjust.to_dots(self.dots_per_um);
        if (f.flow != .left_to_right or character_spacing_adjust != 0) {
            try self.writer.writeAll("^FP");
            try self.writer.writeByte(switch (f.flow) {
                .left_to_right => 'H',
                .right_to_left => 'R',
                .top_to_bottom => 'V',
            });
            if (character_spacing_adjust != 0) {
                try self.writer.print(",{d}", .{ character_spacing_adjust });
            }
        }
        if (f.reverse) {
            try self.writer.writeAll("^FR");
        }
    }

    pub fn default_font(self: *Builder, f: Font) !void {
        std.debug.assert(f.flow == .left_to_right);
        std.debug.assert(f.character_spacing_adjust.to_dots(self.dots_per_um) == 0);
        std.debug.assert(!f.reverse);
        try self.writer.writeAll("^CF");
        try self.writer.writeByte(f.name);
        if (f.height) |height| {
            try self.writer.print(",{d}", .{ height.to_dots(self.dots_per_um) });
            if (f.width) |width| {
                try self.writer.print(",{d}", .{ width.to_dots(self.dots_per_um) });
            }
        } else if (f.width) |width| {
            try self.writer.print(",,{d}", .{ width.to_dots(self.dots_per_um) });
        }
        if (f.orientation) |orientation| {
            self.default_field_orientation(orientation);
        }
    }

    pub fn default_field_orientation(self: *Builder, orientation: Orientation) !void {
        try self.writer.writeAll("^FW");
        try self.writer.writeByte(switch (orientation) {
            .normal => 'N',
            .inverted => 'I',
            .cw => 'R',
            .ccw => 'B',
        });
    }

    pub fn box(self: *Builder, b: Box) !void {
        if (b.origin) |o| {
            try self.field_origin(o);
            try self.write_gb(b);
            if (b.leave_open) {
                try self.end_stack.ensureUnusedCapacity(self.allocator, 1);
                self.end_stack.appendAssumeCapacity("^FS\n");
            } else {
                try self.writer.writeAll("^FS\n");
            }
        } else {
            try self.write_gb(b);
        }
    }

    fn write_gb(self: *Builder, b: Box) !void {
        try self.writer.writeAll("^GB");
        if (b.width) |w| try self.writer.print("{d}", .{ w.to_dots(self.dots_per_um) });
        if (b.height == null and b.border == null and b.color == .black and b.rounding == .none) return;
        try self.writer.writeByte(',');
        if (b.height) |h| try self.writer.print("{d}", .{ h.to_dots(self.dots_per_um) });
        if (b.border == null and b.color == .black and b.rounding == .none) return;
        try self.writer.writeByte(',');
        if (b.border) |bt| try self.writer.print("{d}", .{ bt.to_dots(self.dots_per_um) });
        if (b.color == .black and b.rounding == .none) return;
        try self.writer.writeByte(',');
        switch (b.color) {
            .white => try self.writer.writeByte('W'),
            .black => {},
        }
        if (b.rounding == .none) return;
        try self.writer.print(",{d}", .{ @as(usize, switch (b.rounding) {
            .none => 0,
            .@"1/16" => 1,
            .@"1/8" => 2,
            .@"3/16" => 3,
            .@"1/4" => 4,
            .@"5/16" => 5,
            .@"3/8" => 6,
            .@"7/16" => 7,
            .@"1/2" => 8,
        }) });
    }

    pub fn data_matrix(self: *Builder, data: []const u8, options: Data_Matrix_Options) !void {
        if (options.leave_open) try self.end_stack.ensureUnusedCapacity(self.allocator, 1);
        if (options.origin) |o| try self.field_origin(o);
        try self.write_bx(options);
        try self.field_data(data);
        if (options.leave_open) {
            self.end_stack.appendAssumeCapacity("^FS\n");
        } else {
            try self.writer.writeAll("^FS\n");
        }
    }

    fn write_bx(self: *Builder, bx: Data_Matrix_Options) !void {
        try self.writer.writeAll("^BX");
        if (bx.orientation) |orientation| try self.writer.writeByte(switch (orientation) {
            .normal => 'N',
            .inverted => 'I',
            .cw => 'R',
            .ccw => 'B',
        });
        try self.writer.writeByte(',');
        if (bx.pixel_height) |h| try self.writer.print("{d}", .{ h.to_dots(self.dots_per_um) });
        try self.writer.print(",{d}", .{ bx.quality });
        if (bx.columns == null and bx.rows == null and bx.format == null and bx.escape_character == '~') return;
        try self.writer.writeByte(',');
        if (bx.columns) |c| try self.writer.print("{d}", .{ c });
        if (bx.rows == null and bx.format == null and bx.escape_character == '~') return;
        try self.writer.writeByte(',');
        if (bx.rows) |r| try self.writer.print("{d}", .{ r });
        if (bx.format == null and bx.escape_character == '~') return;
        try self.writer.writeByte(',');
        if (bx.format) |f| try self.writer.print("{d}", .{ @intFromEnum(f) });
        if (bx.escape_character == '~') return;
        try self.writer.print(",{c}", .{ bx.escape_character });
    }
};

pub const Field_Options = struct {
    origin: ?Field_Origin = null,
    typeset: ?Field_Typeset = null,
    font: ?Font = null,
    block: ?Field_Block = null,
    leave_open: bool = false,
};

pub const Field_Origin = union (enum) {
    absolute: Point,
    absolute_inches: Point_Inches,
    absolute_mm: Point_Millimeters,
    relative: Point,
    relative_inches: Point_Inches,
    relative_mm: Point_Millimeters,
};

pub const Field_Typeset = struct {
    x: ?Dimension = null,
    y: ?Dimension = null,
};

pub const Field_Block = struct {
    width: Dimension,
    lines: usize = 1,
    line_height_adjust: Dimension_Signed = .{ .dots = 0 },
    hanging_indent: Dimension = .{ .dots = 0 },
    alignment: enum {
        left,
        center,
        right,
        justified,
    } = .left,
};

pub const Resolution = union (enum) {
    dpi: usize,
    dpmm: usize,
    dpum: usize,
};

pub const Dimension = union (enum) {
    dots: usize,
    inches: f32,
    mm: f32,
    um: f32,

    pub fn to_dots(self: Dimension, dpum: f32) usize {
        return switch (self) {
            .dots => |v| v,
            .inches => |v| @intFromFloat(v * inches_to_um / dpum),
            .mm => |v| @intFromFloat(v * mm_to_um / dpum),
            .um => |v| @intFromFloat(v / dpum),
        };
    }
};

pub const Dimension_Signed = union (enum) {
    dots: isize,
    inches: f32,
    mm: f32,
    um: f32,

    pub fn to_dots(self: Dimension_Signed, dpum: f32) isize {
        return switch (self) {
            .dots => |v| v,
            .inches => |v| @intFromFloat(v * inches_to_um / dpum),
            .mm => |v| @intFromFloat(v * mm_to_um / dpum),
            .um => |v| @intFromFloat(v / dpum),
        };
    }
};

pub const Orientation = enum {
    normal,
    inverted, // read right to left (upside down)
    cw, // read top to bottom
    ccw, // read bottom to top
};

pub const Font = struct {
    name: u8, // 'A'...'Z' or '0'...'9'
    orientation: ?Orientation = null,
    flow: Flow = .left_to_right, // set with ^FP when not .left_to_right
    height: ?Dimension = null,
    width: ?Dimension = null,
    character_spacing_adjust: Dimension = .{ .dots = 0 }, // set with ^FP when not 0
    reverse: bool = false,

    pub const Flow = enum {
        left_to_right,
        right_to_left,
        top_to_bottom,
    };

    pub const Options = struct {
        orientation: ?Orientation = null,
        scale: usize = 1,
        scale_x: usize = 1,
        scale_y: usize = 1,

        fn width(self: Options, comptime scale: comptime_int) Dimension {
            return .{ .dots = @intCast(self.scale * self.scale_x * scale) };
        }
        fn height(self: Options, comptime scale: comptime_int) Dimension {
            return .{ .dots = @intCast(self.scale * self.scale_y * scale) };
        }
    };

    pub const Scalable_Options = struct {
        orientation: ?Orientation = null,
        height: ?Dimension = null,
        width: ?Dimension = null,
    };

    /// "Swiss 721"
    /// 1/4 of height is below baseline
    pub fn scalable(options: Scalable_Options) Font {
        return .{
            .name = '0',
            .orientation = options.orientation,
            .height = options.height,
            .width = options.width,
        };
    }

    /// em height: 7px
    /// em width: 5px
    /// spacing: 1px
    /// descenders: 2px
    pub fn small(options: Options) Font {
        return .{
            .name = 'A',
            .orientation = options.orientation,
            .height = options.height(9),
            .width = options.width(5),
        };
    }

    /// Uppercase only
    /// em height: 11px
    /// em width: 7px
    /// spacing: 2px
    pub fn bold(options: Options) Font {
        return .{
            .name = 'B',
            .orientation = options.orientation,
            .height = options.height(11),
            .width = options.width(7),
        };
    }

    /// em height: 14px
    /// em width: 10px
    /// spacing: 2px
    /// descenders: 4px
    pub fn medium(options: Options) Font {
        return .{
            .name = 'D',
            .orientation = options.orientation,
            .height = options.height(18),
            .width = options.width(10),
        };
    }

    /// em height: 21px
    /// em width: 13px
    /// spacing: 3px
    /// descenders: 4px
    pub fn light(options: Options) Font {
        return .{
            .name = 'F',
            .orientation = options.orientation,
            .height = options.height(26),
            .width = options.width(13),
        };
    }

    /// em height: 48px
    /// em width: 40px
    /// spacing: 8px
    pub fn large(options: Options) Font {
        return .{
            .name = 'G',
            .orientation = options.orientation,
            .height = options.height(60),
            .width = options.width(40),
        };
    }

    /// Uppercase only
    /// em height: 21px
    /// em width: 13px
    /// spacing: 6px
    pub fn ocr_a(options: Options) Font {
        return .{
            .name = 'H',
            .orientation = options.orientation,
            .height = options.height(21),
            .width = options.width(13),
        };
    }

    /// em height: 20px
    /// em width: 13px
    /// spacing: 6px
    /// descenders: 5px
    /// ascenders do not reach top pixel (3px blank at top)
    pub fn ocr_b(options: Options) Font {
        return .{
            .name = 'E',
            .orientation = options.orientation,
            .height = options.height(28),
            .width = options.width(15),
        };
    }
};

pub const Box = struct {
    origin: ?Field_Origin = null,
    leave_open: bool = false,
    width: ?Dimension = null,
    height: ?Dimension = null,
    border: ?Dimension = null,
    color: enum {
        black,
        white,
    } = .black,
    // corner radius = @min(width, height) * rounding
    rounding: enum {
        none,
        @"1/16",
        @"1/8",
        @"3/16",
        @"1/4",
        @"5/16",
        @"3/8",
        @"7/16",
        @"1/2",
    } = .none,
};

pub const Data_Matrix_Options = struct {
    origin: ?Field_Origin = null,
    orientation: ?Orientation = null,
    pixel_height: ?Dimension = null,
    quality: usize = 200,
    columns: ?u8 = null,
    rows: ?u8 = null,
    format: ?enum (u8) {
        numeric_space = 1,
        uppercase_space = 2,
        uppercase_numeric_space_period_comma_dash_slash = 3,
        uppercase_numeric_space = 4,
        @"7b" = 5,
        @"8b" = 6,
    } = null, // ignored when quality == 200
    escape_character: u8 = '~', // only when quality == 200
    leave_open: bool = false,
};

fn fmt_data(data: []const u8) Formatter {
    return .{ .data = data };
}

const Formatter = struct {
    data: []const u8,

    pub fn format(self: Formatter, writer: *std.io.Writer) std.io.Writer.Error!void {
        const data = self.data;
        var start: usize = 0;
        while (std.mem.indexOfAnyPos(u8, data, start, "^~_\n")) |special_pos| {
            try writer.writeAll(data[start..special_pos]);
            if (data[special_pos] == '\n') {
                try writer.writeAll("\\&");
            } else {
                try writer.print("_{X:0>2}", .{ data[special_pos] });
            }
            start = special_pos + 1;
        }
        try writer.writeAll(data[start..]);
    }
};

const inches_to_um = 25400;
const mm_to_um = 1000;

const Point = @Vector(2, usize);
const Point_Inches = @Vector(2, f32);
const Point_Millimeters = @Vector(2, f32);

const std = @import("std");
