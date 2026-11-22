import gleam/dict
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import neo4j_bolt/connection
import neo4j_bolt/graph
import neo4j_bolt/parameters
import neo4j_bolt/pretty
import neo4j_bolt/row

pub fn main() {
  case connection.config_from_env() {
    Error(error) -> print_error(error)
    Ok(config) ->
      case connection.connect(config) {
        Error(error) -> print_error(error)
        Ok(conn) -> run_smoke(conn)
      }
  }
}

fn print_error(error: connection.Error) {
  io.println("Error: " <> pretty.error(error))
}

fn run_smoke(conn: connection.Connection) {
  io.println("Running Bolt smoke test...")

  let create_result =
    connection.run(
      conn,
      "CREATE (:SmokeTest {name: $name, n: $n})",
      parameters.from_list([
        #("name", parameters.string("Zoë ✓")),
        #("n", parameters.int(42)),
      ]),
    )

  case create_result {
    Error(error) -> {
      print_error(error)
      connection.close(conn)
    }
    Ok(_) -> {
      let found =
        connection.run(conn, "MATCH (n:SmokeTest) RETURN n AS node", dict.new())
      case found {
        Error(error) -> print_error(error)
        Ok(result) ->
          list.each(result.rows, fn(row) {
            case row {
              [value] ->
                case graph.node(value) {
                  Ok(_) -> io.println("Decoded node: " <> pretty.value(value))
                  Error(_) -> io.println("Could not decode node")
                }
              _ -> io.println("Unexpected row shape")
            }
          })
      }

      let rolled_back =
        connection.transaction(conn, fn(tx) {
          use _ <- result.try(connection.tx_run(
            tx,
            "CREATE (:SmokeTest {name: 'should vanish'})",
            dict.new(),
          ))
          Error(connection.ProtocolError("forced rollback"))
        })
      io.println("Rollback result: " <> string.inspect(rolled_back))

      let committed =
        connection.transaction(conn, fn(tx) {
          connection.tx_run(
            tx,
            "CREATE (:SmokeTest {name: 'committed'})",
            dict.new(),
          )
        })
      io.println("Commit result: " <> string.inspect(committed))

      let names =
        connection.run_maps(
          conn,
          "MATCH (n:SmokeTest)
           WHERE n.name IN ['Zoë ✓', 'committed']
           RETURN n.name AS name
           ORDER BY name",
          dict.new(),
        )
      case names {
        Error(error) -> print_error(error)
        Ok(rows) -> {
          io.println("Verified names:")
          list.each(rows, fn(values) {
            case row.get_string(values, "name") {
              Ok(name) -> io.println("- " <> name)
              Error(_) -> io.println("- missing or invalid name")
            }
          })
        }
      }

      case
        connection.run(conn, "MATCH (n:SmokeTest) DETACH DELETE n", dict.new())
      {
        Ok(_) -> io.println("Test nodes cleaned up")
        Error(error) -> {
          io.println("Cleanup failed:")
          print_error(error)
        }
      }

      connection.close(conn)
      io.println("Connection closed")
    }
  }
}
