//// Turn the PackStream structures Neo4j returns for graph entities into
//// proper Gleam types. Targets Bolt 5.x, where entities carry element ids.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import neo4j_bolt/packstream.{type Value, PInt, PList, PMap, PString, PStruct}

pub type Node {
  Node(
    id: Int,
    element_id: String,
    labels: List(String),
    properties: Dict(String, Value),
  )
}

pub type Relationship {
  Relationship(
    id: Int,
    element_id: String,
    start_id: Int,
    end_id: Int,
    start_element_id: String,
    end_element_id: String,
    kind: String,
    properties: Dict(String, Value),
  )
}

pub type UnboundRelationship {
  UnboundRelationship(
    id: Int,
    element_id: String,
    kind: String,
    properties: Dict(String, Value),
  )
}

pub type Path {
  Path(
    nodes: List(Node),
    relationships: List(UnboundRelationship),
    sequence: List(Int),
  )
}

/// Decode a node (structure signature 0x4E).
pub fn node(value: Value) -> Result(Node, Nil) {
  case value {
    PStruct(0x4E, [PInt(id), PList(labels), PMap(properties), PString(eid)]) -> {
      use labels <- result.try(list.try_map(labels, packstream.as_string))
      Ok(Node(id:, element_id: eid, labels:, properties:))
    }
    _ -> Error(Nil)
  }
}

/// Decode a relationship (structure signature 0x52).
pub fn relationship(value: Value) -> Result(Relationship, Nil) {
  case value {
    PStruct(
      0x52,
      [
        PInt(id),
        PInt(start_id),
        PInt(end_id),
        PString(kind),
        PMap(properties),
        PString(eid),
        PString(start_eid),
        PString(end_eid),
      ],
    ) ->
      Ok(Relationship(
        id:,
        element_id: eid,
        start_id:,
        end_id:,
        start_element_id: start_eid,
        end_element_id: end_eid,
        kind:,
        properties:,
      ))
    _ -> Error(Nil)
  }
}

/// Decode a path (structure signature 0x50).
pub fn path(value: Value) -> Result(Path, Nil) {
  case value {
    PStruct(
      0x50,
      [PList(node_values), PList(rel_values), PList(sequence_values)],
    ) -> {
      use nodes <- result.try(list.try_map(node_values, node))
      use relationships <- result.try(list.try_map(
        rel_values,
        unbound_relationship,
      ))
      use sequence <- result.try(list.try_map(
        sequence_values,
        packstream.as_int,
      ))
      Ok(Path(nodes:, relationships:, sequence:))
    }
    _ -> Error(Nil)
  }
}

/// Decode an unbound relationship (structure signature 0x72). Unbound
/// relationships are used inside paths and do not carry start/end nodes.
pub fn unbound_relationship(value: Value) -> Result(UnboundRelationship, Nil) {
  case value {
    PStruct(0x72, [PInt(id), PString(kind), PMap(properties), PString(eid)]) ->
      Ok(UnboundRelationship(id:, element_id: eid, kind:, properties:))
    _ -> Error(Nil)
  }
}
