(** Copyright 2024, Kostya Oreshin and Nikita Shchutskii *)

(** SPDX-License-Identifier: MIT *)

open Angstrom
open Ast

let ws =
  many
  @@ satisfy
  @@ function
  | ' ' | '\t' -> true
  | _ -> false
;;

let ( >>>= ) p f = ws *> p >>= f
let ( let** ) = ( >>>= )
let ( <**> ) f p = f <*> ws *> p
let ( **> ) p f = ws *> p *> (ws *> f)
let etp = (None : tp option) (* remove later (tp parser is required) *)
let parens p = char '(' *> ws *> p <* (ws <* char ')')

let is_alpha = function
  | 'a' .. 'z' | 'A' .. 'Z' -> true
  | _ -> false
;;

let is_digit = function
  | '0' .. '9' -> true
  | _ -> false
;;

let const =
  choice
    [ (let* y = take_while1 is_digit in
       let x = int_of_string y in
       return (Int x))
    ; string "()" *> return Unit
    ; string "True" *> return (Bool true)
    ; string "False" *> return (Bool false)
    ]
;;

let%test "const_valid_num" =
  parse_string ~consume:Prefix const "123" = Result.Ok (Int 123)
;;

let%test "const_invalid_num" =
  parse_string ~consume:Prefix const "123ab" = Result.Ok (Int 123)
;;

let%test "const_valid_unit" = parse_string ~consume:Prefix const "()" = Result.Ok Unit

let%test "const_valid_true" =
  parse_string ~consume:Prefix const "True" = Result.Ok (Bool true)
;;

let%test "const_valid_false" =
  parse_string ~consume:Prefix const "False" = Result.Ok (Bool false)
;;

let%test "const_invalid" =
  parse_string ~consume:Prefix const "beb" = Result.Error ": no more choices"
;;

let ident =
  let keywords =
    [ "case"
    ; "of"
    ; "class"
    ; "data"
    ; "default"
    ; "deriving"
    ; "do"
    ; "forall"
    ; "foreign"
    ; "hiding"
    ; "if"
    ; "then"
    ; "else"
    ; "import"
    ; "infix"
    ; "infixl"
    ; "infixr"
    ; "instance"
    ; "let"
    ; "in"
    ; "mdo"
    ; "module"
    ; "newtype"
    ; "proc"
    ; "qualified"
    ; "rec"
    ; "type"
    ; "where"
    ]
  in
  (let* x =
     satisfy (function
       | 'a' .. 'z' -> true
       | _ -> false)
   in
   let* y =
     take_while (fun c ->
       is_digit c || is_alpha c || Char.equal '_' c || Char.equal '\'' c)
   in
   return (Printf.sprintf "%c%s" x y))
  <|> (let* x = satisfy (fun c -> Char.equal '_' c) in
       let* y =
         take_while1 (fun c ->
           is_digit c || is_alpha c || Char.equal '_' c || Char.equal '\'' c)
       in
       return (Printf.sprintf "%c%s" x y))
  >>= fun identifier ->
  match List.find_opt (String.equal identifier) keywords with
  | None -> return (Ident identifier)
  | Some k -> fail (Printf.sprintf "keyword '%s' cannot be an identifier" k)
;;

let%test "ident_valid_starts_with_underline" =
  parse_string ~consume:Prefix ident "_123abc" = Result.Ok (Ident "_123abc")
;;

let%test "ident_invalid" =
  parse_string ~consume:Prefix ident "_" = Result.Error ": count_while1"
;;

let%test "ident_valid_'" =
  parse_string ~consume:Prefix ident "x'" = Result.Ok (Ident "x'")
;;

let%test "ident_invalid_keyword" =
  parse_string ~consume:Prefix ident "do"
  = Result.Error ": keyword 'do' cannot be an identifier"
;;

let pat =
  (let* pt = const in
   return (PConst pt))
  <|> let* pt = ident in
      return (PIdentificator pt)
;;

let ptrn ptrn =
  (let* ident = ident in
   char '@'
   *> (ptrn <|> parens ptrn >>= fun (idents, pat, tp) -> return (ident :: idents, pat, tp)))
  <|>
  let oth_ptrn =
    let* pat = pat in
    (* let* tp = tp in *)
    return ([], pat, etp)
  in
  oth_ptrn <|> parens oth_ptrn
;;

let pattern = ptrn (fix ptrn)

let%test "pattern_valid_as" =
  parse_string ~consume:Prefix pattern "adada@(   x   )"
  = Result.Ok ([ Ident "adada" ], PIdentificator (Ident "x"), None)
;;

let%test "pattern_valid_parens_oth" =
  parse_string ~consume:Prefix pattern "(   x   )"
  = Result.Ok ([], PIdentificator (Ident "x"), None)
;;

let%test "pattern_valid_double_as" =
  parse_string ~consume:Prefix pattern "a@b@2"
  = Result.Ok ([ Ident "a"; Ident "b" ], PConst (Int 2), None)
;;

let return_true_expr = return (Const (Bool true), None)

let bindingbody e =
  (char '='
   **> let* ex = e in
       return (OrdBody ex))
  <|>
  let+ ee_pairs =
    many1
      (char '|'
       **> let* ex1 = string "otherwise" *> return_true_expr <|> e in
           char '='
           **> let* ex2 = e in
               return (ex1, ex2))
  in
  match ee_pairs with
  | [] -> failwith " many1 result can't be empty"
  | hd :: tl -> Guards (hd, tl)
;;

let b e b =
  (let** ident = ident in
   (* let* ft = option None (functype <** char ';') in *)
   let** pt = pattern in
   let* pts = many (ws *> pattern) in
   return (fun bb where_binds -> FunBind ((ident, None), pt, pts, bb, where_binds)))
  <|> (let** pt = pattern in
       return (fun bb where_binds -> VarsBind (pt, bb, where_binds)))
  <**> bindingbody e
  <**> option [] @@ (string "where" **> sep_by (ws *> char ';' *> ws) b)
;;

let binding e = fix (b e) |> b @@ e

type assoc =
  | Left
  | Right
  | Non

let prios_list =
  [ [ (Non, string "==", fun a b -> Binop (a, Equality, b), etp)
    ; (Non, string "/=", fun a b -> Binop (a, Inequality, b), etp)
    ; (Non, string ">=", fun a b -> Binop (a, EqualityOrGreater, b), etp)
    ; (Non, string "<=", fun a b -> Binop (a, EqualityOrLess, b), etp)
    ; (Non, string ">", fun a b -> Binop (a, Greater, b), etp)
    ; (Non, string "<", fun a b -> Binop (a, Less, b), etp)
    ]
  ; [ (Left, string "+", fun a b -> Binop (a, Plus, b), etp)
    ; (Left, string "-", fun a b -> Binop (a, Minus, b), etp)
    ]
  ; [ (Left, string "`div`", fun a b -> Binop (a, Divide, b), etp)
    ; (Left, string "*", fun a b -> Binop (a, Multiply, b), etp)
    ]
  ; [ (Right, string "^", fun a b -> Binop (a, Pow, b), etp) ]
  ]
;;

let bo expr prios_list =
  let rec loop acc = function
    | [] -> acc
    | (Right, op, r) :: tl -> op acc (loop r tl)
    | ((Left | Non), op, r) :: tl -> loop (op acc r) tl
  in
  let rec helper ?(prev_is_non_assoc = false) prios_list =
    match prios_list with
    | [] -> ws *> expr
    | hd :: tl ->
      return loop
      <**> helper tl
      <*> many
            (choice
               (List.map
                  (fun (ass, op, f) ->
                    match ass with
                    | Non ->
                      op **> helper tl ~prev_is_non_assoc:true
                      >>>=
                      if prev_is_non_assoc
                      then
                        fun _ ->
                        fail
                          "cannot mix two non-associative operators in the same infix \
                           expression"
                      else fun r -> return (ass, f, r)
                    | _ -> op **> helper tl >>>= fun r -> return (ass, f, r))
                  hd))
  in
  helper prios_list
;;

let const_e =
  let+ c = const in
  Const c, etp
;;

let ident_e =
  let+ i = ident in
  Identificator i, etp
;;

let if_then_else e =
  let+ cond = string "if" **> e
  and+ th_br = string "then" **> e
  and+ el_br = string "else" **> e in
  IfThenEsle (cond, th_br, el_br), etp
;;

let inner_bindings e =
  string "let"
  **> let+ bnd = binding e
      and+ bnds = many @@ (char ';' **> binding e)
      and+ ex = string "in" **> e in
      InnerBindings (bnd, bnds, ex), etp
;;

let opt_e e =
  ws *> (string "Nothing" *> return (OptionBld Nothing, etp))
  <|> string "Just"
      *> let** ex = e in
         return (OptionBld (Just ex), etp)
;;

let other_expr e fa =
  choice [ const_e; ident_e; opt_e e; if_then_else e; inner_bindings e; parens e ]
  >>= fun ex -> fa ex e <|> return ex
;;

let binop e fa = bo (other_expr e fa) prios_list

let function_apply ex e =
  let+ r = many1 (ws *> (const_e <|> ident_e <|> parens e)) in
  match r with
  | [] -> failwith "many1 result can't be empty"
  | hd :: tl -> FunctionApply (ex, hd, tl), etp
;;

let e e =
  binop e function_apply
  <|> other_expr e function_apply
  >>= fun ex -> function_apply ex e <|> return ex
;;

let expr = e (fix e)

let test call sh str =
  match parse_string ~consume:Prefix call str with
  | Ok v -> print_endline (sh v)
  | Error msg -> failwith msg
;;

let%expect_test "expr_const" =
  test expr show_expr "1";
  [%expect {|
      ((Const (Int 1)), None) |}]
;;

let%expect_test "expr_prio" =
  test expr show_expr "(1 + 1)*2 > 1";
  [%expect
    {|
      ((Binop (
          ((Binop (
              ((Binop (((Const (Int 1)), None), Plus, ((Const (Int 1)), None))),
               None),
              Multiply, ((Const (Int 2)), None))),
           None),
          Greater, ((Const (Int 1)), None))),
       None) |}]
;;

let%expect_test "expr_with_func_apply" =
  test expr show_expr "f 2 2 + 1";
  [%expect
    {|
      ((Binop (
          ((FunctionApply (((Identificator (Ident "f")), None),
              ((Const (Int 2)), None), [((Const (Int 2)), None)])),
           None),
          Plus, ((Const (Int 1)), None))),
       None) |}]
;;

let binding = binding expr

let%expect_test "var_binding_simple" =
  test binding show_binding "x = 1";
  [%expect
    {|
      (VarsBind (([], (PIdentificator (Ident "x")), None),
         (OrdBody ((Const (Int 1)), None)), [])) |}]
;;

let%expect_test "var_binding_with_where" =
  test binding show_binding "x = y where y = 1; k = 2 ";
  [%expect
    {|
      (VarsBind (([], (PIdentificator (Ident "x")), None),
         (OrdBody ((Identificator (Ident "y")), None)),
         [(VarsBind (([], (PIdentificator (Ident "y")), None),
             (OrdBody ((Const (Int 1)), None)), []));
           (VarsBind (([], (PIdentificator (Ident "k")), None),
              (OrdBody ((Const (Int 2)), None)), []))
           ]
         )) |}]
;;

let%expect_test "fun_binding_simple" =
  test binding show_binding "f x = x + 1";
  [%expect
    {|
      (FunBind (((Ident "f"), None), ([], (PIdentificator (Ident "x")), None),
         [],
         (OrdBody
            ((Binop (((Identificator (Ident "x")), None), Plus,
                ((Const (Int 1)), None))),
             None)),
         [])) |}]
;;

let%expect_test "fun_binding_guards" =
  test binding show_binding "f x |x > 1 = 0 | otherwise = 1";
  [%expect
    {|
      (FunBind (((Ident "f"), None), ([], (PIdentificator (Ident "x")), None),
         [],
         (Guards (
            (((Binop (((Identificator (Ident "x")), None), Greater,
                 ((Const (Int 1)), None))),
              None),
             ((Const (Int 0)), None)),
            [(((Const (Bool true)), None), ((Const (Int 1)), None))])),
         [])) |}]
;;

let parse_and_print_line = test binding show_binding

let parse_line str =
  match parse_string ~consume:Prefix binding str with
  | Result.Ok v -> v
  | Error msg -> failwith msg
;;
