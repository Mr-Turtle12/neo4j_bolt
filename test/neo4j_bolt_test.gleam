import gleam/bit_array
import gleam/dict
import gleam/result
import gleam/string
import gleeunit
import neo4j_bolt/connection
import neo4j_bolt/graph
import neo4j_bolt/packstream.{
  PBool, PBytes, PFloat, PInt, PList, PMap, PNull, PString, PStruct,
}
import neo4j_bolt/parameters
import neo4j_bolt/row

pub fn main() {
  gleeunit.main()
}

// --- Known byte vectors from the PackStream spec ---------------------------

pub fn encode_null_and_bools_test() {
  let assert <<0xC0>> = packstream.encode(PNull)
  let assert <<0xC2>> = packstream.encode(PBool(False))
  let assert <<0xC3>> = packstream.encode(PBool(True))
}

pub fn encode_ints_test() {
  let assert <<0x01>> = packstream.encode(PInt(1))
  let assert <<0x00>> = packstream.encode(PInt(0))
  let assert <<0xF0>> = packstream.encode(PInt(-16))
  let assert <<0xC8, 0xEF>> = packstream.encode(PInt(-17))
  let assert <<0xC9, 0x03, 0xE8>> = packstream.encode(PInt(1000))
  let assert <<0xCA, 0x00, 0x01, 0x86, 0xA0>> = packstream.encode(PInt(100_000))
}

pub fn encode_float_test() {
  let assert <<0xC1, 0x3F, 0xF1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A>> =
    packstream.encode(PFloat(1.1))
}

pub fn encode_strings_test() {
  let assert <<0x80>> = packstream.encode(PString(""))
  let assert <<0x81, 0x41>> = packstream.encode(PString("A"))
  // 16 bytes no longer fits the tiny form
  let sixteen = string.repeat("a", 16)
  let assert <<0xD0, 0x10, _:bytes>> = packstream.encode(PString(sixteen))
}

pub fn encode_collections_test() {
  let assert <<0x90>> = packstream.encode(PList([]))
  let assert <<0x93, 0x01, 0x02, 0x03>> =
    packstream.encode(PList([PInt(1), PInt(2), PInt(3)]))
  let assert <<0xA1, 0x81, 0x61, 0x01>> =
    packstream.encode(PMap(dict.from_list([#("a", PInt(1))])))
}

pub fn encode_struct_test() {
  let assert <<0xB1, 0x01, 0x2A>> = packstream.encode(PStruct(0x01, [PInt(42)]))
}

pub fn encode_bytes_has_no_tiny_form_test() {
  let assert <<0xCC, 0x02, 0x01, 0x02>> = packstream.encode(PBytes(<<1, 2>>))
}

pub fn parameter_helpers_test() {
  let values =
    parameters.from_list([
      #("name", parameters.string("Alice")),
      #("age", parameters.int(30)),
      #("score", parameters.float(4.5)),
      #("active", parameters.bool(True)),
      #("missing", parameters.null()),
    ])

  let assert Ok(PString("Alice")) = dict.get(values, "name")
  let assert Ok(PInt(30)) = dict.get(values, "age")
  let assert Ok(PFloat(4.5)) = dict.get(values, "score")
  let assert Ok(PBool(True)) = dict.get(values, "active")
  let assert Ok(PNull) = dict.get(values, "missing")
}

pub fn encode_sized_byte_array_boundaries_test() {
  let bytes_255 = string.repeat("x", 255) |> bit_array.from_string
  let bytes_256 = string.repeat("x", 256) |> bit_array.from_string
  let bytes_65536 = string.repeat("x", 65_536) |> bit_array.from_string
  let assert <<0xCC, 255:size(8), _:bytes>> =
    packstream.encode(PBytes(bytes_255))
  let assert <<0xCD, 256:size(16), _:bytes>> =
    packstream.encode(PBytes(bytes_256))
  let assert <<0xCE, 65_536:size(32), _:bytes>> =
    packstream.encode(PBytes(bytes_65536))
}

// --- Round trips -----------------------------------------------------------

fn round_trip(value: packstream.Value) {
  let assert Ok(#(decoded, <<>>)) = packstream.decode(packstream.encode(value))
  let assert True = decoded == value
}

pub fn round_trip_scalars_test() {
  round_trip(PNull)
  round_trip(PBool(True))
  round_trip(PInt(0))
  round_trip(PInt(-1))
  round_trip(PInt(-16))
  round_trip(PInt(-17))
  round_trip(PInt(127))
  round_trip(PInt(128))
  round_trip(PInt(-129))
  round_trip(PInt(32_767))
  round_trip(PInt(-32_769))
  round_trip(PInt(2_147_483_647))
  round_trip(PInt(2_147_483_648))
  round_trip(PInt(-9_223_372_036_854_775_808))
  round_trip(PFloat(-3.5))
  round_trip(PString("héllo wörld ✓"))
  round_trip(PBytes(<<0, 1, 2, 255>>))
}

pub fn round_trip_large_test() {
  round_trip(PString(string.repeat("x", 300)))
  round_trip(PString(string.repeat("x", 70_000)))
}

pub fn round_trip_nested_test() {
  round_trip(
    PStruct(0x4E, [
      PInt(1),
      PList([PString("Person")]),
      PMap(dict.from_list([#("name", PString("Alice")), #("age", PInt(30))])),
      PString("4:abc:1"),
    ]),
  )
}

pub fn decode_leaves_remaining_bytes_test() {
  let assert Ok(#(PInt(1), <<0x02>>)) = packstream.decode(<<0x01, 0x02>>)
}

pub fn decode_truncated_test() {
  let assert Error(packstream.Truncated) = packstream.decode(<<0x85, 0x41>>)
  let assert Error(packstream.Truncated) = packstream.decode(<<>>)
}

pub fn decode_invalid_values_test() {
  let assert Error(packstream.InvalidMarker(0xC4)) = packstream.decode(<<0xC4>>)
  let assert Error(packstream.InvalidUtf8) = packstream.decode(<<0x81, 0xFF>>)
  let assert Error(packstream.InvalidMapKey) =
    packstream.decode(<<0xA1, 0x01, 0x02>>)
}

pub fn config_validation_test() {
  let config = connection.new_config("neo4j", "password")
  let assert Ok(config) = connection.validate_config(config)
  let assert Error(connection.InvalidConfiguration("NEO4J_PORT")) =
    connection.validate_config(connection.Config(..config, port: 65_536))
  let assert Error(connection.InvalidConfiguration("NEO4J_PORT")) =
    connection.validate_config(connection.Config(..config, port: 0))
  let assert Error(connection.InvalidConfiguration("NEO4J_HOST")) =
    connection.validate_config(connection.Config(..config, host: ""))
  let assert Error(connection.InvalidConfiguration("NEO4J_TIMEOUT_MS")) =
    connection.validate_config(connection.Config(..config, timeout_ms: 0))
  let assert Error(connection.InvalidConfiguration("NEO4J_DATABASE")) =
    connection.validate_config(connection.Config(..config, database: ""))
}

pub fn graph_decoders_test() {
  let node_value =
    PStruct(0x4E, [
      PInt(4),
      PList([PString("Person")]),
      PMap(dict.from_list([#("name", PString("Ada"))])),
      PString("4:db:4"),
    ])
  let assert Ok(node) = graph.node(node_value)
  let assert "4:db:4" = node.element_id
  let assert ["Person"] = node.labels
  let assert Error(Nil) = graph.node(PStruct(0x4E, [PInt(4)]))

  let relationship_value =
    PStruct(0x52, [
      PInt(7),
      PInt(4),
      PInt(9),
      PString("KNOWS"),
      PMap(dict.new()),
      PString("5:db:7"),
      PString("4:db:4"),
      PString("4:db:9"),
    ])
  let assert Ok(relationship) = graph.relationship(relationship_value)
  let assert "KNOWS" = relationship.kind
  let assert "4:db:4" = relationship.start_element_id
  let assert Error(Nil) =
    graph.relationship(PStruct(0x52, [PInt(7), PString("KNOWS")]))
}

pub fn to_maps_test() {
  let result =
    connection.QueryResult(
      fields: ["username", "rating"],
      rows: [[PString("Maya"), PInt(5)]],
      summary: dict.new(),
    )

  let assert [row] = connection.to_maps(result)
  let assert Ok(PString("Maya")) = dict.get(row, "username")
  let assert Ok(PInt(5)) = dict.get(row, "rating")
}

pub fn row_accessors_test() {
  let values =
    dict.from_list([
      #("username", PString("Maya")),
      #("integer_rating", PInt(5)),
      #("decimal_rating", PFloat(4.5)),
    ])

  let assert Ok("Maya") = row.get_string(values, "username")
  let assert Ok(5) = row.get_int(values, "integer_rating")
  let assert Ok(row.Decimal(4.5)) = row.get_number(values, "decimal_rating")
  let assert Ok("5") =
    row.get_number(values, "integer_rating") |> result.map(row.number_to_string)
}

pub fn row_accessor_errors_test() {
  let values = dict.from_list([#("rating", PString("five"))])

  let assert Error(row.MissingColumn("username")) =
    row.get_string(values, "username")
  let assert Error(row.UnexpectedType("rating", "number", "string")) =
    row.get_number(values, "rating")
}
