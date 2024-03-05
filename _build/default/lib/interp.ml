(* COMP 360H Project 1:  an interpreter for an imperative language.
 *
 * N. Danner
 *)

module E = Ast.Expression
module S = Ast.Stm
module P = Ast.Program

(* 'a IdentMap.t:  the type of maps from identifiers to 'a.
 *)
module IdentMap = Map.Make(Ast.Id)

(* MultipleDeclaration x is raised when x is declared more than once in a
 * block.
 *)
exception MultipleDeclaration of Ast.Id.t

(* UnboundVariable x is raised when x is used but not declared.
 *)
exception UnboundVariable of Ast.Id.t

(* UndefinedFunction f is raised when f is called but has not been defined.
 *)
exception UndefinedFunction of Ast.Id.t

(* TypeError s is raised when an operator or function is applied to operands
 * of the incorrect type.  s is any (hopefuly useful) message.
 *)
exception TypeError of string

(* Values.
 *)
module Value = struct
  type t = 
    | V_Undefined
    | V_None
    | V_Int of int
    | V_Bool of bool
    | V_Str of string
    [@@deriving show]

  (* to_string v = a string representation of v (more human-readable than
   * `show`.
   *)
  let to_string (v : t) : string =
    match v with
    | V_Undefined -> "?"
    | V_None -> "None"
    | V_Int n -> Int.to_string n
    | V_Bool b -> Bool.to_string b
    | V_Str s -> s
end

(* An implementation of the I/O API.  This is a little bit complex, because
 * this one implementation allows for a few variations:
 * - The input and output channel can be set by the client (default to
 *   standard input and output).
 * - The display of prompts (for the prompt_* functions) can be turned off
 *   (default on).
 * These variations let us use this module for interactive use (use the
 * defaults) and testing (redirect the i/o channels to a programmatic stream
 * and turn off the display of prompts.
 *
 * A client makes changes to the defaults by setting `in_channel`,
 * `out_channel`, and `show_prompts`.
 *)


module Api = struct

  (* Raised when a function is invoked that is not in the API.
   *)
  exception ApiError of string

  (* in_channel:  input channel (for get_*, prompt_* ).
   *)
  let in_channel : Scanf.Scanning.in_channel ref = 
    ref Scanf.Scanning.stdin

  (* out_channel:  output channel (for print_*, prompt_* when prompts are
   * displayed).
   *)
  let out_channel : Out_channel.t ref = ref Out_channel.stdout

  (* show_prompts:  true to display prompts, false to not display.
   *)
  let show_prompts : bool ref = ref true

  (* output oc s:  output `s` to `oc` and flush `oc`.
   *)
  let output (oc : Out_channel.t) (s : string) : unit =
    Out_channel.output_string oc s ;
    Out_channel.flush oc

  (* outputnl oc s = output `s ^ '\n'` to `oc` and flush `oc`.
   *)
  let outputnl (oc : Out_channel.t) (s : string) : unit =
    output oc (s ^ "\n")

  (* The API definition.  The API is specified by a
   * (string*(Value.t->Value.t)) list.  Each element names an API function
   * and provides the code to be executed when the function is called.
   *)
  let api : (Value.t list -> Value.t) IdentMap.t =
    [
      ("print_bool", fun vs ->
        match vs with
        | [Value.V_Bool n] -> 
          outputnl (!out_channel) (Bool.to_string n) ; Value.V_None
        | _ -> raise @@ TypeError "Bad argument type for print_bool"
      )
    ; ("get_bool", fun vs ->
        match vs with
        | [] -> Value.V_Bool (Scanf.bscanf !in_channel " %B" (fun b -> b))
        | _ -> raise @@ TypeError "Bad argument type for get_bool"
      )
    ; ("prompt_bool", fun vs ->
        match vs with
        | [Value.V_Str s] ->
          if !show_prompts then output (!out_channel) s else () ;
            Value.V_Bool (Scanf.bscanf !in_channel " %B" (fun b -> b))
        | _ -> raise @@ TypeError "Bad argument type for prompt_bool"
      )
    ; ("print_int", fun vs ->
        match vs with
        | [Value.V_Int n] -> 
          outputnl (!out_channel) (Int.to_string n) ; Value.V_None
        | _ -> raise @@ TypeError "Bad argument type for print_int"
      )
    ; ("get_int", fun vs ->
        match vs with
        | [] -> Value.V_Int (Scanf.bscanf !in_channel " %d" (fun n -> n))
        | _ -> raise @@ TypeError "Bad argument type for get_int"
      )
    ; ("prompt_int", fun vs ->
        match vs with
        | [Value.V_Str s] ->
          if !show_prompts then output (!out_channel) s else () ;
            Value.V_Int (Scanf.bscanf !in_channel " %d" (fun n -> n))
        | _ -> raise @@ TypeError "Bad argument type for prompt_int"
      )
    ; ("print_str", fun vs ->
         match vs with
         | [Value.V_Str s] -> 
           outputnl (!out_channel) s ; Value.V_None
         | _ -> raise @@ TypeError "Bad argument type for print_s"
      )
    ; ("get_str", fun vs ->
        match vs with
        | [] -> Value.V_Str (Scanf.bscanf !in_channel "%s" (fun s -> s))
        | _ -> raise @@ TypeError "Bad argument type for get_str"
      )
    ; ("prompt_str", fun vs ->
        match vs with
        | [Value.V_Str s] ->
          if !show_prompts then output (!out_channel) s else () ;
            Value.V_Str (Scanf.bscanf !in_channel " %s" (fun s -> s))
        | _ -> raise @@ TypeError "Bad argument type for prompt_str"
      )
    ] |> List.to_seq |> IdentMap.of_seq

  (* do_call f vs invokes the API function corresponding to `f` with argument
   * list `vs`.
   *
   * Raises ApiError f: if f is not an API function.
   *)
  let do_call (f : string) (vs : Value.t list) : Value.t =
    try
      IdentMap.find f api vs
    with
    | Not_found -> raise @@ ApiError f

end

module Frame = struct
  (* The type of frames
   *)
  type t = 
    | Env of env.t list
    | Value of Value.t

  let vdec (frame : t) (x : Ast.Id.t) (v : Value.t) : t =
    match frame with
    | [] -> [[(x, v)]] (* Create a new environment with the variable binding *)
    | env :: rest ->
      if List.mem_assoc x env then
        (* Variable already defined in the innermost environment *)
        raise (MultipleDeclaration x)
      else
        (* Add the variable binding to the innermost environment *)
        ((x, v) :: env) :: rest
  
  let rec vlookup (frame : t) (x : Ast.Id.t) : Value.t =
    match frame with
    | [] -> raise (UnboundVariable x)
    | env :: rest ->
      begin
        try
          List.assoc x env
        with Not_found ->
          vlookup rest x (* Lookup in the outer environment *)
      end
end


(* exec p :  execute the program p according to the operational semantics
 * provided as a handout.
 *)
(* exec : Execute the program starting with the 'main' function under an empty frame. *)
let exec (p : Ast.Program.t) : unit =
  let initial_frame = Frame.Env [] in  (* Start with an empty frame (no environments) *)
  
  (* Assuming 'p' has a field 'statements' containing the program body;
     Replace this with the actual way to access the 'main' function or its equivalent in your AST. *)
  match Ast.Program.get_main p with  (* Placeholder for actual method to get the main function body *)
  | Some(main_func_body) ->
      (* Assuming 'exec_stmts' executes the body*)
      ignore (exec_stmts main_func_body initial_frame)
  | None ->
      failwith "No main function found"

(* expressions *)
let binop (op : E.binop) (v : Value.t) (v' : Value.t) : Value.t =
  match (op, v, v') with
  | (E.Plus, Value.V_Int n, Value.V_Int n') -> Value.V_Int (n + n')
  | (E.Minus, Value.V_Int n, Value.V_Int n') -> Value.V_Int (n - n')
  | (E.Times, Value.V_Int n, Value.V_Int n') -> Value.V_Int (n * n')
  | (E.Div, Value.V_Int n, Value.V_Int n') -> Value.V_Int (n / n')
  | (E.Mod, Value.V_Int n, Value.V_Int n') -> Value.V_Int (n mod n')  (* Fixed mod operator for integers *)
  | (E.And, Value.V_Bool b, Value.V_Bool b') -> Value.V_Bool (b && b')  (* Logical AND for booleans *)
  | (E.Or, Value.V_Bool b, Value.V_Bool b') -> Value.V_Bool (b || b')   (* Logical OR for booleans, corrected *)
  | (E.Eq, Value.V_Int n, Value.V_Int n') -> Value.V_Bool (n = n')      (* Equality check for integers *)
  | (E.Ne, Value.V_Int n, Value.V_Int n') -> Value.V_Bool (n <> n')     (* Inequality check for integers *)
  | (E.Lt, Value.V_Int n, Value.V_Int n') -> Value.V_Bool (n < n')      (* Less than for integers *)
  | (E.Le, Value.V_Int n, Value.V_Int n') -> Value.V_Bool (n <= n')     (* Less than or equal for integers *)
  | (E.Gt, Value.V_Int n, Value.V_Int n') -> Value.V_Bool (n > n')      (* Greater than for integers *)
  | (E.Ge, Value.V_Int n, Value.V_Int n') -> Value.V_Bool (n >= n')     (* Greater than or equal for integers *)
  | _ -> raise (TypeError "Invalid operands or operator for binary operation")  (* Handling invalid cases *)


(* statments *)
let rec eval (frame : Frame.t) (e : E.t)(p : Ast.Program.t) : Value.t * Frame.t =
  match e with
  | E.Var x -> (Frame.vlookup frame x, frame)
  | E.Num n -> (Value.V_Int n, frame)
  | E.Bool b -> (Value.V_Bool b, frame)
  | E.Str s -> (Value.V_Str s, frame)
  | E.Binop (op, e1, e2) ->
      let v1, frame1 = eval frame e1 p in
      let v2, frame2 = eval frame1 e2 p in
      (binop op v1 v2, frame2)
  | E.Assign (x, e) ->
      let v, frame' = eval frame e p in
      (v, Frame.vdec frame' x v)
  | E.Not e ->
      let v, frame' = eval frame e p in
      (match v with
       | Value.V_Bool b -> (Value.V_Bool (not b), frame')
       | _ -> failwith "TypeError: Not operation requires a boolean")
  | E.Neg e ->
      let v, frame' = eval frame e p in
      (match v with
       | Value.V_Int n -> (Value.V_Int (-n), frame')
       | _ -> failwith "TypeError: Neg operation requires an integer")
  | E.Call (f, args) ->
    match List.find_opt (fun (name, _, _) -> name = f) p.Ast.Program.functions with
      | Some (_, param_names, body) ->
          let evaluated_args, new_frame = List.fold_right (fun arg (evaluated, fr) ->
              let arg_val, new_fr = eval fr arg p in
              (arg_val :: evaluated, new_fr)) args ([], frame) in
          let frame_with_args = List.fold_left2 (fun fr param_name arg_val ->
              Frame.vdec fr param_name arg_val) new_frame param_names evaluated_args in
          exec_function body frame_with_args p  (* Assuming exec_function handles the execution of function bodies *)
      | None -> failwith ("UndefinedFunction: " ^ f)


and exec_stm (stm : Ast.Stm.t) (frame : Frame.t) (p : Ast.Program.t) : Frame.t =
match stm with
| S.Skip -> frame
| S.VarDec decls ->
    List.fold_left (fun fr (x, opt_e) ->
      match opt_e with
      | None -> Frame.vdec fr x Value.V_Undefined
      | Some e ->
          let v, fr' = eval fr e p in
          Frame.vdec fr' x v) frame decls
| S.Expr e ->
    let _, frame' = eval frame e p in
    frame'
| S.Block stms ->
    List.fold_left (fun fr s -> exec_stm s fr p) frame stms
| S.If (e, s1, s2) ->
    let v, frame' = eval frame e p in
    (match v with
     | Value.V_Bool true -> exec_stm s1 frame' p
     | Value.V_Bool false -> exec_stm s2 frame' p
     | _ -> failwith "TypeError: If condition is not boolean")
| S.While (e, s) ->
    let rec loop fr =
      let v, fr' = eval fr e p in
      match v with
      | Value.V_Bool true -> loop (exec_stm s fr' p)
      | Value.V_Bool false -> fr'
      | _ -> failwith "TypeError: While condition is not boolean"
    in loop frame
| S.Return opt_e ->
    let v = match opt_e with
      | None -> Value.V_None
      | Some e -> fst (eval frame e p)
    in Frame.return frame v  (* Implement Frame.return based on your framework if necessary *)


(* expression *)
and exec_stmList (sl : Ast.Stm.t list) (frame : Frame.t) (p : Ast.Program.t) : Frame.t =
  List.fold_left (fun fr s -> exec_stm s fr p) frame sl
