# neo4j_bolt

A synchronous Neo4j Bolt 5.x client written in Gleam and targeting Erlang.

> This driver is under active development. It supports plain TCP connections and Bolt 5.1–5.4.

## Install

The package name is `neo4j_bolt`, and the modules are imported from the
`neo4j_bolt` namespace. This source repository is prepared for Hex publication
but is not published yet. After a release, add it to an application with:

```sh
gleam add neo4j_bolt
```

For now, clone this repository to work on the package itself:

```sh
gleam test
```

## Configure

```gleam
import neo4j_bolt/connection

let config = connection.new_config("neo4j", "password")
```

Configuration fields are `host`, `port`, `username`, `password`, `database`, and `timeout_ms`.
`connection.validate_config(config)` checks host, port, database, and timeout
before connecting; `connection.connect` always validates automatically.

Or read configuration from environment variables:

```gleam
let assert Ok(config) = connection.config_from_env()
```

Supported variables:

| Variable | Required | Default |
|---|---:|---|
| `NEO4J_USERNAME` | Yes | — |
| `NEO4J_PASSWORD` | Yes | — |
| `NEO4J_HOST` | No | `localhost` |
| `NEO4J_PORT` | No | `7687` |
| `NEO4J_DATABASE` | No | `neo4j` |
| `NEO4J_TIMEOUT_MS` | No | `10000` |

Optional integer settings must be valid integers; invalid values return
`InvalidConfiguration` instead of silently falling back to defaults. Ports
must be in `1..65535`, timeouts must be positive, and host/database names must
not be empty.

## Connect and close

```gleam
import neo4j_bolt/connection
import gleam/io
import gleam/string

pub fn main() {
  case connection.config_from_env() {
    Error(error) -> io.println("Configuration error: " <> string.inspect(error))
    Ok(config) ->
      case connection.connect(config) {
        Error(error) -> io.println("Could not connect: " <> string.inspect(error))
        Ok(conn) -> {
          // Use conn for queries here.
          connection.close(conn)
        }
      }
  }
}
```

Always close a successfully opened connection, including after query errors.
A `Connection` is synchronous and is not process-safe: use it from one process
at a time, and close it when that process is finished. This package does not
provide a connection pool.

## Run a query

```gleam
import neo4j_bolt/connection
import neo4j_bolt/parameters

let parameters =
  parameters.from_list([#("name", parameters.string("Alice"))])

case connection.run(
  conn,
  "MATCH (p:Person {name: $name}) RETURN p.name AS name",
  parameters,
) {
  Ok(result) -> {
    // result.fields: List(String)
    // result.rows: List(List(Value))
    // result.summary: Dict(String, Value)
  }
  Error(error) -> {
    // Handle MissingConfiguration, TransportError, ProtocolError,
    // DecodeFailed, ServerFailure, and the other public errors.
  }
}
```

Use `run` when you need positional rows, graph structures, or the query summary.
The result includes `fields` in server order, `rows` as positional values, and
the server's `summary` map (including update statistics when present). Queries
return all rows in memory; use a Cypher `LIMIT` when the result set could be
large.

## Named rows

Cypher aliases become convenient named rows:

```gleam
let result =
  connection.run_maps(
    conn,
    "MATCH (p:Person)-[:WROTE]->(r:Review)
     RETURN p.name AS username,
            r.rating AS rating,
            r.text AS review_text
     LIMIT 25",
    dict.new(),
  )

case result {
  Ok(rows) -> {
    // rows: List(Dict(String, Value))
  }
  Error(error) -> {
    // Handle the error.
  }
}
```

`run_maps` is also available inside an explicit transaction as `tx_run_maps`.
When only the first matching row matters, `run_first_map` returns
`Result(Option(Dict(String, Value)), Error)`: `Ok(None)` means the query
succeeded with no rows. The transaction equivalent is `tx_run_first_map`.
These helpers still consume the full server result; they do not stream or stop
after the first row.

For an existing `QueryResult`, convert its rows explicitly:

```gleam
let maps = connection.to_maps(result)
```

Use `neo4j_bolt/row` to read named values without matching on PackStream constructors.
It also accepts ratings represented as either integers or floats:

```gleam
import neo4j_bolt/row

case row.get_string(result_row, "username"), row.get_number(result_row, "rating") {
  Ok(username), Ok(rating) ->
    username <> " rated " <> row.number_to_string(rating)
  Error(row.MissingColumn(column)), _ -> "Missing column: " <> column
  _, Error(error) -> string.inspect(error)
}
```

Typed accessors include `get_string`, `get_int`, `get_float`, and `get_number`.
Errors distinguish missing columns from values with an unexpected type. Use
`row.get_value` when you need the underlying `packstream.Value`.

Always parameterize user-supplied values rather than interpolating them into
Cypher text. Parameters are ordinary PackStream values:

```gleam
import neo4j_bolt/parameters

let parameters =
  parameters.from_list([
    #("name", parameters.string(user_supplied_name)),
    #("minimum_rating", parameters.int(4)),
  ])
connection.run_first_map(
  conn,
  "MATCH (p:Person {name: $name})
   WHERE p.rating >= $minimum_rating
   RETURN p.name AS name, p.rating AS rating",
  parameters,
)
```

`neo4j_bolt/parameters` provides convenience constructors for native Gleam values:
`string`, `int`, `float`, `bool`, `bytes`, `list`, `map`, and `null`.
Use `parameters.from_list` to build the parameter dictionary accepted by
`run`, `run_maps`, and the transaction variants. The `neo4j_bolt/packstream.Value`
constructors remain available for protocol-level code and graph structures.

Convert maps into application-owned record types at the boundary. This keeps
database naming and nullable/missing-field policy out of the rest of the app:

```gleam
import neo4j_bolt/packstream
import neo4j_bolt/row
import gleam/dict.{type Dict}
import gleam/string

pub type Person {
  Person(name: String, rating: Int)
}

fn decode_person(values: Dict(String, packstream.Value)) -> Result(Person, String) {
  case row.get_string(values, "name"), row.get_int(values, "rating") {
    Ok(name), Ok(rating) -> Ok(Person(name:, rating:))
    Error(error), _ -> Error(string.inspect(error))
    _, Error(error) -> Error(string.inspect(error))
  }
}
```

Keep application-specific result records in application code. `Dict(String, Value)` is useful as a generic boundary, while a record gives field access and compile-time types:

```gleam
pub type Review {
  Review(username: String, rating: Int, review_text: String)
}

review.username
review.rating
review.review_text
```

## PackStream values

Query cells use `neo4j_bolt/packstream.Value`:

| Constructor | Gleam value |
|---|---|
| `PNull` | Null |
| `PBool(Bool)` | Boolean |
| `PInt(Int)` | Integer |
| `PFloat(Float)` | Floating-point number |
| `PString(String)` | UTF-8 string |
| `PBytes(BitArray)` | Byte array |
| `PList(List(Value))` | List |
| `PMap(Dict(String, Value))` | String-keyed map |
| `PStruct(Int, List(Value))` | Bolt structure |

Convenience accessors are exported:

```gleam
packstream.as_string(value)
packstream.as_int(value)
packstream.as_float(value)
packstream.as_bool(value)
packstream.as_list(value)
packstream.as_map(value)
```

## Graph values

Neo4j nodes and relationships can be decoded into typed records:

```gleam
import neo4j_bolt/graph

case graph.node(value) {
  Ok(node) -> {
    node.element_id
    node.labels
    node.properties
  }
  Error(Nil) -> Nil
}
```

Available graph decoders:

- `graph.node(value)`
- `graph.relationship(value)`
- `graph.unbound_relationship(value)`
- `graph.path(value)`

A decoded `Path` contains:

- `nodes`: `List(Node)`
- `relationships`: `List(UnboundRelationship)`
- `sequence`: `List(Int)`

## Transactions

An explicit transaction commits if the callback returns `Ok`, and sends RESET if it returns `Error`.

```gleam
import gleam/result
import neo4j_bolt/parameters

let outcome =
  connection.transaction(conn, fn(tx) {
    use _ <- result.try(
      connection.tx_run(
        tx,
        "CREATE (:Person {name: $name})",
        parameters.from_list([#("name", parameters.string("Bob"))]),
      )
    )

    connection.tx_run(
      tx,
      "CREATE (:Person {name: $name})",
      parameters.from_list([#("name", parameters.string("Carol"))]),
    )
  })
```

The `Tx` handle is opaque and can only be used through `tx_run`, `tx_run_maps`,
`tx_run_first_map`, and other transaction APIs.

Do not continue using a `Tx` after its transaction callback has returned.
Avoid returning a successful value until all transaction queries have
succeeded: an `Ok` callback result commits, while an `Error` rolls back.

## Errors

`connection.Error` variants:

- `MissingConfiguration(name)`
- `InvalidConfiguration(name)`
- `TransportError(description)`
- `NoCompatibleVersion`
- `ProtocolError(description)`
- `DecodeFailed(packstream.DecodeError)`
- `ServerFailure(code, message)`

A `ServerFailure` includes Neo4j's code and message. The driver automatically sends RESET after Neo4j failures.

## Application formatting

The low-level `neo4j_bolt/pretty` module is useful for debugging and demos, but it is not required to use the client:

```gleam
neo4j_bolt/pretty.table(result)
neo4j_bolt/pretty.value(value)
```

Applications should format their own typed records for CLIs, JSON APIs, HTML, and logs.

## Limitations

Current implementation limitations:

- Plain TCP only; TLS/SNI and Aura cloud support are not implemented
- Bolt 5.1–5.4 handshake support
- No connection pool, automatic retry, routing, bookmarks, or cluster support
- A connection is synchronous and must not be used concurrently
- No result streaming; PULL requests collect all records
- Temporal and spatial PackStream structures need typed decoders

## Development

```sh
gleam format
gleam test
```

`gleam test` runs deterministic unit tests and does not require a Neo4j server.
The optional integration smoke programs can be run with
`gleam run -m bolt_smoke` or `gleam run -m bolt_smoke2`; they require
`NEO4J_USERNAME`, `NEO4J_PASSWORD`,
and optionally `NEO4J_HOST`, `NEO4J_PORT`, `NEO4J_DATABASE`, and
`NEO4J_TIMEOUT_MS`. The smoke programs create and delete test nodes, so use a
development database.

## License

This package is released under the [Unlicense](./LICENSE).
