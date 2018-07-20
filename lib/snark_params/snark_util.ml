open Core_kernel
open Bitstring_lib

module Make (Impl : Snarky.Snark_intf.S) = struct
  open Impl
  open Let_syntax

  let pack_int bs =
    assert (List.length bs < 62);
    let rec go pt acc = function
      | [] -> acc
      | b :: bs ->
        if b
        then go (2 * pt) (pt + acc) bs
        else go (2 * pt) acc bs
    in
    go 1 0 bs
  ;;

  let boolean_assert_lte (x : Boolean.var) (y : Boolean.var) =
    (*
      x <= y
      y == 1 or x = 0
      (y - 1) * x = 0
    *)
    assert_r1cs
      Field.Checked.(sub (y :> Field.Checked.t) (constant Field.one))
      (x :> Field.Checked.t)
      (Field.Checked.constant Field.zero)
  ;;

  let assert_decreasing : Boolean.var list -> (unit, _) Checked.t =
    let rec go prev (bs0 : Boolean.var list) =
      match bs0 with
      | [] -> return ()
      | b :: bs ->
        let%bind () = boolean_assert_lte b prev in
        go b bs
    in
    function
    | [] -> return ()
    | b :: bs -> go b bs
  ;;

  let nth_bit x ~n = (x lsr n) land 1 = 1

  let apply_mask mask bs =
    Checked.all (List.map2_exn mask bs ~f:Boolean.(&&))

  let pack_unsafe (bs0 : Boolean.var list) =
    let n = List.length bs0 in
    assert (n <= Field.size_in_bits);
    let rec go acc two_to_the_i = function
      | b :: bs ->
        go
        (Field.Checked.add acc (Field.Checked.scale b two_to_the_i))
        (Field.add two_to_the_i two_to_the_i)
        bs
      | [] -> acc
    in
    go (Field.Checked.constant Field.zero) Field.one (bs0 :> Field.Checked.t list)
  ;;

  type _ Snarky.Request.t += N_ones : bool list Snarky.Request.t

  let n_ones ~total_length n =
    let%bind bs =
      exists (Typ.list ~length:total_length Boolean.typ)
        ~request:(As_prover.return N_ones)
        ~compute:
          As_prover.(map (read_var n) ~f:(fun n ->
            List.init total_length ~f:(fun i ->
              Bigint.(compare (of_field (Field.of_int i)) (of_field n) < 0))))
    in
    let%map () =
      Field.Checked.Assert.equal
        (Field.Checked.sum (bs :> Field.Checked.t list))
        (* This can't overflow since the field is huge *)
        n
    and () = assert_decreasing bs in
    bs

  let assert_num_bits_upper_bound bs u =
    let total_length = List.length bs in
    assert (total_length < Field.size_in_bits);
    let%bind mask = n_ones ~total_length u in
    let%bind masked = apply_mask mask bs in
    with_label __LOC__ (
      Field.Checked.Assert.equal
        (pack_unsafe masked) (pack_unsafe bs)
    )

  let num_bits_int =
    let rec go acc n =
      if n = 0
      then acc
      else go (1 + acc) (n lsr 1)
    in
    go 0
  ;;

  let size_in_bits_size_in_bits = num_bits_int Field.size_in_bits

  type _ Snarky.Request.t +=
    | Num_bits_upper_bound : Field.t Snarky.Request.t

  let num_bits_upper_bound_unchecked x =
    let num_bits =
      match
        List.find_mapi (List.rev (Field.unpack x)) ~f:(fun i x ->
          if x then Some i else None)
      with
      | Some leading_zeroes -> Field.size_in_bits - leading_zeroes
      | None -> 0
    in
    num_bits

  (* Someday: this could definitely be made more efficient *)
  let num_bits_upper_bound_unpacked : Boolean.var list -> (Field.Checked.t, _) Checked.t =
    fun x_unpacked ->
      let%bind res =
        exists Typ.field
          ~request:(As_prover.return Num_bits_upper_bound)
          ~compute:As_prover.(
            map (read_var (Field.Checked.project x_unpacked))
              ~f:(fun x -> Field.of_int (num_bits_upper_bound_unchecked x)))
      in
      let%map () = assert_num_bits_upper_bound x_unpacked res in
      res
  ;;

  let num_bits_upper_bound ~max_length (x : Field.Checked.t) : (Field.Checked.t, _) Checked.t =
    Field.Checked.unpack x ~length:max_length
    >>= num_bits_upper_bound_unpacked
  ;;

  let lt_bitstring_value =
    let module Expr = struct
      module Binary = struct
        type 'a t =
          | Lit of 'a
          | And of 'a * 'a t
          | Or of 'a * 'a t
      end

      module Nary = struct
        type 'a t =
          | Lit of 'a
          | And of 'a t list
          | Or of 'a t list

        let rec of_binary : 'a Binary.t -> 'a t = function
          | Lit x -> Lit x
          | And (x, And (y, t)) ->
            And [Lit x; Lit y; of_binary t]
          | Or (x, Or (y, t)) ->
            Or [Lit x; Lit y; of_binary t]
          | And (x, t) ->
            And [Lit x; of_binary t]
          | Or (x, t) ->
            Or [Lit x; of_binary t]

        let rec eval = function
          | Lit x -> return x
          | And xs ->
            Checked.List.map xs ~f:eval >>= Boolean.all
          | Or xs ->
            Checked.List.map xs ~f:eval >>= Boolean.any
      end
    end
    in
    let rec lt_binary xs ys : Boolean.var Expr.Binary.t =
      match xs, ys with
      | [], [] -> Lit Boolean.false_
      | [ x ], [ false ] -> Lit Boolean.false_
      | [ x ], [ true ] -> Lit (Boolean.not x)
      | [ x1; x2 ], [ true; false ] -> Lit (Boolean.not x1)
      | [ x1; x2 ], [ false; false ] -> Lit Boolean.false_
      | x :: xs, false :: ys ->
        And (Boolean.not x, lt_binary xs ys)
      | x :: xs, true :: ys ->
        Or (Boolean.not x, lt_binary xs ys)
      | _::_, [] | [], _::_ ->
        failwith "lt_bitstring_value: Got unequal length strings"
    in
    fun (xs : Boolean.var Bitstring.Msb_first.t) (ys : bool Bitstring.Msb_first.t) ->
      Expr.Nary.(
        eval (of_binary (lt_binary (xs :> Boolean.var list) (ys :> bool list))))

  let field_size_bits =
    let testbit n i = Bignum_bigint.((shift_right n i) land one = one) in
    List.init Field.size_in_bits ~f:(fun i ->
      testbit Impl.Field.size
        (Field.size_in_bits - 1 - i))
    |> Bitstring.Msb_first.of_list

  let unpack_field_var x =
    let%bind res =
      Impl.Field.Checked.choose_preimage_var x ~length:Field.size_in_bits
      >>| Bitstring.Lsb_first.of_list
    in
    let%map () =
      lt_bitstring_value
        (Bitstring.Msb_first.of_lsb_first res)
        field_size_bits
      >>= Boolean.Assert.is_true
    in
    res

  let%test_module "Snark_util" = (module struct
    let () = Random.init 123456789

    let random_bitstring length = List.init length ~f:(fun _ -> Random.bool ())

    let random_n_bit_field_elt n = Field.project (random_bitstring n)

    let random_biased_bitstring p length =
      List.init length ~f:(fun _ -> if Random.float 1. < p then false else true)

    (* TODO: Quickcheck this *)
    let%test_unit "lt_bitstring_value" =
      let length = Field.size_in_bits + 5 in
      let test p =
        let value = random_biased_bitstring p length in
        let var = random_bitstring length in
        let correct_answer = var < value in
        let ((), lt) =
          run_and_check
            (Checked.map ~f:(As_prover.read Boolean.typ)
               (lt_bitstring_value
                  (Bitstring.Msb_first.of_list
                     (List.map ~f:Boolean.var_of_value var))
                  (Bitstring.Msb_first.of_list value)))
            ()
          |> Or_error.ok_exn
        in
        assert (lt = correct_answer)
      in
      for _ = 1 to 20 do test 0.5 done;
      for _ = 1 to 20 do test 0.1 done;
      for _ = 1 to 20 do test 0.9 done;
      for _ = 1 to 20 do test 0.02 done;
      for _ = 1 to 20 do test 0.98 done
    ;;

    let%test_unit "compare" =
      let bit_length = Field.size_in_bits - 2 in
      let random () = random_n_bit_field_elt bit_length in
      let test () =
        let x = random () in
        let y = random () in
        let ((), (less, less_or_equal)) =
          run_and_check
            (let%map { less; less_or_equal } =
              Field.Checked.compare ~bit_length (Field.Checked.constant x) (Field.Checked.constant y)
            in
            As_prover.(
              map2 (read Boolean.typ less) (read Boolean.typ less_or_equal)
                ~f:Tuple2.create))
            ()
          |> Or_error.ok_exn
        in
        let r = Bigint.(compare (of_field x) (of_field y)) in
        assert (less = (r < 0));
        assert (less_or_equal = (r <= 0))
      in
      for i = 0 to 100 do
        test ()
      done

    let%test_unit "boolean_assert_lte" =
      assert (
        check
          (Checked.all_unit
          [ boolean_assert_lte Boolean.false_ Boolean.false_ 
          ; boolean_assert_lte Boolean.false_ Boolean.true_
          ; boolean_assert_lte Boolean.true_ Boolean.true_
          ])
          ());
      assert (not (
        check
          (boolean_assert_lte Boolean.true_ Boolean.false_) ()))
    ;;

    let%test_unit "assert_decreasing" =
      let decreasing bs = 
        check (assert_decreasing (List.map ~f:Boolean.var_of_value bs)) ()
      in
      assert (decreasing [true; true; true; false]);
      assert (decreasing [true; true; false; false]);
      assert (not (decreasing [true; true; false; true]));
    ;;

    let%test_unit "n_ones" =
      let total_length = 6 in
      let test n =
        let t = n_ones ~total_length (Field.Checked.constant (Field.of_int n)) in
        let handle_with (resp : bool list) = 
          handle t (fun (With {request; respond}) ->
            match request with
            | N_ones -> respond (Provide resp)
            | _ -> unhandled)
        in
        let correct = Int.pow 2 n - 1 in
        let to_bits k = List.init total_length ~f:(fun i -> (k lsr i) land 1 = 1) in
        for i = 0 to Int.pow 2 total_length - 1 do
          if i = correct
          then assert (check (handle_with (to_bits i)) ())
          else assert (not (check (handle_with (to_bits i)) ()))
        done
      in
      for n = 0 to total_length do
        test n
      done
    ;;

    let%test_unit "num_bits_int" =
      assert (num_bits_int 1 = 1);
      assert (num_bits_int 5 = 3);
      assert (num_bits_int 17 = 5);
    ;;

    let%test_unit "num_bits_upper_bound_unchecked" =
      let f k bs =
        assert (num_bits_upper_bound_unchecked (Field.project bs) = k)
      in
      f 3 [true; true; true; false; false];
      f 4 [true; true; true; true; false];
      f 3 [true; false; true; false; false];
      f 5 [true; false; true; false; true]
    ;;

    (*let%test_unit "num_bits_upper_bound" =
      let max_length = Field.size_in_bits - 1 in
      let test x =
        let handle_with resp =
          handle
            (num_bits_upper_bound ~max_length (Field.Checked.constant x))
            (fun (With {request; respond}) ->
              match request with
              | Num_bits_upper_bound -> respond (Field.of_int resp)
              | _ -> unhandled)
        in
        let true_answer = num_bits_upper_bound_unchecked x in
        for i = 0 to true_answer - 1 do
          if check (handle_with i) ()
          then begin
            let n = Bigint.of_field x in
            failwithf !"Shouldn't have passed: x=%s, i=%d"
              (String.init max_length ~f:(fun j -> if Bigint.test_bit n j then '1' else '0'))
              i ();
          end;
        done;
        assert (check (handle_with true_answer) ())
      in
      test (random_n_bit_field_elt max_length)*)
    ;;
  end)
end