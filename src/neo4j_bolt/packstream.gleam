//// PackStream: the binary serialisation format used by Neo4j Bolt.
////
//// Everything is big-endian. Every value starts with a marker byte; the high
//// nibble says what the value is and the low nibble is often a small size.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/list
import gleam/result

pub type Value {
  PNull
  PBool(Bool)
  PInt(Int)
  PFloat(Float)
  PString(String)
  PBytes(BitArray)
  PList(List(Value))
  PMap(Dict(String, Value))
  /// A structure: signature byte plus fields. Nodes, relationships, dates,
  /// and every Bolt message are structures.
  PStruct(signature: Int, fields: List(Value))
}

pub type DecodeError {
  Truncated
  InvalidMarker(Int)
  InvalidUtf8
  InvalidMapKey
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

pub fn encode(value: Value) -> BitArray {
  case value {
    PNull -> <<0xC0>>
    PBool(False) -> <<0xC2>>
    PBool(True) -> <<0xC3>>
    PInt(n) -> encode_int(n)
    PFloat(f) -> <<0xC1, f:float>>
    PString(s) -> {
      let bytes = bit_array.from_string(s)
      let header = tiny_or_sized_header(0x80, 0xD0, bit_array.byte_size(bytes))
      <<header:bits, bytes:bits>>
    }
    PBytes(bytes) -> {
      // Bytes have no "tiny" form.
      let header = sized_header(0xCC, bit_array.byte_size(bytes))
      <<header:bits, bytes:bits>>
    }
    PList(items) -> {
      let header = tiny_or_sized_header(0x90, 0xD4, list.length(items))
      let body = items |> list.map(encode) |> bit_array.concat
      <<header:bits, body:bits>>
    }
    PMap(entries) -> {
      let pairs = dict.to_list(entries)
      let header = tiny_or_sized_header(0xA0, 0xD8, list.length(pairs))
      let body =
        pairs
        |> list.map(fn(pair) {
          <<encode(PString(pair.0)):bits, encode(pair.1):bits>>
        })
        |> bit_array.concat
      <<header:bits, body:bits>>
    }
    PStruct(signature, fields) -> {
      // Structures with more than 15 fields are not used by Bolt.
      let marker = 0xB0 + list.length(fields)
      let body = fields |> list.map(encode) |> bit_array.concat
      <<marker:size(8), signature:size(8), body:bits>>
    }
  }
}

fn encode_int(n: Int) -> BitArray {
  case n {
    _ if n >= -16 && n <= 127 -> <<n:size(8)>>
    _ if n >= -128 && n <= 127 -> <<0xC8, n:size(8)>>
    _ if n >= -32_768 && n <= 32_767 -> <<0xC9, n:size(16)>>
    _ if n >= -2_147_483_648 && n <= 2_147_483_647 -> <<0xCA, n:size(32)>>
    _ -> <<0xCB, n:size(64)>>
  }
}

/// Header for types that have a "tiny" form (sizes 0..15 packed into the marker).
fn tiny_or_sized_header(tiny_base: Int, marker8: Int, size: Int) -> BitArray {
  case size < 16 {
    True -> {
      let marker = tiny_base + size
      <<marker:size(8)>>
    }
    False -> sized_header(marker8, size)
  }
}

/// Marker + explicit size. `marker8` is the 8-bit-size marker; the 16 and 32
/// bit variants are the next two marker values.
fn sized_header(marker8: Int, size: Int) -> BitArray {
  case size {
    _ if size < 256 -> <<marker8:size(8), size:size(8)>>
    _ if size < 65_536 -> {
      let marker = marker8 + 1
      <<marker:size(8), size:size(16)>>
    }
    _ -> {
      let marker = marker8 + 2
      <<marker:size(8), size:size(32)>>
    }
  }
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Decode one value from the front of `bits`, returning the value and the
/// bytes that were not consumed.
pub fn decode(bits: BitArray) -> Result(#(Value, BitArray), DecodeError) {
  case bits {
    <<marker:size(8), rest:bytes>> -> decode_marker(marker, rest)
    _ -> Error(Truncated)
  }
}

type Kind {
  StringKind
  BytesKind
  ListKind
  MapKind
}

fn decode_marker(
  marker: Int,
  rest: BitArray,
) -> Result(#(Value, BitArray), DecodeError) {
  case marker {
    0xC0 -> Ok(#(PNull, rest))
    0xC2 -> Ok(#(PBool(False), rest))
    0xC3 -> Ok(#(PBool(True), rest))
    0xC1 ->
      case rest {
        <<f:float, remaining:bytes>> -> Ok(#(PFloat(f), remaining))
        _ -> Error(Truncated)
      }
    0xC8 ->
      case rest {
        <<n:signed-size(8), remaining:bytes>> -> Ok(#(PInt(n), remaining))
        _ -> Error(Truncated)
      }
    0xC9 ->
      case rest {
        <<n:signed-size(16), remaining:bytes>> -> Ok(#(PInt(n), remaining))
        _ -> Error(Truncated)
      }
    0xCA ->
      case rest {
        <<n:signed-size(32), remaining:bytes>> -> Ok(#(PInt(n), remaining))
        _ -> Error(Truncated)
      }
    0xCB ->
      case rest {
        <<n:signed-size(64), remaining:bytes>> -> Ok(#(PInt(n), remaining))
        _ -> Error(Truncated)
      }
    0xCC | 0xCD | 0xCE -> read_sized(BytesKind, marker - 0xCC, rest)
    0xD0 | 0xD1 | 0xD2 -> read_sized(StringKind, marker - 0xD0, rest)
    0xD4 | 0xD5 | 0xD6 -> read_sized(ListKind, marker - 0xD4, rest)
    0xD8 | 0xD9 | 0xDA -> read_sized(MapKind, marker - 0xD8, rest)
    m if m <= 0x7F -> Ok(#(PInt(m), rest))
    m if m >= 0xF0 -> Ok(#(PInt(m - 256), rest))
    m if m >= 0x80 && m <= 0x8F -> read_body(StringKind, m - 0x80, rest)
    m if m >= 0x90 && m <= 0x9F -> read_body(ListKind, m - 0x90, rest)
    m if m >= 0xA0 && m <= 0xAF -> read_body(MapKind, m - 0xA0, rest)
    m if m >= 0xB0 && m <= 0xBF -> decode_struct(m - 0xB0, rest)
    m -> Error(InvalidMarker(m))
  }
}

/// Read a 1, 2 or 4 byte size prefix, then the body.
fn read_sized(
  kind: Kind,
  width_index: Int,
  rest: BitArray,
) -> Result(#(Value, BitArray), DecodeError) {
  use #(count, remaining) <- result.try(case width_index, rest {
    0, <<n:size(8), r:bytes>> -> Ok(#(n, r))
    1, <<n:size(16), r:bytes>> -> Ok(#(n, r))
    2, <<n:size(32), r:bytes>> -> Ok(#(n, r))
    _, _ -> Error(Truncated)
  })
  read_body(kind, count, remaining)
}

/// `count` is a byte length for strings and bytes, an item count for lists,
/// and a pair count for maps.
fn read_body(
  kind: Kind,
  count: Int,
  rest: BitArray,
) -> Result(#(Value, BitArray), DecodeError) {
  case kind {
    StringKind -> {
      use #(bytes, remaining) <- result.try(take(rest, count))
      use text <- result.try(
        bit_array.to_string(bytes) |> result.replace_error(InvalidUtf8),
      )
      Ok(#(PString(text), remaining))
    }
    BytesKind -> {
      use #(bytes, remaining) <- result.try(take(rest, count))
      Ok(#(PBytes(bytes), remaining))
    }
    ListKind -> {
      use #(items, remaining) <- result.try(decode_many(rest, count, []))
      Ok(#(PList(items), remaining))
    }
    MapKind -> {
      use #(flat, remaining) <- result.try(decode_many(rest, count * 2, []))
      use pairs <- result.try(pair_up(flat, []))
      Ok(#(PMap(dict.from_list(pairs)), remaining))
    }
  }
}

fn decode_struct(
  field_count: Int,
  rest: BitArray,
) -> Result(#(Value, BitArray), DecodeError) {
  case rest {
    <<signature:size(8), after_signature:bytes>> -> {
      use #(fields, remaining) <- result.try(
        decode_many(after_signature, field_count, []),
      )
      Ok(#(PStruct(signature, fields), remaining))
    }
    _ -> Error(Truncated)
  }
}

fn decode_many(
  bits: BitArray,
  count: Int,
  acc: List(Value),
) -> Result(#(List(Value), BitArray), DecodeError) {
  case count {
    0 -> Ok(#(list.reverse(acc), bits))
    _ -> {
      use #(value, remaining) <- result.try(decode(bits))
      decode_many(remaining, count - 1, [value, ..acc])
    }
  }
}

fn pair_up(
  flat: List(Value),
  acc: List(#(String, Value)),
) -> Result(List(#(String, Value)), DecodeError) {
  case flat {
    [] -> Ok(list.reverse(acc))
    [PString(key), value, ..rest] -> pair_up(rest, [#(key, value), ..acc])
    _ -> Error(InvalidMapKey)
  }
}

fn take(bits: BitArray, n: Int) -> Result(#(BitArray, BitArray), DecodeError) {
  let total = bit_array.byte_size(bits)
  case n <= total {
    False -> Error(Truncated)
    True -> {
      use head <- result.try(
        bit_array.slice(bits, 0, n) |> result.replace_error(Truncated),
      )
      use tail <- result.try(
        bit_array.slice(bits, n, total - n) |> result.replace_error(Truncated),
      )
      Ok(#(head, tail))
    }
  }
}

// ---------------------------------------------------------------------------
// Small accessors, handy when picking apart responses
// ---------------------------------------------------------------------------

pub fn as_string(value: Value) -> Result(String, Nil) {
  case value {
    PString(s) -> Ok(s)
    _ -> Error(Nil)
  }
}

pub fn as_int(value: Value) -> Result(Int, Nil) {
  case value {
    PInt(n) -> Ok(n)
    _ -> Error(Nil)
  }
}

pub fn as_float(value: Value) -> Result(Float, Nil) {
  case value {
    PFloat(f) -> Ok(f)
    _ -> Error(Nil)
  }
}

pub fn as_bool(value: Value) -> Result(Bool, Nil) {
  case value {
    PBool(b) -> Ok(b)
    _ -> Error(Nil)
  }
}

pub fn as_list(value: Value) -> Result(List(Value), Nil) {
  case value {
    PList(items) -> Ok(items)
    _ -> Error(Nil)
  }
}

pub fn as_map(value: Value) -> Result(Dict(String, Value), Nil) {
  case value {
    PMap(entries) -> Ok(entries)
    _ -> Error(Nil)
  }
}
