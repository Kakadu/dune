open! Stdune

(* HACK Otherwise ocamldep doesn't detect this module in bootstrap *)
let () =
  let module M = Sub_system_info in
  ()

module Vfile = Dune_lang.Versioned_file.Make (struct
  type t = unit
end)

module Lib = struct
  type t =
    { info : Path.t Lib_info.t
    ; modules : Modules.t option
    ; main_module_name : Module_name.t option
    ; requires : (Loc.t * Lib_name.t) list
    }

  let make ~info ~main_module_name ~requires ~modules =
    let obj_dir = Lib_info.obj_dir info in
    let dir = Obj_dir.dir obj_dir in
    let map_path p =
      if Path.is_managed p then
        Path.relative dir (Path.basename p)
      else
        p
    in
    let info = Lib_info.map_path info ~f:map_path in
    { info; main_module_name; requires; modules }

  let dir_of_name name =
    let _, components = Lib_name.split name in
    Path.Local.L.relative Path.Local.root components

  let encode ~package_root { info; requires; main_module_name; modules } =
    let open Dune_lang.Encoder in
    let no_loc f (_loc, x) = f x in
    let path = Dpath.Local.encode ~dir:package_root in
    let paths name f = field_l name path f in
    let mode_paths name (xs : Path.t Mode.Dict.List.t) =
      field_l name sexp (Mode.Dict.List.encode path xs)
    in
    let known_implementations =
      Lib_info.known_implementations info |> Variant.Map.to_list
    in
    let libs name = field_l name (no_loc Lib_name.encode) in
    let name = Lib_info.name info in
    let kind = Lib_info.kind info in
    let modes = Lib_info.modes info in
    let synopsis = Lib_info.synopsis info in
    let obj_dir = Lib_info.obj_dir info in
    let orig_src_dir = Lib_info.orig_src_dir info in
    let implements = Lib_info.implements info in
    let ppx_runtime_deps = Lib_info.ppx_runtime_deps info in
    let default_implementation = Lib_info.default_implementation info in
    let special_builtin_support = Lib_info.special_builtin_support info in
    let archives = Lib_info.archives info in
    let sub_systems = Lib_info.sub_systems info in
    let plugins = Lib_info.plugins info in
    let foreign_archives = Lib_info.foreign_archives info in
    let foreign_objects =
      match Lib_info.foreign_objects info with
      | External e -> e
      | Local -> assert false
    in
    let jsoo_runtime = Lib_info.jsoo_runtime info in
    let virtual_ = Option.is_some (Lib_info.virtual_ info) in
    record_fields
    @@ [ field "name" Lib_name.encode name
       ; field "kind" Lib_kind.encode kind
       ; field_b "virtual" virtual_
       ; field_o "synopsis" string synopsis
       ; field_o "orig_src_dir" path orig_src_dir
       ; mode_paths "archives" archives
       ; mode_paths "plugins" plugins
       ; paths "foreign_objects" foreign_objects
       ; mode_paths "foreign_archives" foreign_archives
       ; paths "jsoo_runtime" jsoo_runtime
       ; libs "requires" requires
       ; libs "ppx_runtime_deps" ppx_runtime_deps
       ; field_o "implements" (no_loc Lib_name.encode) implements
       ; field_l "known_implementations"
           (pair Variant.encode (no_loc Lib_name.encode))
           known_implementations
       ; field_o "default_implementation" (no_loc Lib_name.encode)
           default_implementation
       ; field_o "main_module_name" Module_name.encode main_module_name
       ; field_l "modes" sexp (Mode.Dict.Set.encode modes)
       ; field_l "obj_dir" sexp (Obj_dir.encode obj_dir)
       ; field_o "modules" Modules.encode modules
       ; field_o "special_builtin_support"
           Dune_file.Library.Special_builtin_support.encode
           special_builtin_support
       ]
    @ ( Sub_system_name.Map.to_list sub_systems
      |> List.map ~f:(fun (name, info) ->
             let (module S) = Sub_system_info.get name in
             match info with
             | S.T info ->
               let _ver, sexps = S.encode info in
               field_l (Sub_system_name.to_string name) sexp sexps
             | _ -> assert false) )

  let decode ~(lang : Vfile.Lang.Instance.t) ~base =
    let open Dune_lang.Decoder in
    let path = Dpath.Local.decode ~dir:base in
    let field_l s x = field ~default:[] s (repeat x) in
    let libs s = field_l s (located Lib_name.decode) in
    let paths s = field_l s path in
    let mode_paths name =
      field ~default:Mode.Dict.List.empty name (Mode.Dict.List.decode path)
    in
    fields
      (let* main_module_name = field_o "main_module_name" Module_name.decode in
       let* implements = field_o "implements" (located Lib_name.decode) in
       let* default_implementation =
         field_o "default_implementation" (located Lib_name.decode)
       in
       let* name = field "name" Lib_name.decode in
       let dir = Path.append_local base (dir_of_name name) in
       let* obj_dir = field_o "obj_dir" (Obj_dir.decode ~dir) in
       let obj_dir =
         match obj_dir with
         | None -> Obj_dir.make_external_no_private ~dir
         | Some obj_dir -> obj_dir
       in
       let+ synopsis = field_o "synopsis" string
       and+ loc = loc
       and+ modes = field_l "modes" Mode.decode
       and+ kind = field "kind" Lib_kind.decode
       and+ archives = mode_paths "archives"
       and+ plugins = mode_paths "plugins"
       and+ foreign_objects = paths "foreign_objects"
       and+ foreign_archives = mode_paths "foreign_archives"
       and+ jsoo_runtime = paths "jsoo_runtime"
       and+ requires = libs "requires"
       and+ ppx_runtime_deps = libs "ppx_runtime_deps"
       and+ virtual_ = field_b "virtual"
       and+ known_implementations =
         field_l "known_implementations"
           (pair Variant.decode (located Lib_name.decode))
       and+ sub_systems = Sub_system_info.record_parser ()
       and+ orig_src_dir = field_o "orig_src_dir" path
       and+ modules =
         let src_dir = Obj_dir.dir obj_dir in
         field_o "modules"
           (Modules.decode
              ~implements:(Option.is_some implements)
              ~src_dir ~version:lang.version)
       and+ special_builtin_support =
         field_o "special_builtin_support"
           ( Dune_lang.Syntax.since Stanza.syntax (1, 10)
           >>> Dune_file.Library.Special_builtin_support.decode )
       in
       let known_implementations =
         Variant.Map.of_list_exn known_implementations
       in
       let modes = Mode.Dict.Set.of_list modes in
       let info : Path.t Lib_info.t =
         let src_dir = Obj_dir.dir obj_dir in
         let enabled = Lib_info.Enabled_status.Normal in
         let status = Lib_info.Status.Installed in
         let version = None in
         let main_module_name =
           Dune_file.Library.Inherited.This main_module_name
         in
         let foreign_objects = Lib_info.Source.External foreign_objects in
         let requires = Lib_info.Deps.Simple requires in
         let jsoo_archive = None in
         let pps = [] in
         let virtual_deps = [] in
         let dune_version = None in
         let virtual_ =
           if virtual_ then
             let modules = Option.value_exn modules in
             Some (Lib_info.Source.External modules)
           else
             None
         in
         let variant = None in
         let wrapped =
           Option.map modules ~f:Modules.wrapped
           |> Option.map ~f:(fun w -> Dune_file.Library.Inherited.This w)
         in
         Lib_info.create ~loc ~name ~kind ~status ~src_dir ~orig_src_dir
           ~obj_dir ~version ~synopsis ~main_module_name ~sub_systems ~requires
           ~foreign_objects ~plugins ~archives ~ppx_runtime_deps
           ~foreign_archives ~jsoo_runtime ~jsoo_archive ~pps ~enabled
           ~virtual_deps ~dune_version ~virtual_ ~implements ~variant
           ~known_implementations ~default_implementation ~modes ~wrapped
           ~special_builtin_support
       in
       { info; requires; main_module_name; modules })

  let modules t = t.modules

  let main_module_name t = t.main_module_name

  let requires t = t.requires

  let compare_name x y =
    let x = Lib_info.name x.info in
    let y = Lib_info.name y.info in
    Lib_name.compare x y

  let wrapped t = Option.map t.modules ~f:Modules.wrapped

  let info dp = dp.info
end

type t =
  { libs : Lib.t list
  ; name : Package.Name.t
  ; version : string option
  ; dir : Path.t
  }

let decode ~lang ~dir =
  let open Dune_lang.Decoder in
  let+ name = field "name" Package.Name.decode
  and+ version = field_o "version" string
  and+ libs = multi_field "library" (Lib.decode ~lang ~base:dir) in
  { name
  ; version
  ; libs =
      List.map libs ~f:(fun (lib : Lib.t) ->
          let info = Lib_info.set_version lib.info version in
          { lib with info })
  ; dir
  }

let () = Vfile.Lang.register Stanza.syntax ()

let prepend_version ~dune_version sexps =
  let open Dune_lang.Encoder in
  let list s = Dune_lang.List s in
  [ list
      [ Dune_lang.atom "lang"
      ; string (Dune_lang.Syntax.name Stanza.syntax)
      ; Dune_lang.Syntax.Version.encode dune_version
      ]
  ]
  @ sexps

let encode ~dune_version { libs; name; version; dir } =
  let list s = Dune_lang.List s in
  let sexp = [ list [ Dune_lang.atom "name"; Package.Name.encode name ] ] in
  let sexp =
    match version with
    | None -> sexp
    | Some version ->
      sexp
      @ [ List
            [ Dune_lang.atom "version"
            ; Dune_lang.atom_or_quoted_string version
            ]
        ]
  in
  let libs =
    List.map libs ~f:(fun lib ->
        list (Dune_lang.atom "library" :: Lib.encode lib ~package_root:dir))
  in
  prepend_version ~dune_version (sexp @ libs)

module Or_meta = struct
  type nonrec t =
    | Use_meta
    | Dune_package of t

  let encode ~dune_version = function
    | Use_meta ->
      prepend_version ~dune_version [ Dune_lang.(List [ atom "use_meta" ]) ]
    | Dune_package p -> encode ~dune_version p

  let decode ~lang ~dir =
    let open Dune_lang.Decoder in
    fields
      (let* use_meta = field_b "use_meta" in
       if use_meta then
         return Use_meta
       else
         let+ package = decode ~lang ~dir in
         Dune_package package)

  let load p =
    Vfile.load p ~f:(fun lang -> decode ~lang ~dir:(Path.parent_exn p))
end