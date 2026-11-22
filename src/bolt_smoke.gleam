import gleam/dict
import gleam/io
import gleam/list
import gleam/string
import neo4j_bolt/connection
import neo4j_bolt/parameters
import neo4j_bolt/pretty
import neo4j_bolt/row

fn print_error(error: connection.Error) {
  io.println("Error: " <> pretty.error(error))
}

pub fn restaurants_reviews(restaurant: String, conn: connection.Connection) {
  let parameters =
    parameters.from_list([#("restaurant", parameters.string(restaurant))])
  let query =
    "MATCH (person:Person)-[:WROTE]->(review:Review)-[:FOR]->(restaurant:Restaurant)
    WHERE restaurant.name = $restaurant
RETURN
  person.name AS username,
  review.appId AS review_id,
  review.rating AS rating,
  review.text AS review_text
LIMIT 25;"
  let query_result = connection.run_maps(conn, query, parameters)
  case query_result {
    Ok(review_rows) ->
      list.each(review_rows, fn(review_row) {
        case
          row.get_string(review_row, "username"),
          row.get_number(review_row, "rating"),
          row.get_string(review_row, "review_text")
        {
          Ok(username), Ok(rating), Ok(review_text) ->
            io.println(
              username
              <> " rated the restaurant "
              <> row.number_to_string(rating)
              <> " and said "
              <> review_text,
            )

          _, _, _ -> io.println("Missing or invalid review data")
        }
      })
    Error(error) -> print_error(error)
  }
}

pub fn main() {
  case connection.config_from_env() {
    Error(error) -> print_error(error)
    Ok(config) -> {
      io.println(
        "Connecting to "
        <> config.host
        <> ":"
        <> string.inspect(config.port)
        <> "...",
      )

      case connection.connect(config) {
        Error(error) -> print_error(error)
        Ok(conn) -> {
          io.println("Connected and authenticated")
          let restaurants_results =
            connection.run_maps(
              conn,
              "MATCH (n:Restaurant) RETURN n.name AS name LIMIT 25",
              dict.new(),
            )

          case restaurants_results {
            Ok(restaurants) ->
              list.each(restaurants, fn(restaurant_row) {
                case row.get_string(restaurant_row, "name") {
                  Ok(name) -> {
                    io.println("All reviews for " <> name <> ":")
                    restaurants_reviews(name, conn)
                  }
                  Error(row.MissingColumn(column)) ->
                    io.println("Missing column in restaurant row: " <> column)
                  Error(row.UnexpectedType(column, expected, actual)) ->
                    io.println(
                      "Invalid "
                      <> column
                      <> ": expected "
                      <> expected
                      <> ", got "
                      <> actual,
                    )
                }
              })
            Error(error) -> print_error(error)
          }

          connection.close(conn)
          io.println("Connection closed")
        }
      }
    }
  }
}
