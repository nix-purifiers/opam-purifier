let () =
  let text = Alpha.get () in
  let chars = Uutf.String.fold_utf_8 (fun n _ _ -> n + 1) 0 text in
  Printf.printf "%s (%d characters)\n" text chars
