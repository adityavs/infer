(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open !Utils

module F = Format

(* string set domain we use to ensure we're getting the expected traces *)
module MockTraceDomain =
  AbstractDomain.FiniteSet
    (PrettyPrintable.MakePPSet(struct
       include String
       let pp_element fmt s = Format.fprintf fmt "%s" s
     end))

module Domain = AccessTree.Make (MockTraceDomain)

let make_base base_str =
  Pvar.mk (Mangled.from_string base_str) Procname.empty_block, Typ.Tvoid

let make_field_access access_str =
  AccessPath.FieldAccess (Ident.create_fieldname (Mangled.from_string access_str) 0, Typ.Tvoid)

let make_access_path base_str accesses =
  let rec make_accesses accesses_acc = function
    | [] -> accesses_acc
    | access_str :: l -> make_accesses ((make_field_access access_str) :: accesses_acc) l in
  let accesses = make_accesses [] accesses in
  make_base base_str, IList.rev accesses

let tests =
  let x_base = make_base "x" in
  let y_base = make_base "y" in
  let z_base = make_base "z" in

  let f = make_field_access "f" in
  let g = make_field_access "g" in

  let xF = AccessPath.Exact (make_access_path "x" ["f"]) in
  let xG = AccessPath.Exact (make_access_path "x" ["g"]) in
  let xFG = AccessPath.Exact (make_access_path "x" ["f"; "g"]) in
  let yF = AccessPath.Exact (make_access_path "y" ["f"]) in
  let yG = AccessPath.Exact (make_access_path "y" ["g"]) in
  let yFG = AccessPath.Exact (make_access_path "y" ["f"; "g"]) in
  let z = AccessPath.Exact (make_access_path "z" []) in
  let zF = AccessPath.Exact (make_access_path "z" ["f"]) in
  let zFG = AccessPath.Exact (make_access_path "z" ["f"; "g"]) in

  let a_star = AccessPath.Abstracted (make_access_path "a" []) in
  let x_star = AccessPath.Abstracted (make_access_path "x" []) in
  let xF_star = AccessPath.Abstracted (make_access_path "x" ["f"]) in
  let xG_star = AccessPath.Abstracted (make_access_path "x" ["g"]) in
  let y_star = AccessPath.Abstracted (make_access_path "y" []) in
  let yF_star = AccessPath.Abstracted (make_access_path "y" ["f"]) in
  let z_star = AccessPath.Abstracted (make_access_path "z" []) in

  let x_trace = MockTraceDomain.singleton "x" in
  let y_trace = MockTraceDomain.singleton "y" in
  let z_trace = MockTraceDomain.singleton "z" in
  let xF_trace = MockTraceDomain.singleton "xF" in
  let yF_trace = MockTraceDomain.singleton "yF" in
  let xFG_trace = MockTraceDomain.singleton "xFG" in

  let x_tree =
    let g_subtree = Domain.make_access_node xF_trace g xFG_trace in
    Domain.AccessMap.singleton f g_subtree
    |> Domain.make_node x_trace in
  let y_tree =
    let yF_subtree = Domain.make_starred_leaf yF_trace in
    Domain.AccessMap.singleton f yF_subtree
    |> Domain.make_node y_trace in
  let z_tree = Domain.make_starred_leaf z_trace in
  let tree =
    Domain.BaseMap.singleton x_base x_tree
    |> Domain.BaseMap.add y_base y_tree
    |> Domain.BaseMap.add z_base z_tree in

  (* [tree] is:
     x |-> ("x",
            f |-> ("Xf",
                   g |-> ("xFG", {})))
     y |-> ("y",
            f |-> ("yF", * ))
     z |-> ("z", * )
  *)

  let open OUnit2 in
  let no_trace = "NONE" in

  let get_trace_str access_path tree =
    match Domain.get_trace access_path tree with
    | Some trace -> pp_to_string MockTraceDomain.pp trace
    | None -> no_trace in

  let assert_traces_eq access_path tree expected_trace_str =
    let actual_trace_str = get_trace_str access_path tree in
    let pp_diff fmt (actual, expected) =
      F.fprintf fmt "Expected to retrieve trace %s but got %s" expected actual in
    assert_equal ~pp_diff actual_trace_str expected_trace_str in

  let assert_trace_not_found access_path tree =
    assert_traces_eq access_path tree no_trace in

  let get_trace_test =
    let get_trace_test_ _ =
      (* exact access path tests *)
      assert_traces_eq z tree "{ z }";
      assert_traces_eq xF tree "{ xF }";
      assert_traces_eq yF tree "{ yF }";
      assert_traces_eq xFG tree "{ xFG }";
      assert_trace_not_found xG tree;

      (* starred access path tests *)
      assert_traces_eq x_star tree "{ x, xF, xFG }";
      assert_traces_eq xF_star tree "{ xF, xFG }";
      assert_trace_not_found xG_star tree;
      assert_trace_not_found a_star tree;

      (* starred tree tests *)
      assert_traces_eq zF tree "{ z }";
      assert_traces_eq zFG tree "{ z }";
      assert_traces_eq z_star tree "{ z }";
      assert_traces_eq y_star tree "{ y, yF }";
      assert_traces_eq yF_star tree "{ yF }";
      assert_traces_eq yFG tree "{ yF }";
      assert_trace_not_found yG tree in
    "get_trace">::get_trace_test_ in
  "access_tree_suite">:::[get_trace_test]
