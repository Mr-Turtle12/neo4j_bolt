//// App-friendly constructors for Bolt query parameters.
////
//// Query APIs still accept `Dict(String, Value)` so that applications can mix
//// parameter types and reuse parameter maps. These helpers remove protocol
//// constructor noise from common application code.

import gleam/dict.{type Dict}
import neo4j_bolt/packstream.{
  type Value, PBool, PBytes, PFloat, PInt, PList, PMap, PNull, PString,
}

pub fn string(value: String) -> Value {
  PString(value)
}

pub fn int(value: Int) -> Value {
  PInt(value)
}

pub fn float(value: Float) -> Value {
  PFloat(value)
}

pub fn bool(value: Bool) -> Value {
  PBool(value)
}

pub fn bytes(value: BitArray) -> Value {
  PBytes(value)
}

pub fn list(values: List(Value)) -> Value {
  PList(values)
}

pub fn map(values: Dict(String, Value)) -> Value {
  PMap(values)
}

pub fn null() -> Value {
  PNull
}

pub fn from_list(values: List(#(String, Value))) -> Dict(String, Value) {
  dict.from_list(values)
}
