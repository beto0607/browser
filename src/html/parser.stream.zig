const std = @import("std");
const io = std.io;
const print = std.debug.print;
const testing = std.testing;
const unicode = std.unicode;
const errors = @import("./parser.errors.zig");

/// This defined the "Input stream" for the tokenizer
/// Receives a byte stream, and transforms it, if needed
/// https://html.spec.whatwg.org/multipage/parsing.html#the-input-byte-stream
pub const HTMLParserInputStream = struct {
    confidence: InputStreamConfidence,
    character_encoding: InputStreamCharacterEncoding,

    reader: io.AnyReader,

    state_flags: InputStreamStateFlags,
    last_item: *InputStreamItem,

    index: u64,
    eof_sent: bool,

    const Self = @This();
    pub fn init(reader: io.AnyReader) HTMLParserInputStream {
        return .{
            .character_encoding = .UTF_8,
            .confidence = .certain,
            .reader = reader,
            .state_flags = .{ .replaced_cr_lf = false },
            .last_item = undefined,
            .index = 0,
            .eof_sent = false,
        };
    }

    pub fn next(self: *Self) !?InputStreamItem {
        if (self.eof_sent) {
            return null;
        }
        self.index += 1;
        const byte = self.reader.readByte() catch {
            self.eof_sent = true;
            return InputStreamItem{ .eof = true, .byte = 0, .code_point = 0 };
        };
        // TODO: add encoding here
        const code_point = self.getCodePoint(byte) catch return null;

        var token = InputStreamItem{
            .byte = byte,
            .code_point = code_point,
            .eof = false,
        };

        self.last_item = &token;
        return token;
    }

    fn getCodePoint(self: *Self, byte: u8) !u21 {
        switch (byte) {
            // newlines normalization
            0x0D => {
                return 0x0A;
            },
            0x0A => {
                if (self.last_item.byte == 0x0D) {
                    self.index += 1;
                    return try self.reader.readByte();
                }
                return byte;
            },
            // continuation bytes
            0xC2...0xDF,
            => {
                const extra_byte = try self.reader.readByte();
                return unicode.utf8Decode2(.{ byte, extra_byte });
            },
            0xe0...0xef => {
                const extra_byte_1 = try self.reader.readByte();
                const extra_byte_2 = try self.reader.readByte();
                return unicode.utf8Decode3(.{ byte, extra_byte_1, extra_byte_2 });
            },
            0xf0...0xf4 => {
                const extra_byte_1 = try self.reader.readByte();
                const extra_byte_2 = try self.reader.readByte();
                const extra_byte_3 = try self.reader.readByte();
                return unicode.utf8Decode4(.{ byte, extra_byte_1, extra_byte_2, extra_byte_3 });
            },
            else => {
                return byte;
            },
        }
    }
};

const InputStreamStateFlags = struct {
    replaced_cr_lf: bool,
};

/// https://html.spec.whatwg.org/multipage/parsing.html#character-encodings
const InputStreamCharacterEncoding = enum {
    UTF_8,
    ISO_8859_2,
    ISO_8859_7,
    ISO_8859_8,
    windows_874,
    windows_1250,
    windows_1251,
    windows_1252,
    windows_1254,
    windows_1255,
    windows_1256,
    windows_1257,
    windows_1258,
    GBK,
    Big5,
    ISO_2022_JP,
    Shift_JIS,
    EUC_KR,
    UTF_16BE,
    UTF_16LE,
    UTF_16BE_LE,
    x_user_defined,
};

const InputStreamConfidence = enum {
    tentative,
    certain,
    irrelevant,
};

pub const InputStreamItem = struct {
    byte: u8,
    code_point: u21,
    eof: bool,
};

test "test" {
    const input =
        "<!DOCTYPE html>\r" ++
        "<html>\n" ++
        "<head><title>Test</title></head>\r\n" ++
        "<body>\n" ++
        "Hello, world!\r" ++
        "</body>\n" ++
        "</html>";
    var stream = io.fixedBufferStream(input);
    const reader = stream.reader().any();
    var input_stream = HTMLParserInputStream.init(reader);

    while (try input_stream.next()) |item| {
        if (item.eof) {
            break;
        }
        var buf: [4]u8 = undefined;
        const len = try unicode.utf8Encode(item.code_point, &buf);
        print("got {d}: {s} ({any})\n", .{ input_stream.index, buf[0..len], item.code_point });
        try testing.expect(item.code_point != 0x0D);
    }
}

test "utf-8 - in 4-byte format" {
    const input = "\xF0\x9F\x98\x80"; // 😀 emoji, 4-byte UTF-8
    var stream = io.fixedBufferStream(input);
    const reader = stream.reader().any();
    var input_stream = HTMLParserInputStream.init(reader);

    while (try input_stream.next()) |item| {
        if (item.eof) {
            break;
        }
        var buf: [4]u8 = undefined;
        const len = try unicode.utf8Encode(item.code_point, &buf);
        print("got {d}: {s} ({any})\n", .{ input_stream.index, buf[0..len], item.code_point });
        try testing.expectEqual(0x1F600, item.code_point);
    }
}
test "utf-8 - in emoji format" {
    const input = "😀";
    var stream = io.fixedBufferStream(input);
    const reader = stream.reader().any();
    var input_stream = HTMLParserInputStream.init(reader);

    while (try input_stream.next()) |item| {
        if (item.eof) {
            break;
        }
        var buf: [4]u8 = undefined;
        const len = try unicode.utf8Encode(item.code_point, &buf);
        print("got {d}: {s} ({any})\n", .{ input_stream.index, buf[0..len], item.code_point });
        try testing.expectEqual(0x1F600, item.code_point);
    }
}
