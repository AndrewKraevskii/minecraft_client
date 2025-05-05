pub fn parse(prefix: [2]u8) ?[3]u8 {
    if (prefix[0] != '§') return null;
    return switch (prefix[1]) {
        '0' => .{ 0x00, 0x00, 0x00 }, // black
        '1' => .{ 0x00, 0x00, 0xAA }, // dark_blue
        '2' => .{ 0x00, 0xAA, 0x00 }, // dark_green
        '3' => .{ 0x00, 0xAA, 0xAA }, // dark_aqua
        '4' => .{ 0xAA, 0x00, 0x00 }, // dark_red
        '5' => .{ 0xAA, 0x00, 0xAA }, // dark_purple
        '6' => .{ 0xFF, 0xAA, 0x00 }, // gold
        '7' => .{ 0xAA, 0xAA, 0xAA }, // gray
        '8' => .{ 0x55, 0x55, 0x55 }, // dark_gray
        '9' => .{ 0x55, 0x55, 0xFF }, // blue
        'a' => .{ 0x55, 0xFF, 0x55 }, // green
        'b' => .{ 0x55, 0xFF, 0xFF }, // aqua
        'c' => .{ 0xFF, 0x55, 0x55 }, // red
        'd' => .{ 0xFF, 0x55, 0xFF }, // light_purple
        'e' => .{ 0xFF, 0xFF, 0x55 }, // yellow
        'f' => .{ 0xFF, 0xFF, 0xFF }, // white
        else => null,
    };
}
// TODO: more styling
// Obfuscated    §k
// Bold          §l
// Strikethrough §m
// Underline     §n
// Italic        §o
// Reset         §r
