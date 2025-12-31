const std = @import("std");
const Allocator = std.mem.Allocator;
const agl = @import("agl.zig");

pub const CffError = error{
    InvalidHeader,
    TruncatedData,
    InvalidIndex,
    UnsupportedFeature,
    DictError,
    StackUnderflow,
    InvalidOperand,
};

pub const CffParser = struct {
    data: []const u8,
    allocator: Allocator,

    // Indices
    name_index: Index = undefined,
    top_dict_index: Index = undefined,
    string_index: Index = undefined,
    global_subr_index: Index = undefined,
    
    // Top DICT data
    charstrings_offset: usize = 0,
    charset_offset: usize = 0,
    encoding_offset: usize = 0,
    private_dict_offset: usize = 0,
    private_dict_size: usize = 0,

    // Parsed tables
    charsets: []u16 = &[_]u16{}, // Map GID -> SID/CID. 0 means .notdef
    charstrings_index: Index = undefined,
    
    // Standard strings (SIDs 0-390)
    const std_strings = @import("cff_std_strings.zig").std_strings;

    pub fn init(allocator: Allocator, data: []const u8) !CffParser {
        var parser = CffParser{
            .data = data,
            .allocator = allocator,
        };
        try parser.parse();
        return parser;
    }

    pub fn deinit(self: *CffParser) void {
        self.allocator.free(self.charsets);
    }

    fn parse(self: *CffParser) !void {
        var cursor = Cursor{ .data = self.data };

        // 1. Header
        // Card8 major, Card8 minor, Card8 hdrSize, OffSize offSize
        if (cursor.remaining() < 4) return CffError.TruncatedData;
        const major = cursor.readCard8();
        const minor = cursor.readCard8();
        _ = minor;
        const hdr_size = cursor.readCard8();
        const off_size = cursor.readCard8();
        _ = off_size;

        if (major != 1) return CffError.UnsupportedFeature; // Only CFF 1.0 supported

        // Move to end of header (hdr_size might be larger than 4)
        cursor.pos = hdr_size;

        // 2. Name INDEX
        self.name_index = try Index.parse(&cursor);
        
        // 3. Top DICT INDEX
        self.top_dict_index = try Index.parse(&cursor);
        
        // 4. String INDEX
        self.string_index = try Index.parse(&cursor);
        
        // 5. Global Subr INDEX
        self.global_subr_index = try Index.parse(&cursor);

        // 6. Parse Top DICT (we only support the first font in the Set)
        if (self.top_dict_index.count > 0) {
            const top_dict_data = self.top_dict_index.getData(self.data, 0);
            try self.parseTopDict(top_dict_data);
        }

        // 7. Parse Charstrings INDEX
        if (self.charstrings_offset > 0) {
            var cs_cursor = Cursor{ .data = self.data, .pos = self.charstrings_offset };
            self.charstrings_index = try Index.parse(&cs_cursor);
        }

        // 8. Parse Charset
        if (self.charset_offset > 0 and self.charstrings_index.count > 0) {
            try self.parseCharset();
        }
    }

    fn parseTopDict(self: *CffParser, data: []const u8) !void {
        var p = DictParser{ .data = data };
        while (try p.next()) |op| {
            switch (op.operator) {
                15 => { // Charset
                    if (op.operands.len > 0) self.charset_offset = @intCast(op.operands[0]);
                },
                16 => { // Encoding
                    if (op.operands.len > 0) self.encoding_offset = @intCast(op.operands[0]);
                },
                17 => { // CharStrings
                    if (op.operands.len > 0) self.charstrings_offset = @intCast(op.operands[0]);
                },
                18 => { // Private
                     if (op.operands.len >= 2) {
                        self.private_dict_size = @intCast(op.operands[0]);
                        self.private_dict_offset = @intCast(op.operands[1]);
                    }
                },
                // We ignore other operators for now
                else => {},
            }
        }
    }

    fn parseCharset(self: *CffParser) !void {
        // Pre-ISO standard CFF charsets
        if (self.charset_offset == 0) { // ISOAdobe
            // TODO: Populate standard charset
            return;
        } else if (self.charset_offset == 1) { // Expert
            return;
        } else if (self.charset_offset == 2) { // ExpertSubset
            return;
        }

        var cursor = Cursor{ .data = self.data, .pos = self.charset_offset };
        const format = cursor.readCard8();
        const num_glyphs = self.charstrings_index.count;
        
        self.charsets = try self.allocator.alloc(u16, num_glyphs);
        self.charsets[0] = 0; // .notdef

        var gid: usize = 1;
        
        switch (format) {
            0 => { // Format 0
                while (gid < num_glyphs and cursor.remaining() >= 2) {
                    const sid = cursor.readCard16();
                    self.charsets[gid] = sid;
                    gid += 1;
                }
            },
            1 => { // Format 1
                while (gid < num_glyphs and cursor.remaining() >= 3) {
                    const first_sid = cursor.readCard16();
                    const n_left = cursor.readCard8();
                    for (0..(n_left + 1)) |i| {
                        if (gid + i < num_glyphs) {
                            self.charsets[gid + i] = first_sid + @as(u16, @intCast(i));
                        }
                    }
                    gid += n_left + 1;
                }
            },
            2 => { // Format 2
                while (gid < num_glyphs and cursor.remaining() >= 4) {
                    const first_sid = cursor.readCard16();
                    const n_left = cursor.readCard16();
                    for (0..(n_left + 1)) |i| {
                         if (gid + i < num_glyphs) {
                            self.charsets[gid + i] = first_sid + @as(u16, @intCast(i));
                        }
                    }
                    gid += n_left + 1;
                }
            },
            else => return CffError.UnsupportedFeature,
        }
    }

    pub fn getGlyphName(self: *const CffParser, gid: u16) ?[]const u8 {
        if (gid >= self.charsets.len) return null;
        const sid = self.charsets[gid];
        return self.getString(sid);
    }

    pub fn getString(self: *const CffParser, sid: u16) ?[]const u8 {
        if (sid < std_strings.len) {
            return std_strings[sid];
        }
        const index = sid - std_strings.len;
        if (index < self.string_index.count) {
            return self.string_index.getData(self.data, index);
        }
        return null;
    }
};

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn remaining(self: *Cursor) usize {
        if (self.pos >= self.data.len) return 0;
        return self.data.len - self.pos;
    }

    fn readCard8(self: *Cursor) u8 {
        if (self.pos >= self.data.len) return 0;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    fn readCard16(self: *Cursor) u16 {
        if (self.pos + 1 >= self.data.len) return 0;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    fn readOffSize(self: *Cursor, size: u8) usize {
        var v: usize = 0;
        var i: u8 = 0;
        while (i < size) : (i += 1) {
            v = (v << 8) | self.readCard8();
        }
        return v;
    }
};

const Index = struct {
    count: u16,
    off_size: u8,
    offsets_offset: usize,
    data_offset: usize,

    fn parse(cursor: *Cursor) !Index {
        if (cursor.remaining() < 2) return CffError.TruncatedData;
        const count = cursor.readCard16();
        if (count == 0) {
            return Index{
                .count = 0,
                .off_size = 0,
                .offsets_offset = 0,
                .data_offset = 0,
            };
        }

        if (cursor.remaining() < 1) return CffError.TruncatedData;
        const off_size = cursor.readCard8();
        
        const offsets_offset = cursor.pos;
        // Skip offsets array: (count + 1) * off_size
        const offsets_len = (count + 1) * @as(usize, off_size);
        if (cursor.remaining() < offsets_len) return CffError.TruncatedData;
        
        // Read last offset to skip data
        // We need to peek at the last offset to know data size
        var temp_cursor = Cursor{ .data = cursor.data, .pos = offsets_offset + (count * off_size) };
        const data_size = temp_cursor.readOffSize(off_size) - 1; // Offsets are 1-based usually relative to data start
        
        cursor.pos += offsets_len;
        const data_offset = cursor.pos;
        
        // Skip data
        // Note: The offsets in the index are relative to the byte preceding the data array
        // (i.e., the first offset is always 1). So total data length is last_offset - 1.
        cursor.pos += data_size;

        return Index{
            .count = count,
            .off_size = off_size,
            .offsets_offset = offsets_offset,
            .data_offset = data_offset,
        };
    }

    fn getData(self: Index, full_data: []const u8, index: usize) []const u8 {
        if (index >= self.count) return &[_]u8{};
        
        // Read offset[index]
        var cursor = Cursor{ .data = full_data, .pos = self.offsets_offset + (index * self.off_size) };
        const start = cursor.readOffSize(self.off_size);
        const end = cursor.readOffSize(self.off_size);
        
        // Offsets are relative to byte preceding data array. So offset 1 means start of data.
        // real_start = data_offset + start - 1
        const real_start = self.data_offset + start - 1;
        const real_end = self.data_offset + end - 1;
        
        if (real_start >= full_data.len or real_end > full_data.len or real_start > real_end) {
            return &[_]u8{};
        }
        
        return full_data[real_start..real_end];
    }
};

const DictParser = struct {
    data: []const u8,
    pos: usize = 0,

    const Op = struct {
        operator: u16,
        operands: []const i32,
    };
    
    // Max operands per operator
    var operand_buf: [48]i32 = undefined; 

    fn next(self: *DictParser) !?Op {
        if (self.pos >= self.data.len) return null;

        var op_count: usize = 0;

        while (self.pos < self.data.len) {
            const b0 = self.data[self.pos];
            if (b0 <= 21) {
                // Operator
                self.pos += 1;
                var op: u16 = b0;
                if (b0 == 12) {
                    if (self.pos >= self.data.len) return CffError.TruncatedData;
                    const b1 = self.data[self.pos];
                    self.pos += 1;
                    op = (@as(u16, 12) << 8) | b1;
                }
                return Op{ .operator = op, .operands = operand_buf[0..op_count] };
            } else if (b0 >= 28 and b0 != 31) {
                // Operand
                if (op_count >= operand_buf.len) return CffError.StackUnderflow; // Actually overflow
                operand_buf[op_count] = try self.readNumber();
                op_count += 1;
            } else {
                 // Reserved or 31 (which is also number prefix 30?) - 30 is representation for real number
                 // standard says:
                 // 32-246: int
                 // 247-250: +int
                 // 251-254: -int
                 // 255: reserved
                 // 28: shortint
                 // 29: longint
                 // 30: real
                 if (op_count >= operand_buf.len) return CffError.StackUnderflow;
                 operand_buf[op_count] = try self.readNumber();
                 op_count += 1;
            }
        }
        return null;
    }

    fn readNumber(self: *DictParser) !i32 {
        if (self.pos >= self.data.len) return 0;
        const b0 = self.data[self.pos];
        self.pos += 1;

        if (b0 == 28) { // shortint
            if (self.pos + 1 >= self.data.len) return CffError.TruncatedData;
            const b1 = self.data[self.pos];
            const b2 = self.data[self.pos+1];
            self.pos += 2;
            return @as(i16, @bitCast(@as(u16, (@as(u16, b1) << 8) | b2)));
        } else if (b0 == 29) { // longint
            if (self.pos + 3 >= self.data.len) return CffError.TruncatedData;
            const v = std.mem.readInt(i32, self.data[self.pos..][0..4], .big);
            self.pos += 4;
            return v;
        } else if (b0 >= 32 and b0 <= 246) {
            return @as(i32, b0) - 139;
        } else if (b0 >= 247 and b0 <= 250) {
            if (self.pos >= self.data.len) return CffError.TruncatedData;
            const b1 = self.data[self.pos];
            self.pos += 1;
            return (@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108;
        } else if (b0 >= 251 and b0 <= 254) {
            if (self.pos >= self.data.len) return CffError.TruncatedData;
            const b1 = self.data[self.pos];
            self.pos += 1;
            return -(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108;
        } else if (b0 == 30) {
             // Real number - skip for now, logic is complex
             // Just consume nibbles until 0xF
             while (self.pos < self.data.len) {
                 const b = self.data[self.pos];
                 self.pos += 1;
                 if ((b & 0xF) == 0xF or (b >> 4) == 0xF) break;
             }
             return 0; // Placeholder
        }
        return 0;
    }
};
