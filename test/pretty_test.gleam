import gleam/dict
import gleam/list
import gleam/string
import neo4j_bolt/connection
import neo4j_bolt/graph
import neo4j_bolt/packstream.{
  PBool, PBytes, PFloat, PInt, PList, PMap, PNull, PString, PStruct,
}
import neo4j_bolt/pretty

// --- Values ----------------------------------------------------------------

pub fn scalars_test() {
  let assert "null" = pretty.value(PNull)
  let assert "true" = pretty.value(PBool(True))
  let assert "false" = pretty.value(PBool(False))
  let assert "42" = pretty.value(PInt(42))
  let assert "-7" = pretty.value(PInt(-7))
  let assert "1.5" = pretty.value(PFloat(1.5))
  let assert "<3 bytes>" = pretty.value(PBytes(<<1, 2, 3>>))
}

pub fn strings_are_quoted_and_escaped_test() {
  let assert "\"hello\"" = pretty.value(PString("hello"))
  let assert "\"say \\\"hi\\\"\"" = pretty.value(PString("say \"hi\""))
  let assert "\"a\\nb\"" = pretty.value(PString("a\nb"))
  let assert "\"Zoë ✓\"" = pretty.value(PString("Zoë ✓"))
}

pub fn lists_and_maps_test() {
  let assert "[1, \"a\", null]" =
    pretty.value(PList([PInt(1), PString("a"), PNull]))
  let assert "[]" = pretty.value(PList([]))
  let assert "{}" = pretty.value(PMap(dict.new()))
  // keys come out sorted
  let assert "{age: 30, name: \"Alice\"}" =
    pretty.value(
      PMap(dict.from_list([#("name", PString("Alice")), #("age", PInt(30))])),
    )
}

pub fn node_test() {
  let node =
    PStruct(0x4E, [
      PInt(4),
      PList([PString("Person"), PString("Employee")]),
      PMap(dict.from_list([#("name", PString("Zoë"))])),
      PString("4:abc:4"),
    ])
  let assert "(:Person:Employee {name: \"Zoë\"})" = pretty.value(node)

  let bare =
    PStruct(0x4E, [
      PInt(5),
      PList([PString("Person")]),
      PMap(dict.new()),
      PString("4:abc:5"),
    ])
  let assert "(:Person)" = pretty.value(bare)
}

pub fn relationship_test() {
  let rel =
    PStruct(0x52, [
      PInt(7),
      PInt(1),
      PInt(2),
      PString("KNOWS"),
      PMap(dict.from_list([#("since", PInt(2020))])),
      PString("5:abc:7"),
      PString("4:abc:1"),
      PString("4:abc:2"),
    ])
  let assert "[:KNOWS {since: 2020}]" = pretty.value(rel)
}

pub fn unknown_struct_test() {
  let assert "Struct(0x99, [1])" = pretty.value(PStruct(0x99, [PInt(1)]))
}

// --- Tables ----------------------------------------------------------------

fn result(fields, rows, stats) -> connection.QueryResult {
  connection.QueryResult(
    fields: fields,
    rows: rows,
    summary: dict.from_list([#("stats", PMap(dict.from_list(stats)))]),
  )
}

pub fn table_test() {
  let output =
    pretty.table(
      result(
        ["name", "age"],
        [[PString("Alice"), PInt(30)], [PString("Bob"), PInt(5)]],
        [],
      ),
    )
  let expected =
    string.join(
      [
        "+---------+-----+",
        "| name    | age |",
        "+---------+-----+",
        "| \"Alice\" | 30  |",
        "| \"Bob\"   | 5   |",
        "+---------+-----+",
        "2 rows",
      ],
      "\n",
    )
  let assert True = output == expected
}

pub fn table_with_no_rows_test() {
  let output = pretty.table(result(["n"], [], []))
  let expected = string.join(["+---+", "| n |", "+---+", "0 rows"], "\n")
  let assert True = output == expected
}

pub fn single_row_is_singular_test() {
  let output = pretty.table(result(["n"], [[PInt(1)]], []))
  let assert True = string.ends_with(output, "1 row")
}

pub fn table_appends_update_summary_test() {
  let output =
    pretty.table(
      result(["n"], [[PInt(1)]], [
        #("nodes-created", PInt(1)),
        #("properties-set", PInt(2)),
      ]),
    )
  let assert True =
    string.ends_with(output, "1 row\nCreated 1 node, set 2 properties")
}

pub fn write_without_return_shows_only_summary_test() {
  let output =
    pretty.table(
      result([], [], [
        #("nodes-created", PInt(1)),
        #("labels-added", PInt(1)),
        #("properties-set", PInt(1)),
      ]),
    )
  let assert "Created 1 node, set 1 property, added 1 label" = output
}

pub fn write_with_no_changes_says_ok_test() {
  let assert "OK" = pretty.table(result([], [], []))
}

pub fn long_cells_are_truncated_test() {
  let long = string.repeat("x", 500)
  let output = pretty.table(result(["s"], [[PString(long)]], []))
  let assert True = string.contains(output, "…")
  let assert False = string.contains(output, string.repeat("x", 61))
}

// --- Errors ----------------------------------------------------------------

pub fn error_messages_test() {
  let assert "Neo.ClientError.Statement.SyntaxError: bad query" =
    pretty.error(connection.ServerFailure(
      "Neo.ClientError.Statement.SyntaxError",
      "bad query",
    ))
  let assert "Missing environment variable NEO4J_PASSWORD" =
    pretty.error(connection.MissingConfiguration("NEO4J_PASSWORD"))
  let assert "Connection problem: Econnrefused" =
    pretty.error(connection.TransportError("Econnrefused"))
}

pub fn path_test() {
  let will =
    PStruct(0x4E, [
      PInt(0),
      PList([PString("Person")]),
      PMap(dict.from_list([#("name", PString("Will"))])),
      PString("4:abc:0"),
    ])
  let maya =
    PStruct(0x4E, [
      PInt(1),
      PList([PString("Person")]),
      PMap(dict.from_list([#("name", PString("Maya"))])),
      PString("4:abc:1"),
    ])
  let follows =
    PStruct(0x72, [
      PInt(0),
      PString("FOLLOWS"),
      PMap(dict.new()),
      PString("5:abc:0"),
    ])
  let path =
    PStruct(0x50, [
      PList([will, maya]),
      PList([follows]),
      PList([PInt(1), PInt(1)]),
    ])

  let assert Ok(decoded) = graph.path(path)
  let assert 2 = list.length(decoded.nodes)
  let assert 1 = list.length(decoded.relationships)
  let assert Ok(relationship) = list.first(decoded.relationships)
  let assert "FOLLOWS" = relationship.kind
}
