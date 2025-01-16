# k2son utilities

The current string utilities are allocation-free. Callers provide output
buffers, and functions return byte counts instead of allocating strings.

## JSON strings

```k2
#import string_utils;

decoded: [256]u8 = .{};
result := parse_json_string("\"hello\\n\"", decoded[:]) catch err {
    return 1;
};
// The first result.written bytes of decoded contain the decoded string.

escaped: [256]u8 = .{};
written := escape_json_string("hello\n", escaped[:]) catch err {
    return 1;
};
// The first written bytes of escaped contain the JSON string.
```

`parse_json_string` accepts the surrounding quotes and reports both input bytes
consumed and output bytes written. It handles JSON escapes, `\uXXXX`, UTF-16
surrogate pairs, and UTF-8 encoding.

`escape_json_string` writes surrounding quotes, escapes JSON control characters,
and preserves non-ASCII UTF-8 bytes.

## Float inspection

```k2
#import float_utils;

info := inspect_f64(value);
if info.is_nan { /* ... */ }
if info.is_infinity { /* ... */ }
if info.is_negative { /* includes negative zero */ }
```

`f64_bits` and `f64_from_bits` provide allocation-free IEEE-754 bit
reinterpretation.
