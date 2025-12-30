//! PDF Font Encoding
//!
//! Handles conversion from PDF glyph codes to Unicode.
//!
//! Encoding precedence:
//! 1. /ToUnicode CMap (best - explicit mapping)
//! 2. /Encoding (name or dict with /Differences)
//! 3. Built-in encoding from font type
//!
//! Standard encodings: WinAnsiEncoding, MacRomanEncoding, MacExpertEncoding
//! CID fonts use CIDToGIDMap instead

const std = @import("std");
const parser = @import("parser.zig");
const decompress = @import("decompress.zig");

const Object = parser.Object;

/// Font encoding for character code to Unicode mapping
pub const FontEncoding = struct {
    /// Unicode codepoints indexed by character code (0-255 for simple fonts)
    codepoint_map: [256]u21,
    /// ToUnicode CMap ranges (for CID fonts or complex mappings)
    cmap_ranges: []const CMapRange,
    /// Is this a simple 8-bit encoding or complex CID encoding?
    is_cid: bool,
    /// Bytes per character (1 for simple, 1-4 for CID)
    bytes_per_char: u8,

    allocator: std.mem.Allocator,

    pub const CMapRange = struct {
        src_start: u32,
        src_end: u32,
        dst_start: u32,
        is_range: bool, // false = individual mapping
    };

    pub fn init(allocator: std.mem.Allocator) FontEncoding {
        var enc = FontEncoding{
            .codepoint_map = undefined,
            .cmap_ranges = &.{},
            .is_cid = false,
            .bytes_per_char = 1,
            .allocator = allocator,
        };

        // Default to WinAnsi
        enc.codepoint_map = win_ansi_encoding;

        return enc;
    }

    pub fn deinit(self: *FontEncoding) void {
        if (self.cmap_ranges.len > 0) {
            self.allocator.free(self.cmap_ranges);
        }
    }

    /// Decode a string to Unicode using this encoding
    pub fn decode(self: *const FontEncoding, data: []const u8, writer: anytype) !void {
        if (self.is_cid and self.cmap_ranges.len > 0) {
            try self.decodeCID(data, writer);
        } else {
            try self.decodeSimple(data, writer);
        }
    }

    fn decodeSimple(self: *const FontEncoding, data: []const u8, writer: anytype) !void {
        for (data) |byte| {
            const codepoint = self.codepoint_map[byte];
            if (codepoint == 0) {
                // No mapping - output replacement character or space
                try writer.writeByte(' ');
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buf) catch 1;
                try writer.writeAll(buf[0..len]);
            }
        }
    }

    fn decodeCID(self: *const FontEncoding, data: []const u8, writer: anytype) !void {
        var i: usize = 0;

        while (i < data.len) {
            // Try to read character code (1-4 bytes depending on font)
            const code = self.readCharCode(data[i..]) orelse {
                i += 1;
                continue;
            };

            i += code.bytes_consumed;

            // Look up in CMap ranges
            const codepoint = self.lookupCMap(code.value) orelse code.value;

            if (codepoint == 0) {
                try writer.writeByte(' ');
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch 1;
                try writer.writeAll(buf[0..len]);
            }
        }
    }

    fn readCharCode(self: *const FontEncoding, data: []const u8) ?struct { value: u32, bytes_consumed: u8 } {
        if (data.len == 0) return null;

        // For simple fonts, 1 byte
        if (!self.is_cid or self.bytes_per_char == 1) {
            return .{ .value = data[0], .bytes_consumed = 1 };
        }

        // For CID fonts, try 2 bytes first
        if (data.len >= 2) {
            const code = (@as(u32, data[0]) << 8) | data[1];
            // Check if this code exists in ranges
            if (self.codeInRanges(code)) {
                return .{ .value = code, .bytes_consumed = 2 };
            }
        }

        // Fall back to 1 byte
        return .{ .value = data[0], .bytes_consumed = 1 };
    }

    fn codeInRanges(self: *const FontEncoding, code: u32) bool {
        for (self.cmap_ranges) |range| {
            if (code >= range.src_start and code <= range.src_end) {
                return true;
            }
        }
        return false;
    }

    fn lookupCMap(self: *const FontEncoding, code: u32) ?u32 {
        for (self.cmap_ranges) |range| {
            if (code >= range.src_start and code <= range.src_end) {
                if (range.is_range) {
                    return range.dst_start + (code - range.src_start);
                } else {
                    return range.dst_start;
                }
            }
        }
        return null;
    }
};

/// Parse font encoding from font dictionary
pub fn parseFontEncoding(
    allocator: std.mem.Allocator,
    font_dict: Object.Dict,
    resolve_fn: anytype,
) !FontEncoding {
    var encoding = FontEncoding.init(allocator);

    // Check for ToUnicode CMap first (highest priority)
    if (font_dict.get("ToUnicode")) |tounicode| {
        const resolved = resolve_fn(tounicode) catch tounicode;
        if (resolved == .stream) {
            try parseToUnicode(allocator, resolved.stream, &encoding);
            return encoding;
        }
    }

    // Check for Encoding
    if (font_dict.get("Encoding")) |enc| {
        const resolved = resolve_fn(enc) catch enc;

        switch (resolved) {
            .name => |name| {
                applyNamedEncoding(&encoding, name);
            },
            .dict => |dict| {
                // Encoding dictionary with /BaseEncoding and /Differences
                if (dict.getName("BaseEncoding")) |base| {
                    applyNamedEncoding(&encoding, base);
                }

                if (dict.getArray("Differences")) |diffs| {
                    try applyDifferences(&encoding, diffs);
                }
            },
            else => {},
        }
    }

    // Check if CID font
    const subtype = font_dict.getName("Subtype");
    if (subtype) |st| {
        if (std.mem.eql(u8, st, "Type0") or
            std.mem.eql(u8, st, "CIDFontType0") or
            std.mem.eql(u8, st, "CIDFontType2"))
        {
            encoding.is_cid = true;
            encoding.bytes_per_char = 2;
        }
    }

    return encoding;
}

fn applyNamedEncoding(encoding: *FontEncoding, name: []const u8) void {
    if (std.mem.eql(u8, name, "WinAnsiEncoding")) {
        encoding.codepoint_map = win_ansi_encoding;
    } else if (std.mem.eql(u8, name, "MacRomanEncoding")) {
        encoding.codepoint_map = mac_roman_encoding;
    } else if (std.mem.eql(u8, name, "StandardEncoding")) {
        encoding.codepoint_map = standard_encoding;
    } else if (std.mem.eql(u8, name, "PDFDocEncoding")) {
        encoding.codepoint_map = pdf_doc_encoding;
    }
    // MacExpertEncoding omitted - rarely used
}

fn applyDifferences(encoding: *FontEncoding, diffs: []Object) !void {
    var code: u16 = 0;

    for (diffs) |item| {
        switch (item) {
            .integer => |i| {
                code = @intCast(@max(0, @min(255, i)));
            },
            .name => |name| {
                if (code < 256) {
                    encoding.codepoint_map[code] = glyphNameToUnicode(name);
                    code += 1;
                }
            },
            else => {},
        }
    }
}

/// Parse ToUnicode CMap stream
fn parseToUnicode(allocator: std.mem.Allocator, stream: Object.Stream, encoding: *FontEncoding) !void {
    // Decompress stream
    const data = decompress.decompressStream(
        allocator,
        stream.data,
        stream.dict.get("Filter"),
        stream.dict.get("DecodeParms"),
    ) catch return;
    defer allocator.free(data);

    var ranges = std.ArrayList(FontEncoding.CMapRange).init(allocator);
    errdefer ranges.deinit();

    var pos: usize = 0;

    while (pos < data.len) {
        // Skip whitespace and comments
        while (pos < data.len and (isWhitespace(data[pos]) or data[pos] == '%')) {
            if (data[pos] == '%') {
                while (pos < data.len and data[pos] != '\n') pos += 1;
            } else {
                pos += 1;
            }
        }

        if (pos >= data.len) break;

        // Look for "beginbfchar" or "beginbfrange"
        if (matchAt(data, pos, "beginbfchar")) {
            pos += 11;
            try parseBfChar(data, &pos, &ranges, encoding);
        } else if (matchAt(data, pos, "beginbfrange")) {
            pos += 12;
            try parseBfRange(data, &pos, &ranges);
        } else {
            pos += 1;
        }
    }

    encoding.cmap_ranges = try ranges.toOwnedSlice();
    if (ranges.items.len > 0) {
        encoding.is_cid = true;
    }
}

fn parseBfChar(data: []const u8, pos: *usize, ranges: *std.ArrayList(FontEncoding.CMapRange), encoding: *FontEncoding) !void {
    while (pos.* < data.len) {
        skipWhitespace(data, pos);

        if (matchAt(data, pos.*, "endbfchar")) {
            pos.* += 9;
            return;
        }

        // Parse source code: <XXXX>
        const src = parseHexToken(data, pos) orelse continue;

        skipWhitespace(data, pos);

        // Parse destination: <XXXX> (Unicode)
        const dst = parseHexToken(data, pos) orelse continue;

        // For simple 1-byte codes, update the direct map
        if (src <= 255) {
            encoding.codepoint_map[@intCast(src)] = @intCast(dst);
        }

        try ranges.append(.{
            .src_start = src,
            .src_end = src,
            .dst_start = dst,
            .is_range = false,
        });
    }
}

fn parseBfRange(data: []const u8, pos: *usize, ranges: *std.ArrayList(FontEncoding.CMapRange)) !void {
    while (pos.* < data.len) {
        skipWhitespace(data, pos);

        if (matchAt(data, pos.*, "endbfrange")) {
            pos.* += 10;
            return;
        }

        // Parse: <start> <end> <dst_start>
        const src_start = parseHexToken(data, pos) orelse continue;
        skipWhitespace(data, pos);
        const src_end = parseHexToken(data, pos) orelse continue;
        skipWhitespace(data, pos);

        // Destination can be a hex value or an array
        if (pos.* < data.len and data[pos.*] == '<') {
            const dst_start = parseHexToken(data, pos) orelse continue;
            try ranges.append(.{
                .src_start = src_start,
                .src_end = src_end,
                .dst_start = dst_start,
                .is_range = true,
            });
        } else if (pos.* < data.len and data[pos.*] == '[') {
            // Array of mappings
            pos.* += 1;
            var src = src_start;
            while (src <= src_end and pos.* < data.len) {
                skipWhitespace(data, pos);
                if (data[pos.*] == ']') {
                    pos.* += 1;
                    break;
                }
                const dst = parseHexToken(data, pos) orelse break;
                try ranges.append(.{
                    .src_start = src,
                    .src_end = src,
                    .dst_start = dst,
                    .is_range = false,
                });
                src += 1;
            }
        }
    }
}

fn parseHexToken(data: []const u8, pos: *usize) ?u32 {
    if (pos.* >= data.len or data[pos.*] != '<') return null;
    pos.* += 1;

    var value: u32 = 0;

    while (pos.* < data.len and data[pos.*] != '>') {
        const c = data[pos.*];
        pos.* += 1;

        const nibble: u4 = if (c >= '0' and c <= '9')
            @truncate(c - '0')
        else if (c >= 'A' and c <= 'F')
            @truncate(c - 'A' + 10)
        else if (c >= 'a' and c <= 'f')
            @truncate(c - 'a' + 10)
        else
            continue;

        value = (value << 4) | nibble;
    }

    if (pos.* < data.len and data[pos.*] == '>') {
        pos.* += 1;
    }

    return value;
}

fn skipWhitespace(data: []const u8, pos: *usize) void {
    while (pos.* < data.len and isWhitespace(data[pos.*])) {
        pos.* += 1;
    }
}

fn matchAt(data: []const u8, pos: usize, needle: []const u8) bool {
    if (pos + needle.len > data.len) return false;
    return std.mem.eql(u8, data[pos..][0..needle.len], needle);
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0x00;
}

/// Map glyph name to Unicode (common subset)
fn glyphNameToUnicode(name: []const u8) u21 {
    // Common glyph names - this is a subset; full AGL has 4000+ entries
    const mappings = .{
        .{ "space", ' ' },
        .{ "exclam", '!' },
        .{ "quotedbl", '"' },
        .{ "numbersign", '#' },
        .{ "dollar", '$' },
        .{ "percent", '%' },
        .{ "ampersand", '&' },
        .{ "quotesingle", '\'' },
        .{ "parenleft", '(' },
        .{ "parenright", ')' },
        .{ "asterisk", '*' },
        .{ "plus", '+' },
        .{ "comma", ',' },
        .{ "hyphen", '-' },
        .{ "period", '.' },
        .{ "slash", '/' },
        .{ "zero", '0' },
        .{ "one", '1' },
        .{ "two", '2' },
        .{ "three", '3' },
        .{ "four", '4' },
        .{ "five", '5' },
        .{ "six", '6' },
        .{ "seven", '7' },
        .{ "eight", '8' },
        .{ "nine", '9' },
        .{ "colon", ':' },
        .{ "semicolon", ';' },
        .{ "less", '<' },
        .{ "equal", '=' },
        .{ "greater", '>' },
        .{ "question", '?' },
        .{ "at", '@' },
        .{ "A", 'A' },
        .{ "B", 'B' },
        .{ "C", 'C' },
        .{ "D", 'D' },
        .{ "E", 'E' },
        .{ "F", 'F' },
        .{ "G", 'G' },
        .{ "H", 'H' },
        .{ "I", 'I' },
        .{ "J", 'J' },
        .{ "K", 'K' },
        .{ "L", 'L' },
        .{ "M", 'M' },
        .{ "N", 'N' },
        .{ "O", 'O' },
        .{ "P", 'P' },
        .{ "Q", 'Q' },
        .{ "R", 'R' },
        .{ "S", 'S' },
        .{ "T", 'T' },
        .{ "U", 'U' },
        .{ "V", 'V' },
        .{ "W", 'W' },
        .{ "X", 'X' },
        .{ "Y", 'Y' },
        .{ "Z", 'Z' },
        .{ "bracketleft", '[' },
        .{ "backslash", '\\' },
        .{ "bracketright", ']' },
        .{ "asciicircum", '^' },
        .{ "underscore", '_' },
        .{ "grave", '`' },
        .{ "a", 'a' },
        .{ "b", 'b' },
        .{ "c", 'c' },
        .{ "d", 'd' },
        .{ "e", 'e' },
        .{ "f", 'f' },
        .{ "g", 'g' },
        .{ "h", 'h' },
        .{ "i", 'i' },
        .{ "j", 'j' },
        .{ "k", 'k' },
        .{ "l", 'l' },
        .{ "m", 'm' },
        .{ "n", 'n' },
        .{ "o", 'o' },
        .{ "p", 'p' },
        .{ "q", 'q' },
        .{ "r", 'r' },
        .{ "s", 's' },
        .{ "t", 't' },
        .{ "u", 'u' },
        .{ "v", 'v' },
        .{ "w", 'w' },
        .{ "x", 'x' },
        .{ "y", 'y' },
        .{ "z", 'z' },
        .{ "braceleft", '{' },
        .{ "bar", '|' },
        .{ "braceright", '}' },
        .{ "asciitilde", '~' },
        // Extended characters
        .{ "bullet", 0x2022 },
        .{ "endash", 0x2013 },
        .{ "emdash", 0x2014 },
        .{ "ellipsis", 0x2026 },
        .{ "quoteleft", 0x2018 },
        .{ "quoteright", 0x2019 },
        .{ "quotedblleft", 0x201C },
        .{ "quotedblright", 0x201D },
        .{ "fi", 0xFB01 },
        .{ "fl", 0xFB02 },
        .{ "ff", 0xFB00 },
        .{ "ffi", 0xFB03 },
        .{ "ffl", 0xFB04 },
    };

    inline for (mappings) |mapping| {
        if (std.mem.eql(u8, name, mapping[0])) {
            return mapping[1];
        }
    }

    // Check for "uniXXXX" format
    if (name.len == 7 and std.mem.startsWith(u8, name, "uni")) {
        return std.fmt.parseInt(u21, name[3..7], 16) catch 0;
    }

    // Check for "uXXXXX" format
    if (name.len >= 5 and name.len <= 7 and name[0] == 'u') {
        return std.fmt.parseInt(u21, name[1..], 16) catch 0;
    }

    return 0;
}

// ============================================================================
// STANDARD ENCODING TABLES
// ============================================================================

pub const win_ansi_encoding = blk: {
    var table: [256]u21 = undefined;

    // ASCII range
    for (0..128) |i| {
        table[i] = @intCast(i);
    }

    // Windows-1252 extensions
    table[128] = 0x20AC; // Euro sign
    table[129] = 0;
    table[130] = 0x201A; // Single low-9 quotation mark
    table[131] = 0x0192; // Latin small letter f with hook
    table[132] = 0x201E; // Double low-9 quotation mark
    table[133] = 0x2026; // Horizontal ellipsis
    table[134] = 0x2020; // Dagger
    table[135] = 0x2021; // Double dagger
    table[136] = 0x02C6; // Modifier letter circumflex accent
    table[137] = 0x2030; // Per mille sign
    table[138] = 0x0160; // Latin capital letter S with caron
    table[139] = 0x2039; // Single left-pointing angle quotation mark
    table[140] = 0x0152; // Latin capital ligature OE
    table[141] = 0;
    table[142] = 0x017D; // Latin capital letter Z with caron
    table[143] = 0;
    table[144] = 0;
    table[145] = 0x2018; // Left single quotation mark
    table[146] = 0x2019; // Right single quotation mark
    table[147] = 0x201C; // Left double quotation mark
    table[148] = 0x201D; // Right double quotation mark
    table[149] = 0x2022; // Bullet
    table[150] = 0x2013; // En dash
    table[151] = 0x2014; // Em dash
    table[152] = 0x02DC; // Small tilde
    table[153] = 0x2122; // Trade mark sign
    table[154] = 0x0161; // Latin small letter s with caron
    table[155] = 0x203A; // Single right-pointing angle quotation mark
    table[156] = 0x0153; // Latin small ligature oe
    table[157] = 0;
    table[158] = 0x017E; // Latin small letter z with caron
    table[159] = 0x0178; // Latin capital letter Y with diaeresis

    // Latin-1 Supplement (160-255)
    for (160..256) |i| {
        table[i] = @intCast(i);
    }

    break :blk table;
};

const mac_roman_encoding = blk: {
    var table: [256]u21 = undefined;

    // ASCII range
    for (0..128) |i| {
        table[i] = @intCast(i);
    }

    // Mac Roman extensions (128-255)
    const mac_ext = [_]u21{
        0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
        0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
        0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
        0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
        0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
        0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
        0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
        0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
        0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
        0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
        0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
        0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
        0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
        0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
        0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
        0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
    };

    for (0..128) |i| {
        table[128 + i] = mac_ext[i];
    }

    break :blk table;
};

const standard_encoding = blk: {
    var table: [256]u21 = undefined;

    // Initialize all to 0
    for (&table) |*t| {
        t.* = 0;
    }

    // ASCII letters and digits
    for ('A'..('Z' + 1)) |i| {
        table[i] = @intCast(i);
    }
    for ('a'..('z' + 1)) |i| {
        table[i] = @intCast(i);
    }
    for ('0'..('9' + 1)) |i| {
        table[i] = @intCast(i);
    }

    // Common punctuation
    table[' '] = ' ';
    table['!'] = '!';
    table['"'] = '"';
    table['#'] = '#';
    table['$'] = '$';
    table['%'] = '%';
    table['&'] = '&';
    table['\''] = 0x2019; // quoteright
    table['('] = '(';
    table[')'] = ')';
    table['*'] = '*';
    table['+'] = '+';
    table[','] = ',';
    table['-'] = '-';
    table['.'] = '.';
    table['/'] = '/';
    table[':'] = ':';
    table[';'] = ';';
    table['<'] = '<';
    table['='] = '=';
    table['>'] = '>';
    table['?'] = '?';
    table['@'] = '@';
    table['['] = '[';
    table['\\'] = '\\';
    table[']'] = ']';
    table['^'] = '^';
    table['_'] = '_';
    table['`'] = 0x2018; // quoteleft
    table['{'] = '{';
    table['|'] = '|';
    table['}'] = '}';
    table['~'] = '~';

    break :blk table;
};

const pdf_doc_encoding = blk: {
    var table: [256]u21 = undefined;

    // Start with WinAnsi
    table = win_ansi_encoding;

    // PDFDocEncoding differs in a few places
    table[0x18] = 0x02D8; // breve
    table[0x19] = 0x02C7; // caron
    table[0x1A] = 0x02C6; // circumflex
    table[0x1B] = 0x02D9; // dotaccent
    table[0x1C] = 0x02DD; // hungarumlaut
    table[0x1D] = 0x02DB; // ogonek
    table[0x1E] = 0x02DA; // ring
    table[0x1F] = 0x02DC; // tilde

    break :blk table;
};

// ============================================================================
// TESTS
// ============================================================================

test "WinAnsi decode ASCII" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try enc.decode("Hello", output.writer());
    try std.testing.expectEqualStrings("Hello", output.items);
}

test "WinAnsi decode extended" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    // 0x93 = left double quote, 0x94 = right double quote
    try enc.decode(&[_]u8{ 0x93, 'H', 'i', 0x94 }, output.writer());

    // Should be "Hi" with smart quotes
    try std.testing.expectEqualStrings("\xe2\x80\x9cHi\xe2\x80\x9d", output.items);
}

test "glyph name to unicode" {
    try std.testing.expectEqual(@as(u21, 'A'), glyphNameToUnicode("A"));
    try std.testing.expectEqual(@as(u21, 0x2022), glyphNameToUnicode("bullet"));
    try std.testing.expectEqual(@as(u21, 0xFB01), glyphNameToUnicode("fi"));
    try std.testing.expectEqual(@as(u21, 0x0041), glyphNameToUnicode("uni0041"));
}
