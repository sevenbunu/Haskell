(** Copyright 2024, Kostya Oreshin and Nikita Shchutskii *)

(** SPDX-License-Identifier: MIT *)

open Angstrom
open Ast
open Integer

let ws1 =
  many1
  @@ satisfy
  @@ function
  | ' ' | '\t' -> true
  | _ -> false
;;

let ws = option [] ws1
let ( >>>= ) p f = ws *> p >>= f
let ( let** ) = ( >>>= )
let ( <**> ) f p = f <*> ws *> p
let ( **> ) p f = ws *> p *> (ws *> f)
let etp = [] (* remove later (tp parser is required) *)

let parens, sq_brackets, backticks, braces =
  let bounded (ch1, ch2) p = char ch1 *> ws *> p <* (ws <* char ch2) in
  ( (fun p -> bounded ('(', ')') p)
  , (fun p -> bounded ('[', ']') p)
  , (fun p -> bounded ('`', '`') p)
  , fun p -> bounded ('{', '}') p )
;;

let is_alpha = function
  | 'a' .. 'z' | 'A' .. 'Z' -> true
  | _ -> false
;;

let is_digit = function
  | '0' .. '9' -> true
  | _ -> false
;;

let is_char_suitable_for_ident c =
  is_digit c || is_alpha c || Char.equal '_' c || Char.equal '\'' c
;;

let prs_ln call str = parse_string ~consume:Prefix call str

let prs_and_prnt_ln call sh str =
  match prs_ln call str with
  | Ok v -> print_endline (sh v)
  | Error msg -> Printf.fprintf stderr "error: %s" msg
;;

let word req_word =
  let open String in
  if equal req_word empty
  then return empty
  else
    let* fst_smb = satisfy is_alpha in
    let* w = take_while is_char_suitable_for_ident in
    if equal (Printf.sprintf "%c%s" fst_smb w) req_word
    then return req_word
    else Printf.sprintf "couldn't parse word '%s'" req_word |> fail
;;

let%test "word_valid" =
  parse_string ~consume:Prefix (word "then") "then" = Result.Ok "then"
;;

let%test "word_invalid" =
  parse_string ~consume:Prefix (word "then") "thena"
  = Result.Error ": couldn't parse word 'then'"
;;

let ident =
  let keywords = [ "case"; "of"; "if"; "then"; "else"; "let"; "in"; "where" ] in
  (let* x =
     satisfy (function
       | 'a' .. 'z' -> true
       | _ -> false)
   in
   let* y = take_while is_char_suitable_for_ident in
   return (Printf.sprintf "%c%s" x y))
  <|> (let* x = satisfy (Char.equal '_') in
       let* y = take_while1 is_char_suitable_for_ident in
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
  parse_string ~consume:Prefix ident "then"
  = Result.Error ": keyword 'then' cannot be an identifier"
;;

let tuple_or_parensed_item item tuple_cons item_cons =
  parens (sep_by1 (ws *> char ',' *> ws) item)
  >>= fun l ->
  match l with
  | hd :: [] -> item_cons hd
  | fs :: sn :: tl -> tuple_cons fs sn tl
  | [] -> fail "sep_by1 result can't be empty"
;;

let is_char_suitable_for_oper = function
  | '&' | '|' | '+' | '-' | ':' | '*' | '=' | '^' | '/' | '\\' | '<' | '>' | '.' -> true
  | _ -> false
;;

let oper expected =
  let* parsed =
    backticks ident
    >>| (fun (Ident s) ->
          let open String in
          concat empty [ "`"; s; "`" ])
    <|> take_while is_char_suitable_for_oper
  in
  if String.equal expected parsed then return expected else fail ""
;;

let%expect_test "oper_valid" =
  prs_and_prnt_ln (oper "+-+") Fun.id "+-+awq";
  [%expect {|
      +-+|}]
;;

let%expect_test "oper_invalid" =
  prs_and_prnt_ln (oper "+-+") Fun.id "+-+>";
  [%expect {|
      error: :|}]
;;

let%expect_test "oper_with_backticks" =
  prs_and_prnt_ln (oper "`a`") Fun.id "`a`";
  [%expect {|
      `a`|}]
;;

let func_tp_tail hd ord_tp =
  many (oper "->" **> ord_tp)
  >>= function
  | sn :: tl -> return (FunctionType (FuncT (hd, sn, tl)))
  | _ -> fail ""
;;

let ord_tp tp =
  let w = word in
  choice
    [ string "()" *> return TUnit
    ; w "Int" *> return TInt
    ; w "Bool" *> return TBool
    ; (sq_brackets tp >>| fun x -> ListParam x)
    ; (braces tp >>| fun x -> TreeParam x)
    ; tuple_or_parensed_item tp (fun fs sn tl -> return (TupleParams (fs, sn, tl))) return
    ]
;;

let tp =
  let t t = ord_tp t >>= fun res -> option res (func_tp_tail res (ord_tp t)) in
  fix t
;;

let%expect_test "tp_list_of_func" =
  prs_and_prnt_ln tp show_tp "[Int -> Int] ";
  [%expect {| (ListParam (FunctionType (FuncT (TInt, TInt, [])))) |}]
;;

let%expect_test "tp_tree_of_func" =
  prs_and_prnt_ln tp show_tp "{Bool -> ()} ";
  [%expect {| (TreeParam (FunctionType (FuncT (TBool, TUnit, [])))) |}]
;;

let%expect_test "tp_lnested_func" =
  prs_and_prnt_ln tp show_tp "Int -> ((Int -> Int)) -> Int";
  [%expect
    {| (FunctionType (FuncT (TInt, (FunctionType (FuncT (TInt, TInt, []))), [TInt]))) |}]
;;

let%expect_test "tp_tuple" =
  prs_and_prnt_ln tp show_tp "(Int, Bool, Int -> Bool)";
  [%expect {| (TupleParams (TInt, TBool, [(FunctionType (FuncT (TInt, TBool, [])))])) |}]
;;

let nonnegative_integer =
  let* y = take_while1 is_digit in
  match Nonnegative_integer.of_string_opt y with
  | None -> fail ""
  | Some x -> return x
;;

let const =
  choice
    [ (let+ x = nonnegative_integer in
       Integer x)
    ; string "()" *> return Unit
    ; string "True" *> return (Bool true)
    ; string "False" *> return (Bool false)
    ]
;;

let%test "const_valid_num" =
  parse_string ~consume:Prefix const "123"
  = Result.Ok (Integer (Nonnegative_integer.of_int 123))
;;

let%test "const_invalid_num" =
  parse_string ~consume:Prefix const "123ab"
  = Result.Ok (Integer (Nonnegative_integer.of_int 123))
;;

let%test "const_invalid_num_negative" =
  parse_string ~consume:Prefix const "-123" = Result.Error ": no more choices"
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

let nothing f = word "Nothing" *> f
let just f = word "Just" *> ws *> f
let list_enum item f = sq_brackets (sep_by (ws *> char ',' *> ws) item) >>= f

let tree item nul_cons node_cons =
  char '$' *> nul_cons
  <|> (parens (sep_by (ws *> char ';' *> ws) item)
       >>= function
       | [ it1; it2; it3 ] -> node_cons it1 it2 it3
       | _ -> fail "cannot parse tree")
;;

let pt_tp ((a, p, tps) as pt) = option pt (oper "::" **> tp >>| fun tp -> a, p, tp :: tps)

let pnegation =
  oper "-" *> ws *> nonnegative_integer >>| fun a -> [], PConst (NegativePInteger a), etp
;;

let just_p ptrn = just (ptrn >>| fun p -> [], PMaybe (Just p), etp)

let pcons_tail head ptrn_ext =
  let rec loop constr = function
    | [] -> constr ([], PList (PEnum []), etp)
    | hd :: [] -> constr hd
    | hd :: tl -> loop (fun y -> constr ([], PList (PCons (hd, y)), etp)) tl
  in
  many1 (oper ":" **> ptrn_ext)
  >>| List.rev
  >>| loop (fun (x : pattern) -> [], PList (PCons (head, x)), etp)
;;

let pat ptrn =
  let ptrn_extended ptrn_extended =
    let* p = ptrn <|> pnegation <|> just_p ptrn in
    option p (pcons_tail p ptrn_extended)
  in
  choice
    [ (let* pt = const in
       return (PConst (OrdinaryPConst pt)))
    ; (let* pt = ident in
       return (PIdentificator pt))
    ; char '_' *> return PWildcard
    ; nothing (return (PMaybe Nothing))
    ; tree
        (ws *> fix ptrn_extended >>= pt_tp)
        (return (PTree PNul))
        (fun d t1 t2 -> return (PTree (PNode (d, t1, t2))))
    ; list_enum (fix ptrn_extended >>= pt_tp) (fun pts -> return (PList (PEnum pts)))
    ]
;;

let ptrn ptrn =
  let ptrn_extended ptrn_extended =
    let* p = ptrn <|> pnegation <|> just_p ptrn in
    option p (pcons_tail p ptrn_extended)
  in
  choice
    [ (let* ident = ident in
       char '@' *> (ptrn >>= fun (idents, pat, tp) -> return (ident :: idents, pat, tp)))
    ; (let* pat = pat ptrn in
       return ([], pat, etp))
    ; tuple_or_parensed_item
        (fix ptrn_extended >>= pt_tp)
        (fun p1 p2 pp -> return ([], PTuple (p1, p2, pp), etp))
        (fun p -> return p)
    ]
;;

type unparansed_pseudoops_handling =
  | Ban_p
  | Allow_p

type unparnsed_tp_handling =
  | Ban_t
  | Allow_t

let pattern unp_ps_h unp_tp_h =
  let p = fix ptrn in
  match unp_ps_h with
  | Ban_p -> p
  | Allow_p ->
    let ptr' ptr' =
      p <|> pnegation <|> just_p p >>= fun hd -> option hd (pcons_tail hd ptr')
    in
    fix ptr'
    >>=
      (match unp_tp_h with
      | Ban_t -> return
      | Allow_t -> pt_tp)
;;

let%test "pattern_valid_as" =
  parse_string ~consume:Prefix (pattern Allow_p Allow_t) "adada@(   x   )"
  = Result.Ok ([ Ident "adada" ], PIdentificator (Ident "x"), [])
;;

let%test "pattern_valid_parens_oth" =
  parse_string ~consume:Prefix (pattern Allow_p Allow_t) "(   x   )"
  = Result.Ok ([], PIdentificator (Ident "x"), [])
;;

let%test "pattern_valid_neg" =
  parse_string ~consume:Prefix (pattern Allow_p Allow_t) "-1"
  = Result.Ok ([], PConst (NegativePInteger (Nonnegative_integer.of_int 1)), [])
;;

let%test "pattern_invalid_banned_neg" =
  parse_string ~consume:Prefix (pattern Ban_p Allow_t) "-1"
  = Result.Error ": no more choices"
;;

let%test "pattern_valid_double_as" =
  parse_string ~consume:Prefix (pattern Allow_p Allow_t) "a@b@2"
  = Result.Ok
      ( [ Ident "a"; Ident "b" ]
      , PConst (OrdinaryPConst (Integer (Nonnegative_integer.of_int 2)))
      , [] )
;;

let%test "pattern_valid_with_parens" =
  parse_string ~consume:Prefix (pattern Allow_p Allow_t) "(a@(b@(2)))"
  = Result.Ok
      ( [ Ident "a"; Ident "b" ]
      , PConst (OrdinaryPConst (Integer (Nonnegative_integer.of_int 2)))
      , [] )
;;

let%expect_test "pattern_valid_tuple" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "(x, y,(x,y))";
  [%expect
    {|
      ([],
       (PTuple (([], (PIdentificator (Ident "x")), []),
          ([], (PIdentificator (Ident "y")), []),
          [([],
            (PTuple (([], (PIdentificator (Ident "x")), []),
               ([], (PIdentificator (Ident "y")), []), [])),
            [])]
          )),
       []) |}]
;;

let%expect_test "pattern_valid_tuple_labeled" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "a@(x, e@y,b@(x,y))";
  [%expect
    {|
      ([(Ident "a")],
       (PTuple (([], (PIdentificator (Ident "x")), []),
          ([(Ident "e")], (PIdentificator (Ident "y")), []),
          [([(Ident "b")],
            (PTuple (([], (PIdentificator (Ident "x")), []),
               ([], (PIdentificator (Ident "y")), []), [])),
            [])]
          )),
       []) |}]
;;

let%expect_test "pattern_invalid_tuple_labeled" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "(x, e@y,(x,y)@(x,y))";
  [%expect {|
      error: : satisfy: '(' |}]
;;

let%expect_test "pattern_valid_tree" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "(2; $; $)";
  [%expect
    {|
      ([],
       (PTree
          (PNode (([], (PConst (OrdinaryPConst (Integer 2))), []),
             ([], (PTree PNul), []), ([], (PTree PNul), [])))),
       []) |}]
;;

let%expect_test "pattern_invalid_tree" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "(2; $)";
  [%expect {|
      error: : satisfy: '(' |}]
;;

let%expect_test "pattern_just_valid" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "Just 1";
  [%expect
    {|
      ([], (PMaybe (Just ([], (PConst (OrdinaryPConst (Integer 1))), []))), []) |}]
;;

let%expect_test "pattern_just_invalid_ban_unparansed" =
  prs_and_prnt_ln (pattern Ban_p Allow_t) show_pattern "Just 1";
  [%expect {|
      error: : no more choices |}]
;;

let%expect_test "pattern_just_invalid_neg" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "Just -1";
  [%expect {|
      error: : no more choices |}]
;;

let%expect_test "pattern_nil_valid" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "[]";
  [%expect {| ([], (PList (PEnum [])), []) |}]
;;

let%expect_test "pattern_enum_valid" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "[1, 2,1  ,1]";
  [%expect
    {|
    ([],
     (PList
        (PEnum
           [([], (PConst (OrdinaryPConst (Integer 1))), []);
             ([], (PConst (OrdinaryPConst (Integer 2))), []);
             ([], (PConst (OrdinaryPConst (Integer 1))), []);
             ([], (PConst (OrdinaryPConst (Integer 1))), [])])),
     [])
       |}]
;;

let%expect_test "pattern_listcons_invalid_ban_unparansed" =
  prs_and_prnt_ln (pattern Ban_p Allow_t) show_pattern "x:xs";
  [%expect {|
      ([], (PIdentificator (Ident "x")), []) |}]
;;

let%expect_test "pattern_listcons_valid" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "x:(y:z):w";
  [%expect
    {|
      ([],
       (PList
          (PCons (([], (PIdentificator (Ident "x")), []),
             ([],
              (PList
                 (PCons (
                    ([],
                     (PList
                        (PCons (([], (PIdentificator (Ident "y")), []),
                           ([], (PIdentificator (Ident "z")), [])))),
                     []),
                    ([], (PIdentificator (Ident "w")), [])))),
              [])
             ))),
       []) |}]
;;

let%expect_test "pattern_simple_valid_tp" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "x :: Int";
  [%expect {|
    ([], (PIdentificator (Ident "x")), [TInt])
       |}]
;;

let%expect_test "pattern_simple_invalid_tp_ban" =
  prs_and_prnt_ln (pattern Allow_p Ban_t) show_pattern "x :: Int";
  [%expect {|
    ([], (PIdentificator (Ident "x")), [])
       |}]
;;

let%expect_test "pattern_listcons_valid_with_tp" =
  prs_and_prnt_ln (pattern Allow_p Allow_t) show_pattern "x:y:z :: [Int]";
  [%expect {|
    ([],
     (PList
        (PCons (([], (PIdentificator (Ident "x")), []),
           ([],
            (PList
               (PCons (([], (PIdentificator (Ident "y")), []),
                  ([], (PIdentificator (Ident "z")), [])))),
            [])
           ))),
     [(ListParam TInt)])
       |}]
;;

let bindingbody e sep =
  (sep
   **> let* ex = e in
       return (OrdBody ex))
  <|>
  let* ee_pairs =
    many1
      (oper "|"
       **> let* ex1 = e in
           sep
           **> let* ex2 = e in
               return (ex1, ex2))
  in
  match ee_pairs with
  | [] -> fail " many1 result can't be empty"
  | hd :: tl -> Guards (hd, tl) |> return
;;

let bnd e bnd =
  (let** ident = ident in
   let** pt = pattern Ban_p Ban_t in
   let* pts = many (ws *> pattern Ban_p Ban_t) in
   return (fun bb where_binds -> FunBind ((ident, None), pt, pts, bb, where_binds)))
  <|> (let** pt = pattern Ban_p Allow_t in
       return (fun bb where_binds -> VarsBind (pt, bb, where_binds)))
  <**> bindingbody e (oper "=")
  <**> option [] @@ (word "where" **> sep_by (ws *> char ';' *> ws) bnd)
;;

let binding e = fix (bnd e)

type assoc =
  | Left
  | Right
  | Non

let prios_list =
  [ None, [ (Right, oper "||", fun a b -> Binop (a, Or, b), etp) ]
  ; None, [ (Right, oper "&&", fun a b -> Binop (a, And, b), etp) ]
  ; ( None
    , [ (Non, oper "==", fun a b -> Binop (a, Equality, b), etp)
      ; (Non, oper "/=", fun a b -> Binop (a, Inequality, b), etp)
      ; (Non, oper ">=", fun a b -> Binop (a, EqualityOrGreater, b), etp)
      ; (Non, oper "<=", fun a b -> Binop (a, EqualityOrLess, b), etp)
      ; (Non, oper ">", fun a b -> Binop (a, Greater, b), etp)
      ; (Non, oper "<", fun a b -> Binop (a, Less, b), etp)
      ] )
  ; ( Some (oper "-", fun a -> Neg a, etp)
    , [ (Right, oper ":", fun a b -> Binop (a, Cons, b), etp)
      ; (Left, oper "+", fun a b -> Binop (a, Plus, b), etp)
      ; (Left, oper "-", fun a b -> Binop (a, Minus, b), etp)
      ] )
  ; ( None
    , [ (Left, oper "`div`", fun a b -> Binop (a, Divide, b), etp)
      ; (Left, oper "*", fun a b -> Binop (a, Multiply, b), etp)
      ; (Left, oper "`mod`", fun a b -> Binop (a, Mod, b), etp)
      ] )
  ; None, [ (Right, oper "^", fun a b -> Binop (a, Pow, b), etp) ]
  ]
;;

let non_assoc_ops_seq_check l =
  List.fold_left
    (fun (prev_assoc, error_flag) (ass, _, _) ->
      ass, if error_flag || (prev_assoc == Non && ass == Non) then true else false)
    (Left, false)
    l
  |> snd
  |> fun error_flag ->
  if error_flag
  then fail "cannot mix two non-associative operators in the same infix expression"
  else return l
;;

let op expr prios_list =
  let rec loop acc = function
    | [] -> acc
    | (Right, op, r) :: tl -> op acc (loop r tl)
    | ((Left | Non), op, r) :: tl -> loop (op acc r) tl
  in
  let rec helper = function
    | [] -> ws *> expr
    | hd :: tl ->
      return loop
      <**> helper tl
      <*> (choice
             (List.map
                (fun (ass, op, f) -> op **> helper tl >>= fun r -> return (ass, f, r))
                (snd hd))
           |> many
           >>= non_assoc_ops_seq_check)
      <|>
        (match fst hd with
        | Some (op, f) -> ws *> (op **> helper tl) >>= fun a -> return (f a)
        | _ -> fail "")
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
  let+ cond = word "if" **> e
  and+ th_br = word "then" **> e
  and+ el_br = word "else" **> e in
  IfThenEsle (cond, th_br, el_br), etp
;;

let inner_bindings e =
  word "let"
  **> let+ bnd = binding e
      and+ bnds = many @@ (char ';' **> binding e)
      and+ ex = word "in" **> e in
      InnerBindings (bnd, bnds, ex), etp
;;

let just_e =
  just
    (return
       ( Lambda
           ( ([], PIdentificator (Ident "X"), etp)
           , []
           , (OptionBld (Just (Identificator (Ident "X"), [])), etp) )
       , etp ))
;;

let lambda e =
  oper "\\"
  *> let** pt = pattern Ban_p Ban_t in
     let* pts = many (ws *> pattern Ban_p Ban_t) in
     let* ex = string "->" **> e in
     return (Lambda (pt, pts, ex), etp)
;;

let tree_e e =
  tree
    e
    ((BinTreeBld Nul, etp) |> return)
    (fun ex1 ex2 ex3 -> return (BinTreeBld (Node (ex1, ex2, ex3)), etp))
;;

let case e =
  word "case"
  *> let** ex = e in
     word "of"
     **>
     let* br1, brs =
       sep_by1
         (ws *> char ';' *> ws)
         (both (pattern Allow_p Ban_t) (bindingbody e (oper "->")))
       >>= function
       | [] -> fail "sep_by1 cant return empty list"
       | hd :: tl -> return (hd, tl)
     in
     return (Case (ex, br1, brs), etp)
;;

let list_e e =
  list_enum e (fun l -> return (ListBld (OrdList (IncomprehensionlList l)), etp))
  <|>
  let condition = return (fun exp -> Condition exp) <*> e in
  let generator =
    return (fun (pat, exp) -> Generator (pat, exp))
    <*> both (pattern Allow_p Allow_t <* ws <* oper "<-" <* ws) e
  in
  (let** ex1 = e in
   choice
     [ (oper "|" **> sep_by1 (ws *> char ',' *> ws) (generator <|> condition)
        >>= function
        | [] -> fail ""
        | hd :: tl -> return (OrdList (ComprehensionList (ex1, hd, tl))))
     ; (let option_ex f = option None (f >>| fun x -> Some x) in
        both (option_ex (char ',' **> e)) (oper ".." **> option_ex e)
        >>| fun (ex2, ex3) -> LazyList (ex1, ex2, ex3))
     ]
   >>| fun l -> ListBld l, etp)
  |> sq_brackets
;;

let tuple_or_parensed_item_e e =
  tuple_or_parensed_item
    e
    (fun ex1 ex2 exs -> return (TupleBld (ex1, ex2, exs), etp))
    (fun ex -> return ex)
;;

let other_expr e fa =
  choice
    [ const_e
    ; ident_e
    ; nothing (return (OptionBld Nothing, etp))
    ; just_e
    ; if_then_else e
    ; case e
    ; inner_bindings e
    ; lambda e
    ; tree_e e
    ; list_e e
    ; tuple_or_parensed_item_e e
    ]
  >>= fun ex -> fa ex e <|> return ex
;;

let oper e fa = op (other_expr e fa) prios_list

let function_application ex e =
  let* r =
    many1
      (ws
       *> choice
            [ const_e
            ; ident_e
            ; just_e
            ; nothing (return (OptionBld Nothing, etp))
            ; tree_e e
            ; list_e e
            ; tuple_or_parensed_item_e e
            ])
  in
  match r with
  | [] -> fail "many1 result can't be empty"
  | hd :: tl -> (FunctionApply (ex, hd, tl), etp) |> return
;;

let e e =
  oper e function_application
  <|> other_expr e function_application
  >>= fun ex -> function_application ex e <|> return ex
;;

let expr = fix e

let%expect_test "expr_const" =
  prs_and_prnt_ln expr show_expr "123456789012345678901234567890";
  [%expect {|
      ((Const (Integer 123456789012345678901234567890)), []) |}]
;;

let%expect_test "expr_prio" =
  prs_and_prnt_ln expr show_expr "(1 + 1)*2 > 1";
  [%expect
    {|
      ((Binop (
          ((Binop (
              ((Binop (((Const (Integer 1)), []), Plus, ((Const (Integer 1)), []))),
               []),
              Multiply, ((Const (Integer 2)), []))),
           []),
          Greater, ((Const (Integer 1)), []))),
       []) |}]
;;

let%expect_test "expr_div_mod" =
  prs_and_prnt_ln expr show_expr "10 `div` 3 `mod` 2";
  [%expect
    {|
      ((Binop (
          ((Binop (((Const (Integer 10)), []), Divide, ((Const (Integer 3)), []))),
           []),
          Mod, ((Const (Integer 2)), []))),
       []) |}]
;;

let%expect_test "expr_right_assoc" =
  prs_and_prnt_ln expr show_expr "2^3^4";
  [%expect
    {|
      ((Binop (((Const (Integer 2)), []), Pow,
          ((Binop (((Const (Integer 3)), []), Pow, ((Const (Integer 4)), []))), [])
          )),
       []) |}]
;;

let%expect_test "expr_with_Just" =
  prs_and_prnt_ln expr show_expr "Just 2 + 1";
  [%expect
    {|
      ((Binop (
          ((FunctionApply (
              ((Lambda (([], (PIdentificator (Ident "X")), []), [],
                  ((OptionBld (Just ((Identificator (Ident "X")), []))), []))),
               []),
              ((Const (Integer 2)), []), [])),
           []),
          Plus, ((Const (Integer 1)), []))),
       []) |}]
;;

let%expect_test "expr_with_func_apply" =
  prs_and_prnt_ln expr show_expr "f(x) g(2) + 1";
  [%expect
    {|
      ((Binop (
          ((FunctionApply (((Identificator (Ident "f")), []),
              ((Identificator (Ident "x")), []),
              [((Identificator (Ident "g")), []); ((Const (Integer 2)), [])])),
           []),
          Plus, ((Const (Integer 1)), []))),
       []) |}]
;;

let%expect_test "expr_with_func_apply_strange_but_valid1" =
  prs_and_prnt_ln expr show_expr "f 9a";
  [%expect
    {|
      ((FunctionApply (((Identificator (Ident "f")), []),
          ((Const (Integer 9)), []), [((Identificator (Ident "a")), [])])),
       []) |}]
;;

let%expect_test "expr_with_func_apply_strange_but_valid2" =
  prs_and_prnt_ln expr show_expr "f Just(1)";
  [%expect
    {|
      ((FunctionApply (((Identificator (Ident "f")), []),
          ((Lambda (([], (PIdentificator (Ident "X")), []), [],
              ((OptionBld (Just ((Identificator (Ident "X")), []))), []))),
           []),
          [((Const (Integer 1)), [])])),
       []) |}]
;;

let%expect_test "expr_with_non-assoc_op_simple" =
  prs_and_prnt_ln expr show_expr "x == y";
  [%expect
    {|
      ((Binop (((Identificator (Ident "x")), []), Equality,
          ((Identificator (Ident "y")), []))),
       []) |}]
;;

let%expect_test "expr_with_non-assoc_ops_invalid" =
  prs_and_prnt_ln expr show_expr "x == y + 1 >= z";
  [%expect {|
      ((Identificator (Ident "x")), []) |}]
;;

let%expect_test "expr_with_non-assoc_ops_valid" =
  prs_and_prnt_ln expr show_expr "x == y && z == z'";
  [%expect
    {|
      ((Binop (
          ((Binop (((Identificator (Ident "x")), []), Equality,
              ((Identificator (Ident "y")), []))),
           []),
          And,
          ((Binop (((Identificator (Ident "z")), []), Equality,
              ((Identificator (Ident "z'")), []))),
           [])
          )),
       []) |}]
;;

let%expect_test "expr_case_statement" =
  prs_and_prnt_ln expr show_expr "case x of 1 -> 1; _ -> 2 ";
  [%expect
    {|
      ((Case (((Identificator (Ident "x")), []),
          (([], (PConst (OrdinaryPConst (Integer 1))), []),
           (OrdBody ((Const (Integer 1)), []))),
          [(([], PWildcard, []), (OrdBody ((Const (Integer 2)), [])))])),
       []) |}]
;;

let%expect_test "expr_case_statement_with_guards" =
  prs_and_prnt_ln expr show_expr "case x of y | y > 10 -> 1 | otherwise -> 2;  _ -> 3 ";
  [%expect
    {|
      ((Case (((Identificator (Ident "x")), []),
          (([], (PIdentificator (Ident "y")), []),
           (Guards (
              (((Binop (((Identificator (Ident "y")), []), Greater,
                   ((Const (Integer 10)), []))),
                []),
               ((Const (Integer 1)), [])),
              [(((Identificator (Ident "otherwise")), []),
                ((Const (Integer 2)), []))]
              ))),
          [(([], PWildcard, []), (OrdBody ((Const (Integer 3)), [])))])),
       []) |}]
;;

let%expect_test "expr_tuple" =
  prs_and_prnt_ln expr show_expr " (x,1 , 2,(x, y))";
  [%expect
    {|
      ((TupleBld (((Identificator (Ident "x")), []), ((Const (Integer 1)), []),
          [((Const (Integer 2)), []);
            ((TupleBld (((Identificator (Ident "x")), []),
                ((Identificator (Ident "y")), []), [])),
             [])
            ]
          )),
       []) |}]
;;

let%expect_test "expr_lambda" =
  prs_and_prnt_ln expr show_expr " \\x -> x+1";
  [%expect
    {|
      ((Lambda (([], (PIdentificator (Ident "x")), []), [],
          ((Binop (((Identificator (Ident "x")), []), Plus,
              ((Const (Integer 1)), []))),
           [])
          )),
       []) |}]
;;

let%expect_test "expr_tree" =
  prs_and_prnt_ln expr show_expr "1 + (2; $; $)";
  [%expect
    {|
      ((Binop (((Const (Integer 1)), []), Plus,
          ((BinTreeBld
              (Node (((Const (Integer 2)), []), ((BinTreeBld Nul), []),
                 ((BinTreeBld Nul), [])))),
           [])
          )),
       []) |}]
;;

let%expect_test "expr_plus_neg" =
  prs_and_prnt_ln expr show_expr "1 + -1";
  [%expect {|
      ((Const (Integer 1)), []) |}]
;;

let%expect_test "expr_and_neg" =
  prs_and_prnt_ln expr show_expr "1 && -1";
  [%expect
    {|
      ((Binop (((Const (Integer 1)), []), And,
          ((Neg ((Const (Integer 1)), [])), []))),
       []) |}]
;;

let%expect_test "expr_tuple_neg" =
  prs_and_prnt_ln expr show_expr "(-1, 1)";
  [%expect
    {|
      ((TupleBld (((Neg ((Const (Integer 1)), [])), []), ((Const (Integer 1)), []),
          [])),
       []) |}]
;;

let%expect_test "expr_lambda neg" =
  prs_and_prnt_ln expr show_expr " \\ -1 -> 1";
  [%expect {|
      error: : no more choices |}]
;;

let%expect_test "expr_case_neg" =
  prs_and_prnt_ln expr show_expr "case-1of-1->1";
  [%expect
    {|
      ((Case (((Neg ((Const (Integer 1)), [])), []),
          (([], (PConst (NegativePInteger 1)), []),
           (OrdBody ((Const (Integer 1)), []))),
          [])),
       []) |}]
;;

let%expect_test "expr_list_incomprehensional" =
  prs_and_prnt_ln expr show_expr "[1, f 2, ()]";
  [%expect
    {|
      ((ListBld
          (OrdList
             (IncomprehensionlList
                [((Const (Integer 1)), []);
                  ((FunctionApply (((Identificator (Ident "f")), []),
                      ((Const (Integer 2)), []), [])),
                   []);
                  ((Const Unit), [])]))),
       []) |}]
;;

let%expect_test "expr_list_comprehensional_cond" =
  prs_and_prnt_ln expr show_expr "[ x | x > 2]";
  [%expect
    {|
      ((ListBld
          (OrdList
             (ComprehensionList (((Identificator (Ident "x")), []),
                (Condition
                   ((Binop (((Identificator (Ident "x")), []), Greater,
                       ((Const (Integer 2)), []))),
                    [])),
                [])))),
       []) |}]
;;

let%expect_test "expr_list_comprehensional_gen" =
  prs_and_prnt_ln expr show_expr "[ x | x <- [1, 2, 3]]";
  [%expect
    {|
      ((ListBld
          (OrdList
             (ComprehensionList (((Identificator (Ident "x")), []),
                (Generator
                   (([], (PIdentificator (Ident "x")), []),
                    ((ListBld
                        (OrdList
                           (IncomprehensionlList
                              [((Const (Integer 1)), []);
                                ((Const (Integer 2)), []);
                                ((Const (Integer 3)), [])]))),
                     []))),
                [])))),
       []) |}]
;;

let%expect_test "expr_list_lazy_valid" =
  List.iter
    (prs_and_prnt_ln expr show_expr)
    [ "[1..]"; "[1, 3 .. 10]"; "[1..10]"; "[1,3..]" ];
  [%expect
    {|
      ((ListBld (LazyList (((Const (Integer 1)), []), None, None))), [])
      ((ListBld
          (LazyList (((Const (Integer 1)), []), (Some ((Const (Integer 3)), [])),
             (Some ((Const (Integer 10)), []))))),
       [])
      ((ListBld
          (LazyList (((Const (Integer 1)), []), None,
             (Some ((Const (Integer 10)), []))))),
       [])
      ((ListBld
          (LazyList (((Const (Integer 1)), []), (Some ((Const (Integer 3)), [])),
             None))),
       []) |}]
;;

let binding = binding expr

let%expect_test "var_binding_simple" =
  prs_and_prnt_ln binding show_binding "x = 1";
  [%expect
    {|
      (VarsBind (([], (PIdentificator (Ident "x")), []),
         (OrdBody ((Const (Integer 1)), [])), [])) |}]
;;

let%expect_test "var_binding_with_where" =
  prs_and_prnt_ln binding show_binding "x = y where y = 1; k = 2 ";
  [%expect
    {|
      (VarsBind (([], (PIdentificator (Ident "x")), []),
         (OrdBody ((Identificator (Ident "y")), [])),
         [(VarsBind (([], (PIdentificator (Ident "y")), []),
             (OrdBody ((Const (Integer 1)), [])), []));
           (VarsBind (([], (PIdentificator (Ident "k")), []),
              (OrdBody ((Const (Integer 2)), [])), []))
           ]
         )) |}]
;;

let%expect_test "fun_binding_simple" =
  prs_and_prnt_ln binding show_binding "f x = x + 1";
  [%expect
    {|
      (FunBind (((Ident "f"), None), ([], (PIdentificator (Ident "x")), []),
         [],
         (OrdBody
            ((Binop (((Identificator (Ident "x")), []), Plus,
                ((Const (Integer 1)), []))),
             [])),
         [])) |}]
;;

let%expect_test "fun_binding_simple_strange_but_valid1" =
  prs_and_prnt_ln binding show_binding "f(x)y = x + y";
  [%expect
    {|
      (FunBind (((Ident "f"), None), ([], (PIdentificator (Ident "x")), []),
         [([], (PIdentificator (Ident "y")), [])],
         (OrdBody
            ((Binop (((Identificator (Ident "x")), []), Plus,
                ((Identificator (Ident "y")), []))),
             [])),
         [])) |}]
;;

let%expect_test "fun_binding_simple_strange_but_valid2" =
  prs_and_prnt_ln binding show_binding "f 9y = y";
  [%expect
    {|
      (FunBind (((Ident "f"), None),
         ([], (PConst (OrdinaryPConst (Integer 9))), []),
         [([], (PIdentificator (Ident "y")), [])],
         (OrdBody ((Identificator (Ident "y")), [])), [])) |}]
;;

let%expect_test "fun_binding_guards" =
  prs_and_prnt_ln binding show_binding "f x |x > 1 = 0 | otherwise = 1";
  [%expect
    {|
      (FunBind (((Ident "f"), None), ([], (PIdentificator (Ident "x")), []),
         [],
         (Guards (
            (((Binop (((Identificator (Ident "x")), []), Greater,
                 ((Const (Integer 1)), []))),
              []),
             ((Const (Integer 0)), [])),
            [(((Identificator (Ident "otherwise")), []), ((Const (Integer 1)), []))
              ]
            )),
         [])) |}]
;;

let parse_and_print_line = prs_and_prnt_ln binding show_binding
let parse_line str = prs_ln binding str
