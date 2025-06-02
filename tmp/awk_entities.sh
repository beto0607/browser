#!/bin/zsh
# awk 'match($0, /"&[^"]+"/) {
#     entity = substr($0, RSTART+1, RLENGTH-2);
#
#     match($0, /"codepoints": *\[[^]]+\]/);
#     codepoints_raw = substr($0, RSTART, RLENGTH);
#     gsub(/.*\[/, "", codepoints_raw);  # Remove everything before and including [
#     gsub(/\].*/, "", codepoints_raw);  # Remove everything after and including ]
#     gsub(/ /, "", codepoints_raw);     # Remove spaces
#
#     match($0, /"characters": *"([^"]+)"/, chars);
#     n = split(chars[1], c, /\\u/);
#     ustr = "";
#     for (i = 2; i <= n; ++i) {
#         ustr = ustr "\\u{" toupper(c[i]) "}";
#     }
#
#     printf "    .{ \"%s\", .{ .codepoints = &[_]u32{%s}, .characters = \"%s\" } },\n", entity, codepoints_raw, ustr;
# }' $1
# awk '
# function utf16_to_utf8(high, low) {
#     # Convert surrogate pair to codepoint
#     high = strtonum("0x" high)
#     low = strtonum("0x" low)
#     codepoint = 0x10000 + ((high - 0xD800) * 1024) + (low - 0xDC00)
#     return sprintf("\\u{%X}", codepoint)
# }
#
# function hex_escape(h) {
#     return sprintf("\\u{%s}", toupper(h))
# }
#
# match($0, /"&[^"]+"/) {
#     entity = substr($0, RSTART+1, RLENGTH-2)
#
#     match($0, /"codepoints": *\[[^]]+\]/)
#     codepoints_raw = substr($0, RSTART, RLENGTH)
#     gsub(/.*\[/, "", codepoints_raw)
#     gsub(/\].*/, "", codepoints_raw)
#     gsub(/ /, "", codepoints_raw)
#
#     match($0, /"characters": *"([^"]+)"/, chars)
#     split(chars[1], units, /\\u/)
#
#     ustr = ""
#     i = 2
#     while (i <= length(units)) {
#         if (units[i] ~ /^[dD]8[0-9A-Fa-f]{2}$/ && i < length(units) && units[i+1] ~ /^[dD][c-fC-F][0-9A-Fa-f]{2}$/) {
#             # surrogate pair
#             ustr = ustr utf16_to_utf8(units[i], units[i+1])
#             i += 2
#         } else {
#             # BMP character
#             ustr = ustr hex_escape(units[i])
#             i++
#         }
#     }
#
#     printf "    .{ \"%s\", .{ .codepoints = &[_]u32{%s}, .characters = \"%s\" } },\n", entity, codepoints_raw, ustr
# }
# ' $1


awk '{
    # Preserve leading spaces and capture the content within the JSON object
    match($0, /^\s*"(.*)": \{ "codepoints": \[([0-9]+)\], "characters": "(.*)" \},?/, arr);

    if (arr[1] && arr[2] && arr[3]) {
        # Extract captured groups
        name = arr[1];
        codepoints = arr[2];
        characters = arr[3];

        # Replace the specific UTF-16 surrogate pair with the Zig Unicode escape
        # This is a direct string replacement for this specific case.
        # If you have many different surrogate pairs, this approach wont scale.
        gsub(/\\uD835\\uDD38/, "\\u{1D538}", characters);

        # Construct the new output format
        printf "%s.{ .name = \"%s\", .codepoints = &[_]u32{%s}, .characters = \"%s\" },\n",
               gensub(/\S.*$/, "", 1, $0), # Extract leading whitespace
               name,
               codepoints,
               characters;
    } else {
        # If the pattern doesnt match, print the line as is (or handle error)
        print $0;
    }
}' $1
