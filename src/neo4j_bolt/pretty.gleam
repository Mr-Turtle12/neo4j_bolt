//// Human-readable output for values, query results and errors.
////
//// Intended for debugging, logs and command-line tools. For anything a
//// program has to parse, work with the `Value` types directly instead.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import neo4j_bolt/connection
import neo4j_bolt/graph
import neo4j_bolt/packstream.{
  type Value, PBool, PBytes, PFloat, PInt, PList, PMap, PNull, PString, PStruct,
}

/// Cells longer than this are shortened in `table`.
pub const default_max_cell_width: Int = 60

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

/// Render one value. Nodes and relationships use Cypher-style notation,
/// map keys are sorted so the output is stable.
pub fn value(v: Value) -> String {
  case v {
    PNull -> "null"
    PBool(True) -> "true"
    PBool(False) -> "false"
    PInt(n) -> int.to_string(n)
    PFloat(f) -> float.to_string(f)
    PString(s) -> quote(s)
    PBytes(bytes) ->
      "<" <> int.to_string(bit_array.byte_size(bytes)) <> " bytes>"
    PList(items) -> "[" <> string.join(list.map(items, value), ", ") <> "]"
    PMap(entries) -> properties(entries)
    PStruct(signature, fields) -> structure(v, signature, fields)
  }
}

fn structure(v: Value, signature: Int, fields: List(Value)) -> String {
  case
    graph.path(v),
    graph.node(v),
    graph.relationship(v),
    graph.unbound_relationship(v)
  {
    Ok(path), _, _, _ -> {
      let nodes =
        list.map(path.nodes, fn(node) {
          let labels =
            list.map(node.labels, fn(label) { ":" <> label }) |> string.concat
          "(" <> join_nonempty([labels, property_text(node.properties)]) <> ")"
        })
      let rels =
        list.map(path.relationships, fn(rel) {
          "-["
          <> join_nonempty([":" <> rel.kind, property_text(rel.properties)])
          <> "]->"
        })
      let alternating = list.append(nodes, rels)
      string.join(alternating, "")
    }
    _, Ok(node), _, _ -> {
      let labels =
        list.map(node.labels, fn(label) { ":" <> label }) |> string.concat
      "(" <> join_nonempty([labels, property_text(node.properties)]) <> ")"
    }
    _, _, Ok(rel), _ ->
      "["
      <> join_nonempty([":" <> rel.kind, property_text(rel.properties)])
      <> "]"
    _, _, _, Ok(rel) ->
      "-["
      <> join_nonempty([":" <> rel.kind, property_text(rel.properties)])
      <> "]->"
    _, _, _, _ ->
      "Struct(0x"
      <> int.to_base16(signature)
      <> ", ["
      <> string.join(list.map(fields, value), ", ")
      <> "])"
  }
}

fn property_text(entries: Dict(String, Value)) -> String {
  case dict.size(entries) {
    0 -> ""
    _ -> properties(entries)
  }
}

fn properties(entries: Dict(String, Value)) -> String {
  let body =
    entries
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(pair) { pair.0 <> ": " <> value(pair.1) })
    |> string.join(", ")
  "{" <> body <> "}"
}

fn quote(s: String) -> String {
  let escaped =
    s
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
  "\"" <> escaped <> "\""
}

fn join_nonempty(parts: List(String)) -> String {
  parts |> list.filter(fn(part) { part != "" }) |> string.join(" ")
}

// ---------------------------------------------------------------------------
// Query results
// ---------------------------------------------------------------------------

/// Render a result as a table, followed by a row count and a summary of any
/// updates the query made.
pub fn table(result: connection.QueryResult) -> String {
  table_with(result, default_max_cell_width)
}

/// Like `table`, with your own limit on how wide a cell may get.
pub fn table_with(
  result: connection.QueryResult,
  max_cell_width: Int,
) -> String {
  case result.fields {
    // A write with no RETURN: there is no table, only the update summary.
    [] ->
      case summary(result) {
        "" -> "OK"
        text -> text
      }

    fields -> {
      let body =
        list.map(result.rows, fn(row) {
          list.map(row, fn(cell) { truncate(value(cell), max_cell_width) })
        })
      let columns = list.transpose([fields, ..body])
      let widths = list.map(columns, column_width)

      let rule =
        "+"
        <> widths
        |> list.map(fn(width) { string.repeat("-", width + 2) })
        |> string.join("+")
        <> "+"

      let render = fn(cells: List(String)) -> String {
        let padded =
          list.zip(cells, widths)
          |> list.map(fn(pair) { string.pad_end(pair.0, pair.1, " ") })
        "| " <> string.join(padded, " | ") <> " |"
      }

      let header = [rule, render(fields), rule]
      let rows = case body {
        [] -> []
        _ -> list.append(list.map(body, render), [rule])
      }

      let count = list.length(body)
      let count_line =
        int.to_string(count)
        <> case count {
          1 -> " row"
          _ -> " rows"
        }
      let footer = case summary(result) {
        "" -> [count_line]
        text -> [count_line, text]
      }

      string.join(list.flatten([header, rows, footer]), "\n")
    }
  }
}

/// A sentence describing what the query changed, such as
/// "Created 1 node, set 2 properties". Empty if nothing changed.
pub fn summary(result: connection.QueryResult) -> String {
  case dict.get(result.summary, "stats") {
    Ok(PMap(stats)) ->
      [
        #("nodes-created", "created", "node", "nodes"),
        #("nodes-deleted", "deleted", "node", "nodes"),
        #("relationships-created", "created", "relationship", "relationships"),
        #("relationships-deleted", "deleted", "relationship", "relationships"),
        #("properties-set", "set", "property", "properties"),
        #("labels-added", "added", "label", "labels"),
        #("labels-removed", "removed", "label", "labels"),
      ]
      |> list.filter_map(fn(item) {
        let #(key, verb, singular, plural) = item
        case stat(stats, key) {
          0 -> Error(Nil)
          1 -> Ok(verb <> " 1 " <> singular)
          n -> Ok(verb <> " " <> int.to_string(n) <> " " <> plural)
        }
      })
      |> string.join(", ")
      |> string.capitalise
    _ -> ""
  }
}

fn stat(stats: Dict(String, Value), key: String) -> Int {
  case dict.get(stats, key) {
    Ok(PInt(n)) -> n
    _ -> 0
  }
}

fn column_width(column: List(String)) -> Int {
  column |> list.map(string.length) |> list.fold(0, int.max)
}

fn truncate(text: String, max_width: Int) -> String {
  case string.length(text) > max_width {
    True -> string.slice(text, 0, max_width - 1) <> "…"
    False -> text
  }
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// A one-line description of a driver error.
pub fn error(error: connection.Error) -> String {
  case error {
    connection.MissingConfiguration(name) ->
      "Missing environment variable " <> name
    connection.InvalidConfiguration(name) -> "Invalid value for " <> name
    connection.TransportError(text) -> "Connection problem: " <> text
    connection.NoCompatibleVersion ->
      "The server does not support Bolt 5.1 to 5.4"
    connection.ProtocolError(text) -> "Protocol error: " <> text
    connection.DecodeFailed(problem) ->
      "Could not decode the server's response: " <> string.inspect(problem)
    connection.ServerFailure(code, message) -> code <> ": " <> message
  }
}
