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

## JSON numbers

```k2
#import number_utils;

result := parse_json_number("3.14") catch err {
    return 1;
};
// result.consumed bytes were scanned; result.value holds the f64;
// result.is_integer is false (a '.' or exponent was present).

buf: [32]u8 = .{};
written := format_f64(3.14, buf[:]) catch err {
    return 1;
};
// The first `written` bytes of buf hold the JSON number text.
```

`parse_json_number` scans one RFC 8259 number token (`-? int frac? exp?`) and
reports both bytes consumed and the parsed value. `format_u64`/`format_i64`
write plain decimal integers; `format_f64` writes whole numbers as integers
and searches for the shortest decimal spelling that round-trips back to the
same `f64` via `parse_json_number` (falling back to 17 significant digits).
NaN and Infinity are not valid JSON numbers — check `inspect_f64` first and
pick a float-handling policy (e.g. `null` or a quoted string) before calling
`format_f64` on them.

Note: this is decimal<->binary conversion via straightforward accumulation
(`mantissa * 10^scale`), not a correctly-rounded strtod/Grisu/Ryu — it's
correct for essentially all real-world JSON numbers but last-bit precision
isn't guaranteed.
