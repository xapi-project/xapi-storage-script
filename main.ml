(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
module U = Unix
module R = Rpc
module B = Backtrace

open Core.Std
open Async.Std

open Xapi_types

let use_syslog = ref false

let log level fmt =
  Printf.ksprintf (fun s ->
    if !use_syslog then begin
      (* FIXME: this is synchronous and will block other I/O *)
      Core.Syslog.syslog ~level ~facility:Core.Syslog.Facility.DAEMON s;
    end else begin
      let w = Lazy.force Writer.stderr in
      Writer.write w s;
      Writer.newline w
    end
  ) fmt

let debug fmt = log Core.Syslog.Level.DEBUG   fmt
let info  fmt = log Core.Syslog.Level.INFO    fmt
let warn  fmt = log Core.Syslog.Level.WARNING fmt
let error fmt = log Core.Syslog.Level.ERR     fmt

module RRD = struct
  open Protocol_async

  let (>>|=) m f = m >>= function
    | `Ok x -> f x
    | `Error y ->
      let b = Buffer.create 16 in
      let fmt = Format.formatter_of_buffer b in
      Client.pp_error fmt y;
      Format.pp_print_flush fmt ();
      raise (Failure (Buffer.contents b))

  let switch_rpc queue_name string_of_call response_of_string call =
    Client.connect ~switch:queue_name () >>|= fun t ->
    Client.rpc ~t ~queue:queue_name ~body:(string_of_call call) () >>|= fun s ->
    return (response_of_string s)

  let json_switch_rpc queue_name = switch_rpc queue_name Jsonrpc.string_of_call Jsonrpc.response_of_string

  module Client = Rrd_interface.ClientM(struct
    type 'a t = 'a Deferred.t
    let return = return
    let bind = Deferred.bind
    let fail = raise
    let rpc call = json_switch_rpc !Rrd_interface.queue_name call
end)

end

let _nonpersistent = "NONPERSISTENT"
let _clone_on_boot_key = "clone-on-boot"

let backend_error name args =
  let open Storage_interface in
  let exnty = Exception.Backend_error (name, args) in
  Exception.rpc_of_exnty exnty

let backend_backtrace_error name args backtrace =
  let backtrace = rpc_of_backtrace backtrace |> Jsonrpc.to_string in
  let open Storage_interface in
  let exnty = Exception.Backend_error_with_backtrace(name, backtrace :: args) in
  Exception.rpc_of_exnty exnty

let missing_uri () =
  backend_error "MISSING_URI" [ "Please include a URI in the device-config" ]

let (>>>=) = Deferred.Result.(>>=)

let fork_exec_rpc root_dir script_name args response_of_rpc =
  info "%s %s" script_name (Jsonrpc.to_string args);
  ( Sys.is_file ~follow_symlinks:true script_name
    >>= function
    | `No | `Unknown ->
      error "%s is not a file" script_name;
      return (Error(backend_error "SCRIPT_MISSING" [ script_name; "Check whether the file exists and has correct permissions" ]))
    | `Yes -> return (Ok ())
  ) >>>= fun () ->
  ( Unix.access script_name [ `Exec ]
    >>= function
    | Error exn ->
      error "%s is not executable" script_name;
      return (Error (backend_error "SCRIPT_NOT_EXECUTABLE" [ script_name; Exn.to_string exn ]))
    | Ok () -> return (Ok ())
  ) >>>= fun () ->
  Process.create ~prog:script_name ~args:["--json"] ~working_dir:root_dir ()
  >>= function
  | Error e ->
    error "%s failed: %s" script_name (Error.to_string_hum e);
    return (Error(backend_error "SCRIPT_FAILED" [ script_name; Error.to_string_hum e ]))
  | Ok p ->
    (* Send the request as json on stdin *)
    let w = Process.stdin p in
    Writer.write w (Jsonrpc.to_string args);
    Writer.close w
    >>= fun () ->
    Process.collect_output_and_wait p
    >>= fun output ->
    begin match output.Process.Output.exit_status with
    | Error (`Exit_non_zero code) ->
      (* Expect an exception and backtrace on stdout *)
      begin match Or_error.try_with (fun () -> Jsonrpc.of_string output.Process.Output.stdout) with
      | Error _ ->
        error "%s failed and printed bad error json: %s" script_name output.Process.Output.stdout;
        return (Error (backend_error "SCRIPT_FAILED" [ script_name; "non-zero exit and bad json on stdout"; string_of_int code; output.Process.Output.stdout; output.Process.Output.stdout ]))
      | Ok response ->
        begin match Or_error.try_with (fun () -> error_of_rpc response) with
        | Error _ ->
          error "%s failed and printed bad error json: %s" script_name output.Process.Output.stdout;
          return (Error (backend_error "SCRIPT_FAILED" [ script_name; "non-zero exit and bad json on stdout"; string_of_int code; output.Process.Output.stdout; output.Process.Output.stdout ]))
        | Ok x -> return (Error(backend_backtrace_error x.code x.params x.backtrace))
        end
      end
    | Error (`Signal signal) ->
      error "%s caught a signal and failed" script_name;
      return (Error (backend_error "SCRIPT_FAILED" [ script_name; "signalled"; Signal.to_string signal; output.Process.Output.stdout; output.Process.Output.stdout ]))
    | Ok () ->

      (* Parse the json on stdout *)
      begin match Or_error.try_with (fun () -> Jsonrpc.of_string output.Process.Output.stdout) with
      | Error _ ->
        error "%s succeeded but printed bad json: %s" script_name output.Process.Output.stdout;
        return (Error (backend_error "SCRIPT_FAILED" [ script_name; "bad json on stdout"; output.Process.Output.stdout ]))
      | Ok response ->
        begin match Or_error.try_with (fun () -> response_of_rpc response) with
        | Error _ ->
          error "%s succeeded but printed bad json: %s" script_name output.Process.Output.stdout;
          return (Error (backend_error "SCRIPT_FAILED" [ script_name; "json did not match schema"; output.Process.Output.stdout ]))
        | Ok x ->
          info "%s succeeded: %s" script_name output.Process.Output.stdout;
          return (Ok x)
        end
      end
    end

let script root_dir name kind script = match kind with
| `Volume -> Filename.(concat (concat root_dir name) script)
| `Datapath datapath -> Filename.(concat (concat (concat (dirname root_dir) "datapath") datapath) script)

module Attached_SRs = struct
  type state = {
    sr: string;
    uids: string list;
  } with sexp

  let sr_table : state String.Table.t ref = ref (String.Table.create ())
  let state_path = ref None

  let add smapiv2 plugin uids =
    Hashtbl.replace !sr_table smapiv2 { sr = plugin; uids };
    ( match !state_path with
      | None ->
        return ()
      | Some path ->
        let contents = String.Table.sexp_of_t sexp_of_state !sr_table |> Sexplib.Sexp.to_string in
        let dir = Filename.dirname path in
        Unix.mkdir ~p:() dir >>= fun () ->
        Writer.save path ~contents
    ) >>= fun () ->
    return (Ok ())

  let find smapiv2 =
    match Hashtbl.find !sr_table smapiv2 with
    | None ->
      let open Storage_interface in
      let exnty = Exception.Sr_not_attached smapiv2 in
      return (Error (Exception.rpc_of_exnty exnty))
    | Some { sr } -> return (Ok sr)

  let get_uids smapiv2 =
    match Hashtbl.find !sr_table smapiv2 with
    | None ->
      let open Storage_interface in
      let exnty = Exception.Sr_not_attached smapiv2 in
      return (Error (Exception.rpc_of_exnty exnty))
    | Some { uids } -> return (Ok uids)

  let remove smapiv2 =
    Hashtbl.remove !sr_table smapiv2;
    return (Ok ())

  let reload path =
    state_path := Some path;
    Sys.is_file ~follow_symlinks:true path
    >>= function
    | `No | `Unknown ->
      return ()
    | `Yes ->
      Reader.file_contents path
      >>= fun contents ->
      sr_table := contents |> Sexplib.Sexp.of_string |> String.Table.t_of_sexp state_of_sexp;
      return ()
end

module Datapath_plugins = struct
  let table: Storage.Plugin.Types.query_result String.Table.t ref = ref (String.Table.create ())

  let register root_dir name =
    let args = Storage.Plugin.Types.Plugin.Query.In.make "register" in
    let args = Storage.Plugin.Types.Plugin.Query.In.rpc_of_t args in
    fork_exec_rpc root_dir (script root_dir name (`Datapath name) "Plugin.Query") args Storage.Plugin.Types.Plugin.Query.Out.t_of_rpc
    >>= function
    | Ok response ->
      info "Registered datapath plugin %s" name;
      Hashtbl.replace !table name response;
      return ()
    | _ ->
      info "Failed to register datapath plugin %s" name;
      return ()

  let unregister root_dir name =
    Hashtbl.remove !table name;
    return ()

  let supports_feature scheme feature =
    match Hashtbl.find !table scheme with
    | None -> false
    | Some query_result -> List.mem query_result.Storage.Plugin.Types.features feature
end

let vdi_of_volume x =
  let open Storage_interface in {
  vdi = x.Storage.Volume.Types.key;
  uuid = x.Storage.Volume.Types.uuid;
  content_id = "";
  name_label = x.Storage.Volume.Types.name;
  name_description = x.Storage.Volume.Types.description;
  ty = "";
  metadata_of_pool = "";
  is_a_snapshot = false;
  snapshot_time = "19700101T00:00:00Z";
  snapshot_of = "";
  read_only = not x.Storage.Volume.Types.read_write;
  virtual_size = x.Storage.Volume.Types.virtual_size;
  physical_utilisation = x.Storage.Volume.Types.physical_utilisation;
  sm_config = [];
  persistent = true;
}

let stat root_dir name dbg sr vdi =
  let args = Storage.Volume.Types.Volume.Stat.In.make dbg sr vdi in
  let args = Storage.Volume.Types.Volume.Stat.In.rpc_of_t args in
  fork_exec_rpc root_dir (script root_dir name `Volume "Volume.stat") args Storage.Volume.Types.Volume.Stat.Out.t_of_rpc

let clone root_dir name dbg sr vdi =
  let args = Storage.Volume.Types.Volume.Clone.In.make dbg sr vdi in
  let args = Storage.Volume.Types.Volume.Clone.In.rpc_of_t args in
  fork_exec_rpc root_dir (script root_dir name `Volume "Volume.clone") args Storage.Volume.Types.Volume.Clone.Out.t_of_rpc

let destroy root_dir name dbg sr vdi =
  let args = Storage.Volume.Types.Volume.Destroy.In.make dbg sr vdi in
  let args = Storage.Volume.Types.Volume.Destroy.In.rpc_of_t args in
  fork_exec_rpc root_dir (script root_dir name `Volume "Volume.destroy") args Storage.Volume.Types.Volume.Destroy.Out.t_of_rpc

let set root_dir name dbg sr vdi k v =
  let args = Storage.Volume.Types.Volume.Set.In.make dbg sr vdi k v in
  let args = Storage.Volume.Types.Volume.Set.In.rpc_of_t args in
  fork_exec_rpc root_dir (script root_dir name `Volume "Volume.set") args Storage.Volume.Types.Volume.Set.Out.t_of_rpc

let unset root_dir name dbg sr vdi k =
  let args = Storage.Volume.Types.Volume.Unset.In.make dbg sr vdi k in
  let args = Storage.Volume.Types.Volume.Unset.In.rpc_of_t args in
  fork_exec_rpc root_dir (script root_dir name `Volume "Volume.unset") args Storage.Volume.Types.Volume.Unset.Out.t_of_rpc

let choose_datapath ?(persistent = true) response =
  (* We can only use a URI with a valid scheme, since we use the scheme
     to name the datapath plugin. *)
  let possible =
    List.filter_map ~f:(fun x ->
      let uri = Uri.of_string x in
      match Uri.scheme uri with
      | None -> None
      | Some scheme -> Some (scheme, x)
    ) response.Storage.Volume.Types.uri in
  (* We can only use URIs whose schemes correspond to registered plugins *)
  let possible = List.filter ~f:(fun (scheme, _) -> Hashtbl.mem !Datapath_plugins.table scheme) possible in
  (* If we want to be non-persistent, we prefer if the datapath plugin supports it natively *)
  let preference_order =
    if persistent
    then possible
    else
      let supports_nonpersistent, others = List.partition_map ~f:(fun (scheme, uri) ->
        if Datapath_plugins.supports_feature scheme _nonpersistent
        then `Fst (scheme, uri) else `Snd (scheme, uri)
      ) possible in
      supports_nonpersistent @ others in
  match preference_order with
  | [] -> return (Error (missing_uri ()))
  | (scheme, u) :: us -> return (Ok (scheme, u, "0"))

(* Process a message *)
let process root_dir name x =
  let open Storage_interface in
  let call = Jsonrpc.call_of_string x in
  (match call with
  | { R.name = "Query.query"; R.params = [ args ] } ->
    let args = Args.Query.Query.request_of_rpc args in
    (* convert to new storage interface *)
    let args = Storage.Plugin.Types.Plugin.Query.In.make args.Args.Query.Query.dbg in
    let args = Storage.Plugin.Types.Plugin.Query.In.rpc_of_t args in
    let open Deferred.Result.Monad_infix in
    fork_exec_rpc root_dir (script root_dir name `Volume "Plugin.Query") args Storage.Plugin.Types.Plugin.Query.Out.t_of_rpc
    >>= fun response ->
    (* Convert between the xapi-storage interface and the SMAPI *)
    let features = List.map ~f:(function
      | "VDI_DESTROY" -> "VDI_DELETE"
      | x -> x) response.Storage.Plugin.Types.features in
    (* Look for executable scripts and automatically add capabilities *)
    let rec loop acc = function
      | [] -> return (Ok acc)
      | (s, capability) :: rest ->
        let open Deferred.Monad_infix in
        let script_name = script root_dir name `Volume s in
        ( Sys.is_file ~follow_symlinks:true script_name
          >>= function
          | `No | `Unknown ->
            return false
          | `Yes ->
            ( Unix.access script_name [ `Exec ]
              >>= function
              | Error exn ->
                return false
              | Ok () ->
                return true
            )
          ) >>= function
          | false -> loop acc rest
          | true -> loop (capability :: acc) rest in
    loop [] [
      "SR.attach",       "SR_ATTACH";
      "SR.create",       "SR_CREATE";
      "SR.destroy",      "SR_DELETE";
      "SR.detach",       "SR_DETACH";
      "SR.ls",           "SR_SCAN";
      "SR.stat",         "SR_UPDATE";
      "Volume.create",   "VDI_CREATE";
      "Volume.clone",    "VDI_CLONE";
      "Volume.snapshot", "VDI_SNAPSHOT";
      "Volume.resize",   "VDI_RESIZE";
      "Volume.destroy",  "VDI_DELETE";
      "Volume.stat",     "VDI_UPDATE";
    ]
    >>= fun x ->
    let features = features @ x in
    (* Add the features we always have *)
    let features = features @ [
      "VDI_ATTACH"; "VDI_DETACH"; "VDI_ACTIVATE"; "VDI_DEACTIVATE";
      "VDI_INTRODUCE"
    ] in
    (* If we have the ability to clone a disk then we can provide
       clone on boot. *)
    let features =
      if List.mem features "VDI_CLONE"
      then "VDI_RESET_ON_BOOT/2" :: features
      else features in
    let response = {
      driver = response.Storage.Plugin.Types.plugin;
      name = response.Storage.Plugin.Types.name;
      description = response.Storage.Plugin.Types.description;
      vendor = response.Storage.Plugin.Types.vendor;
      copyright = response.Storage.Plugin.Types.copyright;
      version = response.Storage.Plugin.Types.version;
      required_api_version = response.Storage.Plugin.Types.required_api_version;
      features;
      configuration =
       ("uri", "URI of the storage medium") ::
       response.Storage.Plugin.Types.configuration;
      required_cluster_stack = response.Storage.Plugin.Types.required_cluster_stack } in
    Deferred.Result.return (R.success (Args.Query.Query.rpc_of_response response))
  | { R.name = "Query.diagnostics"; R.params = [ args ] } ->
    let args = Args.Query.Diagnostics.request_of_rpc args in
    let args = Storage.Plugin.Types.Plugin.Diagnostics.In.make args.Args.Query.Diagnostics.dbg in
    let args = Storage.Plugin.Types.Plugin.Diagnostics.In.rpc_of_t args in
    let open Deferred.Result.Monad_infix in
    fork_exec_rpc root_dir (script root_dir name `Volume "Plugin.diagnostics") args Storage.Plugin.Types.Plugin.Diagnostics.Out.t_of_rpc
    >>= fun response ->
    Deferred.Result.return (R.success (Args.Query.Diagnostics.rpc_of_response response))
  | { R.name = "SR.attach"; R.params = [ args ] } ->
    let args = Args.SR.Attach.request_of_rpc args in
    let device_config = args.Args.SR.Attach.device_config in
    begin match List.find device_config ~f:(fun (k, _) -> k = "uri") with
    | None ->
      Deferred.Result.return (R.failure (missing_uri ()))
    | Some (_, uri) ->
      let args' = Storage.Volume.Types.SR.Attach.In.make args.Args.SR.Attach.dbg uri in
      let args' = Storage.Volume.Types.SR.Attach.In.rpc_of_t args' in
      let open Deferred.Result.Monad_infix in
      fork_exec_rpc root_dir (script root_dir name `Volume "SR.attach") args' Storage.Volume.Types.SR.Attach.Out.t_of_rpc
      >>= fun attach_response ->
      let sr = args.Args.SR.Attach.sr in
      (* Stat the SR to look for datasources *)
      let args = Storage.Volume.Types.SR.Stat.In.make
        args.Args.SR.Attach.dbg
        attach_response (* SR.stat should take the attached URI *) in
      let args = Storage.Volume.Types.SR.Stat.In.rpc_of_t args in
      fork_exec_rpc root_dir (script root_dir name `Volume "SR.stat") args Storage.Volume.Types.SR.Stat.Out.t_of_rpc
      >>= fun stat ->
      let open Deferred.Monad_infix in
      let rec loop acc = function
      | [] -> return acc
      | datasource :: datasources ->
        let uri = Uri.of_string datasource in
        match Uri.scheme uri with
        | Some "xeno+shm" ->
          let uid = Uri.path uri in
          let uid = if String.length uid > 1 then String.sub uid 1 (String.length uid - 1) else uid in
          RRD.Client.Plugin.Local.register ~uid ~info:Rrd.Five_Seconds ~protocol:Rrd_interface.V2
          >>= fun _ ->
          loop (uid :: acc) datasources
        | _ ->
          loop acc datasources in
      loop [] stat.Storage.Volume.Types.datasources
      >>= fun uids ->
      let open Deferred.Result.Monad_infix in
      (* associate the 'sr' from the plugin with the SR reference passed in *)
      Attached_SRs.add sr attach_response uids
      >>= fun () ->
      Deferred.Result.return (R.success (Args.SR.Attach.rpc_of_response attach_response))
    end
  | { R.name = "SR.detach"; R.params = [ args ] } ->
    let args = Args.SR.Detach.request_of_rpc args in
    begin Attached_SRs.find args.Args.SR.Detach.sr
    >>= function
    | Error _ ->
      (* ensure SR.detach is idempotent *)
      Deferred.Result.return (R.success (Args.SR.Detach.rpc_of_response ()))
    | Ok sr ->
      let open Deferred.Result.Monad_infix in
      let args' = Storage.Volume.Types.SR.Detach.In.make
        args.Args.SR.Detach.dbg
        sr in
      let args' = Storage.Volume.Types.SR.Detach.In.rpc_of_t args' in
      fork_exec_rpc root_dir (script root_dir name `Volume "SR.detach") args' Storage.Volume.Types.SR.Detach.Out.t_of_rpc
      >>= fun response ->
      Attached_SRs.get_uids args.Args.SR.Detach.sr
      >>= fun uids ->
      let open Deferred.Monad_infix in
      let rec loop = function
      | [] -> return ()
      | datasource :: datasources ->
        let uri = Uri.of_string datasource in
        match Uri.scheme uri with
        | Some "xeno+shm" ->
          let uid = Uri.path uri in
          let uid = if String.length uid > 1 then String.sub uid 1 (String.length uid - 1) else uid in
          RRD.Client.Plugin.Local.deregister ~uid
          >>= fun _ ->
          loop datasources
        | _ ->
          loop datasources in
      loop uids
      >>= fun () ->
      let open Deferred.Result.Monad_infix in
      Attached_SRs.remove args.Args.SR.Detach.sr
      >>= fun () ->
      Deferred.Result.return (R.success (Args.SR.Detach.rpc_of_response response))
    end
  | { R.name = "SR.probe"; R.params = [ args ] } ->
    let args = Args.SR.Probe.request_of_rpc args in
    let name = args.Args.SR.Probe.queue in
    let device_config = args.Args.SR.Probe.device_config in
    begin match List.find device_config ~f:(fun (k, _) -> k = "uri") with
    | None ->
      Deferred.Result.return (R.failure (missing_uri ()))
    | Some (_, uri) ->
      let args = Storage.Volume.Types.SR.Probe.In.make
        args.Args.SR.Probe.dbg
        uri in
      let args = Storage.Volume.Types.SR.Probe.In.rpc_of_t args in
      let open Deferred.Result.Monad_infix in
      fork_exec_rpc root_dir (script root_dir name `Volume "SR.probe") args Storage.Volume.Types.SR.Probe.Out.t_of_rpc
      >>= fun response ->
      let srs = List.map ~f:(fun sr_stat -> sr_stat.Storage.Volume.Types.sr, {
        Storage_interface.name_label = sr_stat.Storage.Volume.Types.name;
        name_description = sr_stat.Storage.Volume.Types.description;
        total_space = sr_stat.Storage.Volume.Types.total_space;
        free_space = sr_stat.Storage.Volume.Types.free_space;
        clustered = sr_stat.Storage.Volume.Types.clustered;
        health = match sr_stat.Storage.Volume.Types.health with
          | Storage.Volume.Types.Healthy _ -> Healthy
          | Storage.Volume.Types.Recovering _ -> Recovering
          ;
      }) response.Storage.Volume.Types.SR.Probe.Out.srs in
      let uris = response.Storage.Volume.Types.SR.Probe.Out.uris in
      let result = Storage_interface.(Probe { srs; uris }) in
      Deferred.Result.return (R.success (Args.SR.Probe.rpc_of_response result))
    end
  | { R.name = "SR.create"; R.params = [ args ] } ->
    let args = Args.SR.Create.request_of_rpc args in
    let name_label = args.Args.SR.Create.name_label in
    let description = args.Args.SR.Create.name_description in
    let device_config = args.Args.SR.Create.device_config in
    begin match List.find device_config ~f:(fun (k, _) -> k = "uri") with
    | None ->
      Deferred.Result.return (R.failure (missing_uri ()))
    | Some (_, uri) ->
      let args = Storage.Volume.Types.SR.Create.In.make
        args.Args.SR.Create.dbg
        uri
        name_label
        description
        device_config in
      let args = Storage.Volume.Types.SR.Create.In.rpc_of_t args in
      let open Deferred.Result.Monad_infix in
      fork_exec_rpc root_dir (script root_dir name `Volume "SR.create") args Storage.Volume.Types.SR.Create.Out.t_of_rpc
      >>= fun response ->
      Deferred.Result.return (R.success (Args.SR.Create.rpc_of_response response))
    end
  | { R.name = "SR.set_name_label"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.SR.Set_name_label.request_of_rpc args in
    Attached_SRs.find args.Args.SR.Set_name_label.sr
    >>= fun sr ->
    let name_label = args.Args.SR.Set_name_label.new_name_label in
    let dbg = args.Args.SR.Set_name_label.dbg in
    let args = Storage.Volume.Types.SR.Set_name.In.make dbg sr name_label in
    let args = Storage.Volume.Types.SR.Set_name.In.rpc_of_t args in
    fork_exec_rpc root_dir (script root_dir name `Volume "SR.set_name") args Storage.Volume.Types.SR.Set_name.Out.t_of_rpc
    >>= fun () ->
    Deferred.Result.return (R.success (Args.SR.Set_name_label.rpc_of_response ()))
  | { R.name = "SR.set_name_description"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.SR.Set_name_description.request_of_rpc args in
    Attached_SRs.find args.Args.SR.Set_name_description.sr
    >>= fun sr ->
    let name_description = args.Args.SR.Set_name_description.new_name_description in
    let dbg = args.Args.SR.Set_name_description.dbg in
    let args = Storage.Volume.Types.SR.Set_description.In.make dbg sr name_description in
    let args = Storage.Volume.Types.SR.Set_description.In.rpc_of_t args in
    fork_exec_rpc root_dir (script root_dir name `Volume "SR.set_description") args Storage.Volume.Types.SR.Set_description.Out.t_of_rpc
    >>= fun () ->
    Deferred.Result.return (R.success (Args.SR.Set_name_label.rpc_of_response ()))
  | { R.name = "SR.destroy"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.SR.Destroy.request_of_rpc args in
    Attached_SRs.find args.Args.SR.Destroy.sr
    >>= fun sr ->
    let args = Storage.Volume.Types.SR.Destroy.In.make
      args.Args.SR.Destroy.dbg
      sr in
    let args = Storage.Volume.Types.SR.Destroy.In.rpc_of_t args in
    fork_exec_rpc root_dir (script root_dir name `Volume "SR.destroy") args Storage.Volume.Types.SR.Destroy.Out.t_of_rpc
    >>= fun response ->
    Deferred.Result.return (R.success (Args.SR.Create.rpc_of_response response))
  | { R.name = "SR.scan"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.SR.Scan.request_of_rpc args in
    Attached_SRs.find args.Args.SR.Scan.sr
    >>= fun sr ->
    let args = Storage.Volume.Types.SR.Ls.In.make
      args.Args.SR.Scan.dbg
      sr in
    let args = Storage.Volume.Types.SR.Ls.In.rpc_of_t args in
    fork_exec_rpc root_dir (script root_dir name `Volume "SR.ls") args Storage.Volume.Types.SR.Ls.Out.t_of_rpc
    >>= fun response ->
    (* Filter out volumes which are clone-on-boot transients *)
    let transients = List.fold ~f:(fun set x ->
      match List.Assoc.find x.Storage.Volume.Types.keys _clone_on_boot_key with
      | None -> set
      | Some transient -> Set.add set transient
    ) ~init:(Set.empty ~comparator:String.comparator) response in
    let response = List.filter ~f:(fun x -> not(Set.mem transients x.Storage.Volume.Types.key)) response in
    let response = List.map ~f:vdi_of_volume response in
    Deferred.Result.return (R.success (Args.SR.Scan.rpc_of_response response))
  | { R.name = "VDI.create"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Create.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Create.sr
    >>= fun sr ->
    let vdi_info = args.Args.VDI.Create.vdi_info in
    let args = Storage.Volume.Types.Volume.Create.In.make
      args.Args.VDI.Create.dbg
      sr
      vdi_info.name_label
      vdi_info.name_description
      vdi_info.virtual_size in
    let args = Storage.Volume.Types.Volume.Create.In.rpc_of_t args in
    fork_exec_rpc root_dir (script root_dir name `Volume "Volume.create") args Storage.Volume.Types.Volume.Create.Out.t_of_rpc
    >>= fun response ->
    let response = vdi_of_volume response in
    Deferred.Result.return (R.success (Args.VDI.Create.rpc_of_response response))
  | { R.name = "VDI.destroy"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Destroy.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Destroy.sr
    >>= fun sr ->
    stat root_dir name args.Args.VDI.Destroy.dbg sr args.Args.VDI.Destroy.vdi
    >>= fun response ->
    (* Destroy any clone-on-boot volume that might exist *)
    ( match List.Assoc.find response.Storage.Volume.Types.keys _clone_on_boot_key with
      | None ->
        return (Ok ())
      | Some temporary ->
        (* Destroy the temporary disk we made earlier *)
        destroy root_dir name args.Args.VDI.Destroy.dbg sr temporary
    ) >>= fun () ->
    destroy root_dir name args.Args.VDI.Destroy.dbg sr args.Args.VDI.Destroy.vdi
    >>= fun () ->
    Deferred.Result.return (R.success (Args.VDI.Destroy.rpc_of_response ()))
  | { R.name = "VDI.snapshot"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Snapshot.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Snapshot.sr
    >>= fun sr ->
    let vdi_info = args.Args.VDI.Snapshot.vdi_info in
    let args = Storage.Volume.Types.Volume.Snapshot.In.make
      args.Args.VDI.Snapshot.dbg
      sr
      vdi_info.vdi in
    let args = Storage.Volume.Types.Volume.Snapshot.In.rpc_of_t args in
    fork_exec_rpc root_dir (script root_dir name `Volume "Volume.snapshot") args Storage.Volume.Types.Volume.Snapshot.Out.t_of_rpc
    >>= fun response ->
    let response = vdi_of_volume response in
    Deferred.Result.return (R.success (Args.VDI.Snapshot.rpc_of_response response))
  | { R.name = "VDI.clone"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Clone.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Clone.sr
    >>= fun sr ->
    let vdi_info = args.Args.VDI.Clone.vdi_info in
    clone root_dir name args.Args.VDI.Clone.dbg sr vdi_info.vdi
    >>= fun response ->
    let response = vdi_of_volume response in
    Deferred.Result.return (R.success (Args.VDI.Clone.rpc_of_response response))
  | { R.name = "VDI.set_name_label"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Set_name_label.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Set_name_label.sr
    >>= fun sr ->
    let vdi = args.Args.VDI.Set_name_label.vdi in
    let new_name_label = args.Args.VDI.Set_name_label.new_name_label in
    let dbg = args.Args.VDI.Set_name_label.dbg in
    let args = Storage.Volume.Types.Volume.Set_name.In.make dbg sr vdi new_name_label in
    let args = Storage.Volume.Types.Volume.Set_name.In.rpc_of_t args in
    fork_exec_rpc root_dir (script root_dir name `Volume "Volume.set_name") args Storage.Volume.Types.Volume.Set_name.Out.t_of_rpc
    >>= fun () ->
    Deferred.Result.return (R.success (Args.VDI.Set_name_label.rpc_of_response ()))
  | { R.name = "VDI.set_name_description"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Set_name_description.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Set_name_description.sr
    >>= fun sr ->
    let vdi = args.Args.VDI.Set_name_description.vdi in
    let new_name_description = args.Args.VDI.Set_name_description.new_name_description in
    let dbg = args.Args.VDI.Set_name_description.dbg in
    let args = Storage.Volume.Types.Volume.Set_description.In.make dbg sr vdi new_name_description in
    let args = Storage.Volume.Types.Volume.Set_description.In.rpc_of_t args in
    fork_exec_rpc root_dir (script root_dir name `Volume "Volume.set_description") args Storage.Volume.Types.Volume.Set_description.Out.t_of_rpc
    >>= fun () ->
    Deferred.Result.return (R.success (Args.VDI.Set_name_description.rpc_of_response ()))
  | { R.name = "VDI.resize"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Resize.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Resize.sr
    >>= fun sr ->
    let vdi = args.Args.VDI.Resize.vdi in
    let new_size = args.Args.VDI.Resize.new_size in
    let dbg = args.Args.VDI.Resize.dbg in
    let args = Storage.Volume.Types.Volume.Resize.In.make dbg sr vdi new_size in
    let args = Storage.Volume.Types.Volume.Resize.In.rpc_of_t args in
    fork_exec_rpc root_dir (script root_dir name `Volume "Volume.resize") args Storage.Volume.Types.Volume.Resize.Out.t_of_rpc
    >>= fun () ->
    (* Now call Volume.stat to discover the size *)
    stat root_dir name dbg sr vdi
    >>= fun response ->
    Deferred.Result.return (R.success (Args.VDI.Resize.rpc_of_response response.Storage.Volume.Types.virtual_size))
  | { R.name = "VDI.stat"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Stat.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Stat.sr
    >>= fun sr ->
    let vdi = args.Args.VDI.Stat.vdi in
    stat root_dir name args.Args.VDI.Stat.dbg sr vdi
    >>= fun response ->
    let response = vdi_of_volume response in
    Deferred.Result.return (R.success (Args.VDI.Stat.rpc_of_response response))
  | { R.name = "VDI.introduce"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Introduce.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Introduce.sr
    >>= fun sr ->
    let vdi = args.Args.VDI.Introduce.location in
    stat root_dir name args.Args.VDI.Introduce.dbg sr vdi
    >>= fun response ->
    let response = vdi_of_volume response in
    Deferred.Result.return (R.success (Args.VDI.Introduce.rpc_of_response response))
  | { R.name = "VDI.attach"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Attach.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Attach.sr
    >>= fun sr ->
    (* Discover the URIs using Volume.stat *)
    stat root_dir name args.Args.VDI.Attach.dbg sr args.Args.VDI.Attach.vdi
    >>= fun response ->
    (* If we have a clone-on-boot volume then use that instead *)
    ( match List.Assoc.find response.Storage.Volume.Types.keys _clone_on_boot_key with
      | None ->
        return (Ok response)
      | Some temporary ->
        stat root_dir name args.Args.VDI.Attach.dbg sr temporary
    ) >>= fun response ->
    choose_datapath response
    >>= fun (datapath, uri, domain) ->
    let args' = Storage.Datapath.Types.Datapath.Attach.In.make
      args.Args.VDI.Attach.dbg
      uri domain in
    let args' = Storage.Datapath.Types.Datapath.Attach.In.rpc_of_t args' in
    fork_exec_rpc root_dir (script root_dir name (`Datapath datapath) "Datapath.attach") args' Storage.Datapath.Types.Datapath.Attach.Out.t_of_rpc
    >>= fun response ->
    let backend, params = match response.Storage.Datapath.Types.implementation with
    | Storage.Datapath.Types.Blkback p -> "vbd", p
    | Storage.Datapath.Types.Qdisk p -> "qdisk", p
    | Storage.Datapath.Types.Tapdisk3 p -> "vbd3", p in
    let attach_info = {
      params;
      xenstore_data = [ "backend-kind", backend ];
      o_direct = true;
      o_direct_reason = "";
    } in
    Deferred.Result.return (R.success (Args.VDI.Attach.rpc_of_response attach_info))
  | { R.name = "VDI.activate"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Activate.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Activate.sr
    >>= fun sr ->
    (* Discover the URIs using Volume.stat *)
    stat root_dir name args.Args.VDI.Activate.dbg sr args.Args.VDI.Activate.vdi
    >>= fun response ->
    (* If we have a clone-on-boot volume then use that instead *)
    ( match List.Assoc.find response.Storage.Volume.Types.keys _clone_on_boot_key with
      | None ->
        return (Ok response)
      | Some temporary ->
        stat root_dir name args.Args.VDI.Activate.dbg sr temporary
    ) >>= fun response ->
    choose_datapath response
    >>= fun (datapath, uri, domain) ->
    let args' = Storage.Datapath.Types.Datapath.Activate.In.make
      args.Args.VDI.Activate.dbg
      uri domain in
    let args' = Storage.Datapath.Types.Datapath.Activate.In.rpc_of_t args' in
    fork_exec_rpc root_dir (script root_dir name (`Datapath datapath) "Datapath.activate") args' Storage.Datapath.Types.Datapath.Activate.Out.t_of_rpc
    >>= fun response ->
    Deferred.Result.return (R.success (Args.VDI.Activate.rpc_of_response ()))
  | { R.name = "VDI.deactivate"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Deactivate.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Deactivate.sr
    >>= fun sr ->
    (* Discover the URIs using Volume.stat *)
    stat root_dir name args.Args.VDI.Deactivate.dbg sr args.Args.VDI.Deactivate.vdi
    >>= fun response ->
    ( match List.Assoc.find response.Storage.Volume.Types.keys _clone_on_boot_key with
      | None ->
        return (Ok response)
      | Some temporary ->
        stat root_dir name args.Args.VDI.Deactivate.dbg sr temporary
    ) >>= fun response ->
    choose_datapath response
    >>= fun (datapath, uri, domain) ->
    let args' = Storage.Datapath.Types.Datapath.Deactivate.In.make
      args.Args.VDI.Deactivate.dbg
      uri domain in
    let args' = Storage.Datapath.Types.Datapath.Deactivate.In.rpc_of_t args' in
    fork_exec_rpc root_dir (script root_dir name (`Datapath datapath) "Datapath.deactivate") args' Storage.Datapath.Types.Datapath.Deactivate.Out.t_of_rpc
    >>= fun response ->
    Deferred.Result.return (R.success (Args.VDI.Deactivate.rpc_of_response ()))
  | { R.name = "VDI.detach"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Detach.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Detach.sr
    >>= fun sr ->
    (* Discover the URIs using Volume.stat *)
    stat root_dir name args.Args.VDI.Detach.dbg sr args.Args.VDI.Detach.vdi
    >>= fun response ->
    ( match List.Assoc.find response.Storage.Volume.Types.keys _clone_on_boot_key with
      | None ->
        return (Ok response)
      | Some temporary ->
        stat root_dir name args.Args.VDI.Detach.dbg sr temporary
    ) >>= fun response ->
    choose_datapath response
    >>= fun (datapath, uri, domain) ->
    let args' = Storage.Datapath.Types.Datapath.Detach.In.make
      args.Args.VDI.Detach.dbg
      uri domain in
    let args' = Storage.Datapath.Types.Datapath.Detach.In.rpc_of_t args' in
    fork_exec_rpc root_dir (script root_dir name (`Datapath datapath) "Datapath.detach") args' Storage.Datapath.Types.Datapath.Detach.Out.t_of_rpc
    >>= fun response ->
    Deferred.Result.return (R.success (Args.VDI.Detach.rpc_of_response ()))
  | { R.name = "SR.stat"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.SR.Stat.request_of_rpc args in
    Attached_SRs.find args.Args.SR.Stat.sr
    >>= fun sr ->
    let args = Storage.Volume.Types.SR.Stat.In.make
      args.Args.SR.Stat.dbg
      sr in
    let args = Storage.Volume.Types.SR.Stat.In.rpc_of_t args in
    fork_exec_rpc root_dir (script root_dir name `Volume "SR.stat") args Storage.Volume.Types.SR.Stat.Out.t_of_rpc
    >>= fun response ->
    let response = {
      name_label = response.Storage.Volume.Types.name;
      name_description = response.Storage.Volume.Types.description;
      total_space = response.Storage.Volume.Types.total_space;
      free_space = response.Storage.Volume.Types.free_space;
      clustered = response.Storage.Volume.Types.clustered;
      health = match response.Storage.Volume.Types.health with
        | Storage.Volume.Types.Healthy _ -> Healthy
        | Storage.Volume.Types.Recovering _ -> Recovering
        ;
    } in
    Deferred.Result.return (R.success (Args.SR.Stat.rpc_of_response response))
  | { R.name = "VDI.epoch_begin"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Epoch_begin.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Epoch_begin.sr
    >>= fun sr ->
    (* Discover the URIs using Volume.stat *)
    let persistent = args.Args.VDI.Epoch_begin.persistent in
    stat root_dir name args.Args.VDI.Epoch_begin.dbg sr args.Args.VDI.Epoch_begin.vdi
    >>= fun response ->
    choose_datapath ~persistent response
    >>= fun (datapath, uri, domain) ->
    (* If non-persistent and the datapath plugin supports NONPERSISTENT
       then we delegate this to the datapath plugin. Otherwise we will
       make a temporary clone now and attach/detach etc this file. *)
    if Datapath_plugins.supports_feature datapath _nonpersistent then begin
      (* We delegate handling non-persistent disks to the datapath plugin. *)
      let args = Storage.Datapath.Types.Datapath.Open.In.make
        args.Args.VDI.Epoch_begin.dbg
        uri persistent in
      let args = Storage.Datapath.Types.Datapath.Open.In.rpc_of_t args in
      fork_exec_rpc root_dir (script root_dir name (`Datapath datapath) "Datapath.open") args Storage.Datapath.Types.Datapath.Open.Out.t_of_rpc
      >>= fun () ->
      Deferred.Result.return (R.success (Args.VDI.Epoch_begin.rpc_of_response ()))
    end else if not persistent then begin
      (* We create a non-persistent disk here with Volume.clone, and store
         the name of the cloned disk in the metadata of the original. *)
      ( match List.Assoc.find response.Storage.Volume.Types.keys _clone_on_boot_key with
        | None ->
          return (Ok ())
        | Some temporary ->
          (* Destroy the temporary disk we made earlier *)
          destroy root_dir name args.Args.VDI.Epoch_begin.dbg sr temporary
      ) >>= fun () ->
      clone root_dir name args.Args.VDI.Epoch_begin.dbg sr args.Args.VDI.Epoch_begin.vdi
      >>= fun vdi ->
      set root_dir name args.Args.VDI.Epoch_begin.dbg sr args.Args.VDI.Epoch_begin.vdi _clone_on_boot_key vdi.Storage.Volume.Types.key
      >>= fun () ->
      Deferred.Result.return (R.success (Args.VDI.Epoch_begin.rpc_of_response ()))
    end else Deferred.Result.return (R.success (Args.VDI.Epoch_begin.rpc_of_response ()))
  | { R.name = "VDI.epoch_end"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    let args = Args.VDI.Epoch_end.request_of_rpc args in
    Attached_SRs.find args.Args.VDI.Epoch_end.sr
    >>= fun sr ->
    (* Discover the URIs using Volume.stat *)
    stat root_dir name args.Args.VDI.Epoch_end.dbg sr args.Args.VDI.Epoch_end.vdi
    >>= fun response ->
    choose_datapath response
    >>= fun (datapath, uri, domain) ->
    if Datapath_plugins.supports_feature datapath _nonpersistent then begin
      let args = Storage.Datapath.Types.Datapath.Close.In.make
        args.Args.VDI.Epoch_end.dbg
        uri in
      let args = Storage.Datapath.Types.Datapath.Close.In.rpc_of_t args in
      fork_exec_rpc root_dir (script root_dir name (`Datapath datapath) "Datapath.close") args Storage.Datapath.Types.Datapath.Close.Out.t_of_rpc
      >>= fun () ->
      Deferred.Result.return (R.success (Args.VDI.Epoch_end.rpc_of_response ()))
    end else begin
      match List.Assoc.find response.Storage.Volume.Types.keys _clone_on_boot_key with
      | None ->
        Deferred.Result.return (R.success (Args.VDI.Epoch_end.rpc_of_response ()))
      | Some temporary ->
        (* Destroy the temporary disk we made earlier *)
        destroy root_dir name args.Args.VDI.Epoch_end.dbg sr temporary
        >>= fun () ->
        unset root_dir name args.Args.VDI.Epoch_end.dbg sr args.Args.VDI.Epoch_end.vdi _clone_on_boot_key
        >>= fun () ->
        Deferred.Result.return (R.success (Args.VDI.Epoch_end.rpc_of_response ()))
    end
  | { R.name = "VDI.set_persistent"; R.params = [ args ] } ->
    let open Deferred.Result.Monad_infix in
    (* We don't do anything until the VDI.epoch_begin *)
    Deferred.Result.return (R.success (Args.VDI.Set_persistent.rpc_of_response ()))
  | { R.name = name } ->
    Deferred.return (Error (backend_error "UNIMPLEMENTED" [ name ])))
  >>= function
  | Result.Error error ->
    info "returning error %s" (Jsonrpc.string_of_response (R.failure error));
    return (Jsonrpc.string_of_response (R.failure error))
  | Result.Ok rpc ->
    return (Jsonrpc.string_of_response rpc)

(* Active servers, one per sub-directory of the root_dir *)
let servers = String.Table.create () ~size:4

(* XXX: need a better error-handling strategy *)
let get_ok = function
  | `Ok x -> x
  | `Error e ->
    let b = Buffer.create 16 in
    let fmt = Format.formatter_of_buffer b in
    Protocol_unix.Server.pp_error fmt e;
    Format.pp_print_flush fmt ();
    failwith (Buffer.contents b)


let rec diff a b = match a with
  | [] -> []
  | a :: aa ->
    if List.mem b a then diff aa b else a :: (diff aa b)

let watch_volume_plugins ~root_dir ~switch_path ~pipe =
  let create switch_path root_dir name =
    if Hashtbl.mem servers name
      then return ()
      else begin
        info "Adding %s" name;
        Protocol_async.Server.listen ~process:(process root_dir name) ~switch:switch_path ~queue:(Filename.basename name) ()
        >>= fun result ->
        let server = get_ok result in
        Hashtbl.add_exn servers name server;
        return ()
      end in
  let destroy switch_path name =
    info "Removing %s" name;
    if Hashtbl.mem servers name then begin
      let t = Hashtbl.find_exn servers name in
      Protocol_async.Server.shutdown ~t () >>= fun () ->
      Hashtbl.remove servers name;
      return ()
    end else return () in
  let sync ~root_dir ~switch_path =
    Sys.readdir root_dir
    >>= fun names ->
    let needed : string list = Array.to_list names in
    let got_already : string list = Hashtbl.keys servers in
    Deferred.all_ignore (List.map ~f:(create switch_path root_dir) (diff needed got_already))
    >>= fun () ->
    Deferred.all_ignore (List.map ~f:(destroy switch_path) (diff got_already needed)) in
  sync ~root_dir ~switch_path
  >>= fun () ->
  let open Async_inotify.Event in
  let rec loop () =
    ( Pipe.read pipe >>= function
    | `Eof ->
      info "Received EOF from inotify event pipe";
      Shutdown.exit 1
    | `Ok (Created path)
    | `Ok (Moved (Into path)) ->
      create switch_path root_dir (Filename.basename path)
    | `Ok (Unlinked path)
    | `Ok (Moved (Away path)) ->
      destroy switch_path (Filename.basename path)
    | `Ok (Modified _) ->
      return ()
    | `Ok (Moved (Move (path_a, path_b))) ->
      destroy switch_path (Filename.basename path_a)
      >>= fun () ->
      create switch_path root_dir (Filename.basename path_b)
    | `Ok Queue_overflow ->
      sync ~root_dir ~switch_path
    ) >>= fun () ->
    loop () in
  loop ()

let watch_datapath_plugins ~root_dir ~pipe =
  let sync ~root_dir =
    Sys.readdir root_dir
    >>= fun names ->
    let needed : string list = Array.to_list names in
    let got_already : string list = Hashtbl.keys servers in
    Deferred.all_ignore (List.map ~f:(Datapath_plugins.register root_dir) (diff needed got_already))
    >>= fun () ->
    Deferred.all_ignore (List.map ~f:(Datapath_plugins.unregister root_dir) (diff got_already needed)) in
  sync ~root_dir
  >>= fun () ->
  let open Async_inotify.Event in
  let rec loop () =
    ( Pipe.read pipe >>= function
    | `Eof ->
      info "Received EOF from inotify event pipe";
      Shutdown.exit 1
    | `Ok (Created path)
    | `Ok (Moved (Into path)) ->
      Datapath_plugins.register root_dir (Filename.basename path)
    | `Ok (Unlinked path)
    | `Ok (Moved (Away path)) ->
      Datapath_plugins.unregister root_dir (Filename.basename path)
    | `Ok (Modified _) ->
      return ()
    | `Ok (Moved (Move (path_a, path_b))) ->
      Datapath_plugins.unregister root_dir (Filename.basename path_a)
      >>= fun () ->
      Datapath_plugins.register root_dir (Filename.basename path_b)
    | `Ok Queue_overflow ->
      sync ~root_dir
    ) >>= fun () ->
    loop () in
  loop ()

let main ~root_dir ~state_path ~switch_path =
  Attached_SRs.reload state_path
  >>= fun () ->
  let datapath_root = Filename.concat root_dir "datapath" in
  Async_inotify.create ~recursive:false ~watch_new_dirs:false datapath_root
  >>= fun (watch, _) ->
  let datapath = Async_inotify.pipe watch in
  let volume_root = Filename.concat root_dir "volume" in
  Async_inotify.create ~recursive:false ~watch_new_dirs:false volume_root
  >>= fun (watch, _) ->
  let volume = Async_inotify.pipe watch in

  let rec loop () =
    Monitor.try_with
      (fun () ->
        Deferred.all_unit [
          watch_volume_plugins ~root_dir:volume_root ~switch_path ~pipe:volume;
          watch_datapath_plugins ~root_dir:datapath_root ~pipe:datapath
        ]
      )
    >>= function
    | Ok () ->
      info "main thread shutdown cleanly";
      return ()
    | Error x ->
      error "main thread failed with %s" (Exn.to_string x);
      Clock.after (Time.Span.of_sec 5.) >>= fun () -> 
      loop () in
  loop ()

open Xcp_service

let description = String.concat ~sep:" " [
  "Allow xapi storage adapters to be written as individual scripts.";
  "To add a storage adapter, create a sub-directory in the --root directory";
  "with the name of the adapter (e.g. org.xen.xcp.storage.mylvm) and place";
  "the scripts inside.";
]

let _ =
  let root_dir = ref "/var/lib/xapi/storage-scripts" in
  let state_path = ref "/var/run/nonpersistent/xapi-storage-script/state.db" in

  let resources = [
    { Xcp_service.name = "root";
      description = "directory whose sub-directories contain sets of per-operation scripts, one sub-directory per queue name";
      essential = true;
      path = root_dir;
      perms = [ U.X_OK ];
    }; { Xcp_service.name = "state";
      description = "file containing attached SR information, should be deleted on host boot";
      essential = false;
      path = state_path;
      perms = [ ];
    }
  ] in

  (match configure2
    ~name:"xapi-script-storage"
    ~version:Version.version
    ~doc:description
    ~resources
    () with
  | `Ok () -> ()
  | `Error x ->
    error "Error: %s\n%!" x;
    Pervasives.exit 1);

  if !Xcp_service.daemon then begin
    Xcp_service.maybe_daemonize ();
    use_syslog := true;
    info "Daemonisation successful.";
  end;
  let (_: unit Deferred.t) =
    let rec loop () =
      Monitor.try_with
        (fun () ->
          main ~root_dir:!root_dir ~state_path:!state_path ~switch_path:!Xcp_client.switch_path
        )
      >>= function
      | Ok () ->
        info "main thread shutdown cleanly";
        return ()
      | Error x ->
        error "main thread failed with %s" (Exn.to_string x);
        Clock.after (Time.Span.of_sec 5.) >>= fun () -> 
        loop () in
    loop () in
  never_returns (Scheduler.go ())

