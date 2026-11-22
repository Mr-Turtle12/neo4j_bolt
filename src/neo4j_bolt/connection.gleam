//// A single synchronous Bolt connection (Bolt 5.1 to 5.4, plain TCP).
////
//// The connection is not process-safe: use it from one process at a time.
//// Wrap it in an actor or pool for concurrent use.

import envoy
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mug
import neo4j_bolt/packstream.{type Value, PInt, PList, PMap, PString, PStruct}

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub type Config {
  Config(
    host: String,
    port: Int,
    username: String,
    password: String,
    database: String,
    timeout_ms: Int,
  )
}

pub opaque type Connection {
  Connection(socket: mug.Socket, timeout: Int, database: String)
}

/// A handle that is only valid inside `transaction`.
pub opaque type Tx {
  Tx(connection: Connection)
}

pub type QueryResult {
  QueryResult(
    fields: List(String),
    rows: List(List(Value)),
    summary: Dict(String, Value),
  )
}

pub type Error {
  MissingConfiguration(String)
  TransportError(String)
  NoCompatibleVersion
  ProtocolError(String)
  DecodeFailed(packstream.DecodeError)
  InvalidConfiguration(String)
  /// Neo4j rejected the request. `code` looks like
  /// "Neo.ClientError.Statement.SyntaxError".
  ServerFailure(code: String, message: String)
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub fn new_config(username: String, password: String) -> Config {
  Config(
    host: "localhost",
    port: 7687,
    username:,
    password:,
    database: "neo4j",
    timeout_ms: 10_000,
  )
}

/// Reads NEO4J_USERNAME and NEO4J_PASSWORD (required), plus NEO4J_HOST,
/// NEO4J_PORT, NEO4J_DATABASE and NEO4J_TIMEOUT_MS (optional).
pub fn config_from_env() -> Result(Config, Error) {
  use username <- result.try(require_env("NEO4J_USERNAME"))
  use password <- result.try(require_env("NEO4J_PASSWORD"))
  let host = envoy.get("NEO4J_HOST") |> result.unwrap("localhost")
  let port = case envoy.get("NEO4J_PORT") {
    Error(_) -> Ok(7687)
    Ok(value) ->
      int.parse(value)
      |> result.replace_error(InvalidConfiguration("NEO4J_PORT"))
  }
  use port <- result.try(port)
  let database = envoy.get("NEO4J_DATABASE") |> result.unwrap("neo4j")
  let timeout_ms = case envoy.get("NEO4J_TIMEOUT_MS") {
    Error(_) -> Ok(10_000)
    Ok(value) ->
      int.parse(value)
      |> result.replace_error(InvalidConfiguration("NEO4J_TIMEOUT_MS"))
  }
  use timeout_ms <- result.try(timeout_ms)
  validate_config(Config(
    host:,
    port:,
    username:,
    password:,
    database:,
    timeout_ms:,
  ))
}

fn require_env(name: String) -> Result(String, Error) {
  envoy.get(name) |> result.replace_error(MissingConfiguration(name))
}

/// Check settings before opening a network connection.
///
/// `connect` performs this validation automatically. This function is useful
/// when configuration is assembled from application-specific sources.
pub fn validate_config(config: Config) -> Result(Config, Error) {
  case config.host == "" {
    True -> Error(InvalidConfiguration("NEO4J_HOST"))
    False ->
      case config.port < 1 || config.port > 65_535 {
        True -> Error(InvalidConfiguration("NEO4J_PORT"))
        False ->
          case config.database == "" {
            True -> Error(InvalidConfiguration("NEO4J_DATABASE"))
            False ->
              case config.timeout_ms < 1 {
                True -> Error(InvalidConfiguration("NEO4J_TIMEOUT_MS"))
                False -> Ok(config)
              }
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Connecting
// ---------------------------------------------------------------------------

// Magic preamble, then four version proposals: [reserved, range, minor, major].
// 0x00 0x03 0x04 0x05 means "5.4, and the 3 minor versions below it" (5.4 - 5.1).
const handshake: BitArray = <<
  0x60, 0x60, 0xB0, 0x17, 0x00, 0x03, 0x04, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
>>

pub fn connect(config: Config) -> Result(Connection, Error) {
  use config <- result.try(validate_config(config))
  use socket <- result.try(
    mug.new(config.host, port: config.port)
    |> mug.timeout(config.timeout_ms)
    |> mug.connect
    |> result.map_error(transport_error),
  )
  let conn =
    Connection(socket:, timeout: config.timeout_ms, database: config.database)

  case negotiate(conn) {
    Error(error) -> {
      let _ = mug.shutdown(socket)
      Error(error)
    }
    Ok(_) ->
      case authenticate(conn, config) {
        Ok(_) -> Ok(conn)
        Error(error) -> {
          let _ = mug.shutdown(socket)
          Error(error)
        }
      }
  }
}

fn negotiate(conn: Connection) -> Result(Nil, Error) {
  use _ <- result.try(
    mug.send(conn.socket, handshake) |> result.map_error(transport_error),
  )
  use reply <- result.try(receive(conn, 4))
  case reply {
    <<0, 0, _minor, 5>> -> Ok(Nil)
    <<0, 0, 0, 0>> -> Error(NoCompatibleVersion)
    _ -> Error(ProtocolError("unexpected handshake reply"))
  }
}

fn authenticate(conn: Connection, config: Config) -> Result(Nil, Error) {
  let hello =
    PMap(
      dict.from_list([
        #("user_agent", PString("gleam-bolt/0.1.0")),
        #(
          "bolt_agent",
          PMap(dict.from_list([#("product", PString("gleam-bolt/0.1.0"))])),
        ),
      ]),
    )
  use _ <- result.try(expect_success(conn, 0x01, [hello]))

  let logon =
    PMap(
      dict.from_list([
        #("scheme", PString("basic")),
        #("principal", PString(config.username)),
        #("credentials", PString(config.password)),
      ]),
    )
  use _ <- result.try(expect_success(conn, 0x6A, [logon]))
  Ok(Nil)
}

/// Politely close the connection.
pub fn close(conn: Connection) -> Nil {
  let _ = send(conn, 0x02, [])
  let _ = mug.shutdown(conn.socket)
  Nil
}

// ---------------------------------------------------------------------------
// Running queries
// ---------------------------------------------------------------------------

/// Run a query in its own auto-commit transaction.
pub fn run(
  conn: Connection,
  query: String,
  parameters: Dict(String, Value),
) -> Result(QueryResult, Error) {
  let extra = PMap(dict.from_list([#("db", PString(conn.database))]))
  run_with(conn, query, parameters, extra)
}

/// Run a query inside a transaction opened by `transaction`.
pub fn tx_run(
  tx: Tx,
  query: String,
  parameters: Dict(String, Value),
) -> Result(QueryResult, Error) {
  // The database is chosen by BEGIN, so RUN's extra map must stay empty.
  run_with(tx.connection, query, parameters, PMap(dict.new()))
}

/// Run `body` in an explicit transaction. Commits if it returns Ok, and
/// rolls back (via RESET) if it returns Error.
pub fn transaction(
  conn: Connection,
  body: fn(Tx) -> Result(a, Error),
) -> Result(a, Error) {
  let begin_extra = PMap(dict.from_list([#("db", PString(conn.database))]))
  use _ <- result.try(expect_success(conn, 0x11, [begin_extra]))
  case body(Tx(conn)) {
    Ok(value) -> {
      use _ <- result.try(expect_success(conn, 0x12, []))
      Ok(value)
    }
    Error(error) -> {
      let _ = reset(conn)
      Error(error)
    }
  }
}

/// Convert each row into a map keyed by column name.
pub fn to_maps(result: QueryResult) -> List(Dict(String, Value)) {
  list.map(result.rows, fn(row) {
    list.zip(result.fields, row) |> dict.from_list
  })
}

/// Run a query and return its first row as a named map, or `None` when there
/// are no rows. The query is still fully consumed; this is a result-shaping
/// convenience, not a streaming or early-stop operation.
pub fn run_first_map(
  conn: Connection,
  query: String,
  parameters: Dict(String, Value),
) -> Result(Option(Dict(String, Value)), Error) {
  use rows <- result.try(run_maps(conn, query, parameters))
  Ok(case list.first(rows) {
    Ok(row) -> Some(row)
    Error(_) -> None
  })
}

/// Run a query and convert every row to a map keyed by the returned column name.
/// Use this for Cypher results that use scalar projections or explicit `AS` aliases.
/// Graph values remain available as `PStruct` values inside the maps.
pub fn run_maps(
  conn: Connection,
  query: String,
  parameters: Dict(String, Value),
) -> Result(List(Dict(String, Value)), Error) {
  use result <- result.try(run(conn, query, parameters))
  Ok(to_maps(result))
}

/// Run a query inside a transaction and convert every row to a named map.
pub fn tx_run_maps(
  tx: Tx,
  query: String,
  parameters: Dict(String, Value),
) -> Result(List(Dict(String, Value)), Error) {
  use result <- result.try(tx_run(tx, query, parameters))
  Ok(to_maps(result))
}

/// Run a query inside a transaction and return its first named row, if present.
pub fn tx_run_first_map(
  tx: Tx,
  query: String,
  parameters: Dict(String, Value),
) -> Result(Option(Dict(String, Value)), Error) {
  use rows <- result.try(tx_run_maps(tx, query, parameters))
  Ok(case list.first(rows) {
    Ok(row) -> Some(row)
    Error(_) -> None
  })
}

fn run_with(
  conn: Connection,
  query: String,
  parameters: Dict(String, Value),
  extra: Value,
) -> Result(QueryResult, Error) {
  // RUN and PULL are pipelined: send both, then read the replies.
  use _ <- result.try(
    send(conn, 0x10, [PString(query), PMap(parameters), extra]),
  )
  let pull = PMap(dict.from_list([#("n", PInt(-1))]))
  use _ <- result.try(send(conn, 0x3F, [pull]))

  use first <- result.try(read_response(conn))
  case first {
    Success(meta) -> {
      let fields = case dict.get(meta, "fields") {
        Ok(PList(items)) -> list.filter_map(items, packstream.as_string)
        _ -> []
      }
      use #(rows, summary) <- result.try(collect_records(conn, []))
      Ok(QueryResult(fields:, rows:, summary:))
    }
    // The server answers the pipelined PULL with IGNORED; `reset` skips it.
    Failure(code, message) -> fail(conn, code, message)
    _ -> Error(ProtocolError("unexpected reply to RUN"))
  }
}

fn collect_records(
  conn: Connection,
  acc: List(List(Value)),
) -> Result(#(List(List(Value)), Dict(String, Value)), Error) {
  use response <- result.try(read_response(conn))
  case response {
    Record(values) -> collect_records(conn, [values, ..acc])
    Success(summary) -> Ok(#(list.reverse(acc), summary))
    Failure(code, message) -> fail(conn, code, message)
    Ignored -> Error(ProtocolError("request was ignored by the server"))
  }
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

type Response {
  Success(Dict(String, Value))
  Record(List(Value))
  Failure(code: String, message: String)
  Ignored
}

fn send(
  conn: Connection,
  signature: Int,
  fields: List(Value),
) -> Result(Nil, Error) {
  let message = packstream.encode(PStruct(signature, fields))
  mug.send(conn.socket, frame(message)) |> result.map_error(transport_error)
}

fn expect_success(
  conn: Connection,
  signature: Int,
  fields: List(Value),
) -> Result(Dict(String, Value), Error) {
  use _ <- result.try(send(conn, signature, fields))
  use response <- result.try(read_response(conn))
  case response {
    Success(meta) -> Ok(meta)
    Failure(code, message) -> fail(conn, code, message)
    _ -> Error(ProtocolError("unexpected reply"))
  }
}

/// After FAILURE the server ignores everything until it receives RESET.
fn fail(conn: Connection, code: String, message: String) -> Result(a, Error) {
  let _ = reset(conn)
  Error(ServerFailure(code, message))
}

fn reset(conn: Connection) -> Result(Nil, Error) {
  use _ <- result.try(send(conn, 0x0F, []))
  await_reset(conn)
}

fn await_reset(conn: Connection) -> Result(Nil, Error) {
  use response <- result.try(read_response(conn))
  case response {
    Success(_) -> Ok(Nil)
    // Leftover replies to requests that were pipelined before the failure.
    Ignored | Record(_) -> await_reset(conn)
    Failure(code, message) -> Error(ServerFailure(code, message))
  }
}

fn read_response(conn: Connection) -> Result(Response, Error) {
  use bytes <- result.try(read_message(conn, <<>>))
  use #(value, _) <- result.try(
    packstream.decode(bytes) |> result.map_error(DecodeFailed),
  )
  parse_response(value)
}

fn parse_response(value: Value) -> Result(Response, Error) {
  case value {
    PStruct(0x70, [PMap(meta)]) -> Ok(Success(meta))
    PStruct(0x71, [PList(values)]) -> Ok(Record(values))
    PStruct(0x7F, [PMap(meta)]) ->
      Ok(Failure(
        code: string_or(meta, "code", "unknown"),
        message: string_or(meta, "message", ""),
      ))
    PStruct(0x7E, _) -> Ok(Ignored)
    _ -> Error(ProtocolError("unexpected message: " <> string.inspect(value)))
  }
}

fn string_or(map: Dict(String, Value), key: String, default: String) -> String {
  case dict.get(map, key) {
    Ok(PString(s)) -> s
    _ -> default
  }
}

// ---------------------------------------------------------------------------
// Chunking: every message is sent as [size:16, data]... followed by 0x0000
// ---------------------------------------------------------------------------

const max_chunk: Int = 65_535

fn frame(message: BitArray) -> BitArray {
  frame_loop(message, <<>>)
}

fn frame_loop(rest: BitArray, acc: BitArray) -> BitArray {
  let len = bit_array.byte_size(rest)
  case len > max_chunk {
    True -> {
      let assert Ok(head) = bit_array.slice(rest, 0, max_chunk)
      let assert Ok(tail) = bit_array.slice(rest, max_chunk, len - max_chunk)
      frame_loop(tail, <<acc:bits, max_chunk:size(16), head:bits>>)
    }
    False -> <<acc:bits, len:size(16), rest:bits, 0:size(16)>>
  }
}

fn read_message(conn: Connection, acc: BitArray) -> Result(BitArray, Error) {
  use header <- result.try(receive(conn, 2))
  case header {
    <<0:size(16)>> ->
      case acc {
        // A bare 0x0000 with nothing buffered is a keep-alive no-op.
        <<>> -> read_message(conn, acc)
        _ -> Ok(acc)
      }
    <<len:size(16)>> -> {
      use chunk <- result.try(receive(conn, len))
      read_message(conn, <<acc:bits, chunk:bits>>)
    }
    _ -> Error(ProtocolError("short chunk header"))
  }
}

// ---------------------------------------------------------------------------
// Transport helpers
// ---------------------------------------------------------------------------

fn receive(conn: Connection, bytes: Int) -> Result(BitArray, Error) {
  mug.receive_exact(conn.socket, bytes, conn.timeout)
  |> result.map_error(transport_error)
}

fn transport_error(error: a) -> Error {
  TransportError(string.inspect(error))
}
