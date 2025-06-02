import json

def convert_unicode_escape_to_zig(char_string: str) -> str:
    if not char_string:
        return "" # Handle empty string case

    # Python's string will already have correctly interpreted \uXXXX escapes.
    # We just need the ordinal value of the first character.
    # If it's a surrogate pair, ord() on the first char will give the high surrogate,
    # but ord() on the combined character will give the true codepoint.
    # The simplest way to get the single code point for a potential surrogate pair
    # is to treat the string as containing only that character.

    # ord() correctly handles characters outside the BMP (e.g., U+1D538)
    # when they are represented as a single Python character (which Python does internally).
    code_point = ord(char_string[0])

    # If the string contains multiple characters (e.g., combined emojis),
    # this will only take the first one. For HTML entities, it's usually one char.
    if len(char_string) > 1 and code_point >= 0xD800 and code_point <= 0xDBFF:
        # This handles cases where Python might present a surrogate pair as two characters
        # (though typically it combines them). We rely on ord() to give us the full code point.
        # This check is mostly for robustness, as ord() on a single combined char is usually enough.
        try:
            # Re-encoding to UTF-16 then back to string to ensure Python's internal representation
            # has correctly combined surrogates, then ord() should work.
            # This is often redundant if the JSON was parsed correctly, but good for safety.
            combined_char = char_string.encode('utf-16-be').decode('utf-16-be')
            code_point = ord(combined_char)
        except UnicodeDecodeError:
            # Fallback if there's an issue, stick to the first char's ord
            pass


    return f"\\u{{{code_point:X}}}"


def generate_zig_entity_array(input_file: str, output_struct_name: str = "HtmlEntity") -> str:
    """
    Loads entity data from a JSON file and generates a Zig comptime array.
    """
    try:
        with open(input_file, 'r', encoding='utf-8') as f:
            entities = json.load(f)
    except FileNotFoundError:
        return f"Error: Input file '{input_file}' not found."
    except json.JSONDecodeError as e:
        return f"Error decoding JSON from '{input_file}': {e}"

    output_lines = [
        f"const {output_struct_name} = struct {{",
        "    name: []const u8,",
        "    codepoints: []const u32,",
        "    characters: []const u8,",
        "};",
        "",
        f"pub const htmlEntities = comptime [_]{output_struct_name}{{"
    ]

    for name, data in entities.items():
        codepoints = data["codepoints"]
        characters_raw = data["characters"]

        # Convert codepoints array to Zig format
        codepoints_zig = f"&[_]u32{{{', '.join(map(str, codepoints))}}}"

        # Convert characters string to Zig Unicode escape (e.g., "\u{1D538}")
        # Ensure the string itself is UTF-8 encoded when placed in Zig's `[]const u8`
        # and using the correct Unicode escape syntax.
        # Python's `json.load` will correctly interpret `\uXXXX` sequences into
        # native Python Unicode strings.
        # We need to ensure the *output string* in Zig is correctly escaped for literal use.

        # If characters_raw represents a single logical character,
        # we convert it to the \u{XXXXX} format.
        # If it's more complex (e.g., multiple characters or combining marks),
        # we might just escape the literal characters.
        # For HTML entities, it's almost always a single logical character.
        if characters_raw:
            # Convert to Zig's `\u{}` escape. `json.load` already decoded the `\uXXXX`
            # so `characters_raw` is a Python Unicode string.
            zig_characters_escape = convert_unicode_escape_to_zig(characters_raw)
        else:
            zig_characters_escape = "" # For empty character strings

        output_lines.append(
            f"    .{{ .name = \"{name}\", .codepoints = {codepoints_zig}, .characters = \"{zig_characters_escape}\" }},"
        )

    output_lines.append("};")

    return "\n".join(output_lines)

if __name__ == "__main__":
    zig_code = generate_zig_entity_array("entities.json")
    print(zig_code)

    # Optional: Save to a .zig file
    # with open("html_entities.zig", "w", encoding="utf-8") as f:
    #     f.write(zig_code)
    # print("\nGenerated html_entities.zig")
