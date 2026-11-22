//// Typed accessors for rows returned by `connection.run_maps`.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/result
import neo4j_bolt/packstream.{
  type Value, PBool, PBytes, PFloat, PInt, PList, PMap, PNull, PString, PStruct,
}

pub type Error {
  MissingColumn(String)
  UnexpectedType(column: String, expected: String, actual: String)
}

pub type Number {
  Integer(Int)
  Decimal(Float)
}

pub fn get_value(
  row: Dict(String, Value),
  column: String,
) -> Result(Value, Error) {
  case dict.get(row, column) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(MissingColumn(column))
  }
}

pub fn get_string(
  row: Dict(String, Value),
  column: String,
) -> Result(String, Error) {
  use value <- result.try(get_value(row, column))
  case value {
    PString(string) -> Ok(string)
    _ -> unexpected_type(column, "string", value)
  }
}

pub fn get_int(row: Dict(String, Value), column: String) -> Result(Int, Error) {
  use value <- result.try(get_value(row, column))
  case value {
    PInt(integer) -> Ok(integer)
    _ -> unexpected_type(column, "integer", value)
  }
}

pub fn get_float(
  row: Dict(String, Value),
  column: String,
) -> Result(Float, Error) {
  use value <- result.try(get_value(row, column))
  case value {
    PFloat(decimal) -> Ok(decimal)
    _ -> unexpected_type(column, "float", value)
  }
}

/// Read either an integer or floating-point value without losing its type.
pub fn get_number(
  row: Dict(String, Value),
  column: String,
) -> Result(Number, Error) {
  use value <- result.try(get_value(row, column))
  case value {
    PInt(integer) -> Ok(Integer(integer))
    PFloat(decimal) -> Ok(Decimal(decimal))
    _ -> unexpected_type(column, "number", value)
  }
}

pub fn number_to_string(number: Number) -> String {
  case number {
    Integer(integer) -> int.to_string(integer)
    Decimal(decimal) -> float.to_string(decimal)
  }
}

fn unexpected_type(
  column: String,
  expected: String,
  value: Value,
) -> Result(a, Error) {
  Error(UnexpectedType(column:, expected:, actual: value_type(value)))
}

fn value_type(value: Value) -> String {
  case value {
    PNull -> "null"
    PBool(_) -> "boolean"
    PInt(_) -> "integer"
    PFloat(_) -> "float"
    PString(_) -> "string"
    PBytes(_) -> "bytes"
    PList(_) -> "list"
    PMap(_) -> "map"
    PStruct(_, _) -> "structure"
  }
}
