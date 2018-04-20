(*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)
open! IStd
module L = Logging
module F = Format
module MF = MarkupFormatter

let desc_retain_cycle tenv (cycle: RetainCyclesType.t) =
  let open RetainCyclesType in
  Logging.d_strln "Proposition with retain cycle:" ;
  let do_edge index_ edge =
    let index = index_ + 1 in
    let node = State.get_node () in
    let from_exp_str edge_obj =
      let type_str =
        let typ_str = Typ.to_string edge_obj.rc_from.rc_node_typ in
        if String.equal typ_str "objc_object" then MF.monospaced_to_string "id"
        else MF.monospaced_to_string (Format.sprintf "%s*" typ_str)
      in
      match Errdesc.find_outermost_dereference tenv node edge_obj.rc_from.rc_node_exp with
      | Some de
        -> (
          let decomp = DecompiledExp.to_string de in
          match de with
          | DecompiledExp.Dretcall _ ->
              Format.sprintf "object %s of type %s" decomp type_str
          | _ ->
              Format.sprintf "%s of type %s" (MF.monospaced_to_string decomp) type_str )
      | None ->
          Format.sprintf "object of type %s" type_str
    in
    let location_str =
      match edge with
      | Object obj ->
          let update_str_list =
            Localise.access_desc (Errdesc.access_opt obj.rc_field.rc_field_inst)
          in
          if List.is_empty update_str_list then " "
          else ", " ^ String.concat ~sep:"," update_str_list
      | Block _ ->
          ""
    in
    let cycle_item_str =
      match edge with
      | Object obj ->
          Format.sprintf "%s --> %s" (from_exp_str obj)
            (MF.monospaced_to_string (Typ.Fieldname.to_string obj.rc_field.rc_field_name))
      | Block (_, var) ->
          Format.sprintf "a block that captures %s" (MF.monospaced_to_string (Pvar.to_string var))
    in
    Format.sprintf "(%d) %s%s" index cycle_item_str location_str
  in
  let cycle_str = List.mapi ~f:do_edge cycle.rc_elements in
  List.fold_left cycle_str ~f:(fun acc s -> Format.sprintf "%s\n %s" acc s) ~init:""


let edge_is_strong tenv obj_edge =
  let open RetainCyclesType in
  (* returns items annotation for field fn in struct t *)
  let get_item_annotation (t: Typ.t) fn =
    match t.desc with
    | Tstruct name -> (
      match Tenv.lookup tenv name with
      | Some {fields} -> (
        match List.find ~f:(fun (fn', _, _) -> Typ.Fieldname.equal fn fn') fields with
        | None ->
            None
        | Some (_, _, ann) ->
            Some ann (* Only returns annotations when the type and field are found in the tenv *) )
      | None ->
          None )
    | _ ->
        None
  in
  let has_weak_or_unretained_or_assign params =
    List.exists
      ~f:(fun att ->
        String.equal Config.unsafe_unret att || String.equal Config.weak att
        || String.equal Config.assign att )
      params
  in
  let weak_edge_by_type =
    match obj_edge.rc_from.rc_node_typ.Typ.desc with
    | Typ.Tptr (_, Typ.Pk_objc_weak) | Typ.Tptr (_, Typ.Pk_objc_unsafe_unretained) ->
        true
    | _ ->
        false
  in
  let weak_edge_by_field =
    match get_item_annotation obj_edge.rc_from.rc_node_typ obj_edge.rc_field.rc_field_name with
    | Some ia ->
        List.exists
          ~f:(fun ((ann: Annot.t), _) ->
            ( String.equal ann.class_name Config.property_attributes
            || String.equal ann.class_name Config.ivar_attributes )
            && has_weak_or_unretained_or_assign ann.parameters )
          ia
    | None ->
        true
    (* Assume the edge is weak if the type or field cannot be found in the tenv, to avoid FPs *)
  in
  not (weak_edge_by_type || weak_edge_by_field)


exception Max_retain_cycles of RetainCyclesType.Set.t

let add_cycle found_cycles rev_path =
  match RetainCyclesType.create_cycle (List.rev rev_path) with
  | Some cycle ->
      if RetainCyclesType.Set.cardinal found_cycles < 10 then
        RetainCyclesType.Set.add cycle found_cycles
      else raise (Max_retain_cycles found_cycles)
  | None ->
      found_cycles


let get_cycle_blocks root_node exp =
  match exp with
  | Exp.Closure {name; captured_vars} ->
      List.find_map
        ~f:(fun (e, var, typ) ->
          match typ.Typ.desc with
          | Typ.Tptr (_, Typ.Pk_objc_weak) | Typ.Tptr (_, Typ.Pk_objc_unsafe_unretained) ->
              None
          | _ ->
              if Exp.equal e root_node.RetainCyclesType.rc_node_exp then Some (name, var) else None
          )
        captured_vars
  | _ ->
      None


let get_weak_alias_type prop e =
  let sigma = prop.Prop.sigma in
  let check_weak_alias hpred =
    match hpred with
    | Sil.Hpointsto (_, Sil.Eexp (e', _), Sizeof {typ}) -> (
      match typ.Typ.desc with
      | (Typ.Tptr (_, Typ.Pk_objc_weak) | Typ.Tptr (_, Typ.Pk_objc_unsafe_unretained))
        when Exp.equal e' e ->
          Some typ
      | _ ->
          None )
    | _ ->
        None
  in
  List.find_map ~f:check_weak_alias sigma


let get_cycles found_cycles root tenv prop =
  let open RetainCyclesType in
  let sigma = prop.Prop.sigma in
  let get_points_to e =
    List.find
      ~f:(fun hpred -> match hpred with Sil.Hpointsto (e', _, _) -> Exp.equal e' e | _ -> false)
      sigma
  in
  (* Perform a dfs of a graph stopping when e_root is reached. Returns the set of cycles reached. *)
  let rec dfs ~found_cycles ~root_node ~from_node ~rev_path ~fields ~visited =
    let from_node =
      match get_weak_alias_type prop from_node.rc_node_exp with
      | Some typ ->
          {from_node with rc_node_typ= typ}
      | None ->
          from_node
    in
    match fields with
    | [] ->
        found_cycles
    | (field, Sil.Eexp (f_exp, f_inst)) :: el' ->
        let rc_field = {rc_field_name= field; rc_field_inst= f_inst} in
        let obj_edge = {rc_from= from_node; rc_field} in
        let edge = Object obj_edge in
        let visited' = from_node.rc_node_exp :: visited in
        let found_cycles' =
          (* found root, finish the cycle *)
          if edge_is_strong tenv obj_edge && Exp.equal f_exp root_node.rc_node_exp then
            add_cycle found_cycles (edge :: rev_path) (* we already visited f_exp, stop *)
          else if List.mem ~equal:Exp.equal visited f_exp then found_cycles
          else
            (* cycle with a block *)
            let cycle_opt = get_cycle_blocks root_node f_exp in
            if edge_is_strong tenv obj_edge && Option.is_some cycle_opt then
              let procname, captured_var = Option.value_exn cycle_opt in
              let edge2 = Block (procname, captured_var) in
              let rev_path' = edge2 :: edge :: rev_path in
              add_cycle found_cycles rev_path'
            else
              match get_points_to f_exp with
              | None ->
                  found_cycles
              | Some (Sil.Hpointsto (_, Sil.Estruct (new_fields, _), Exp.Sizeof {typ= te}))
                when edge_is_strong tenv obj_edge ->
                  let rc_to = {rc_node_exp= f_exp; rc_node_typ= te} in
                  dfs ~found_cycles ~root_node ~from_node:rc_to ~rev_path:(edge :: rev_path)
                    ~fields:new_fields ~visited:visited'
              | _ ->
                  found_cycles
        in
        dfs ~found_cycles:found_cycles' ~root_node ~from_node ~rev_path ~fields:el'
          ~visited:visited'
    | _ ->
        found_cycles
  in
  match root with
  | Sil.Hpointsto (e_root, Sil.Estruct (fl, _), Exp.Sizeof {typ= te}) when Sil.is_objc_object root ->
      let se_root = {rc_node_exp= e_root; rc_node_typ= te} in
      (* start dfs with empty path and expr pointing to root *)
      dfs ~found_cycles ~root_node:se_root ~from_node:se_root ~rev_path:[] ~fields:fl ~visited:[]
  | _ ->
      found_cycles


(* Find all the cycles available in prop, up to a limit of 10 *)
let get_retain_cycles tenv prop =
  let get_retain_cycles_with_root acc_set root = get_cycles acc_set root tenv prop in
  let sigma = prop.Prop.sigma in
  try List.fold ~f:get_retain_cycles_with_root sigma ~init:RetainCyclesType.Set.empty
  with Max_retain_cycles cycles -> cycles


let exn_retain_cycle tenv cycle =
  let retain_cycle = desc_retain_cycle tenv cycle in
  let cycle_dotty = Format.asprintf "%a" RetainCyclesType.pp_dotty cycle in
  if Config.debug_mode then (
    let rc_dotty_dir = Filename.concat Config.results_dir Config.retain_cycle_dotty_dir in
    Utils.create_dir rc_dotty_dir ;
    let rc_dotty_file = Filename.temp_file ~in_dir:rc_dotty_dir "rc" ".dot" in
    RetainCyclesType.write_dotty_to_file rc_dotty_file cycle ) ;
  let desc = Localise.desc_retain_cycle retain_cycle (State.get_loc ()) (Some cycle_dotty) in
  Exceptions.Retain_cycle (desc, __POS__)


let report_cycle tenv pname prop =
  (* When there is a cycle in objc we ignore it
        only if it's empty or it has weak or unsafe_unretained fields.
        Otherwise we report a retain cycle. *)
  let cycles = get_retain_cycles tenv prop in
  RetainCyclesType.Set.iter RetainCyclesType.print_cycle cycles ;
  match Specs.get_summary pname with
  | Some summary ->
      if RetainCyclesType.Set.cardinal cycles > 0 then (
        RetainCyclesType.Set.iter
          (fun cycle ->
            let exn = exn_retain_cycle tenv cycle in
            Reporting.log_error summary exn )
          cycles ;
        (* we report the retain cycles above but need to raise an exception as well to stop the analysis *)
        raise (Exceptions.Dummy_exception (Localise.verbatim_desc "retain cycle found")) )
  | None ->
      ()
