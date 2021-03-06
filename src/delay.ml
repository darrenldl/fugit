module C = CalendarLib.Calendar.Precise

type duration = C.Period.t

type t = {
  start : C.t ;
  stop : C.t ;
}

let of_duration p =
  let start = C.now () in
  let stop = C.add start p in
  { start ; stop }

let duration p = C.sub p.stop p.start

let calendar_pp_with fmt ppf d =
  let open CalendarLib in
  let d = C.convert d UTC Local in
  Printer.Precise_Calendar.fprint fmt ppf d

let calendar_parse_with fmt s =
  let open CalendarLib in
  C.convert
    (Printer.Precise_Calendar.from_fstring fmt s)
    Local UTC

module Raw = struct
  open Cmdliner

  let format = "%FT%T%:z"
  let printer = calendar_pp_with format
  let parser s =
    try Ok (calendar_parse_with format s) with
      Invalid_argument s -> Error (`Msg s)

  let rfc3339 =
    let docv = "TIME" in
    let parser s =
      try Ok (calendar_parse_with format s) with
        Invalid_argument s -> Error (`Msg s)
    in
    Arg.conv ~docv (parser, printer)

  let arg =
    let i =
      Arg.info ~docs:"DELAY" ~docv:"START/STOP"
        ~doc:"Provide the start and end time as pair of rfc3339 dates separated by /."
        ["raw-delay"]
    in
    Arg.(value & opt (some & pair ~sep:'/' rfc3339 rfc3339) None i)

  let term =
    let f (start, stop) = { start ; stop } in
    Cmdliner.Term.(pure (CCOpt.map f) $ arg)

  let pp ppf { start ; stop } =
    Fmt.pf ppf "%a/%a" printer start printer stop
end


(** Printing *)
type precision =
  | Hour
  | Day
  | Yesterday
  | Week
  | Month
  | Year
  | Unknown

let decide_precision start stop =
  let c = C.convert start UTC Local in
  let c_now = C.convert stop UTC Local in
  let date = C.to_date c and date_now = C.to_date c_now in
  if C.Date.equal date date_now then
    begin if C.hour c = C.hour c_now then
        Hour
      else
        Day
    end
  else if C.(day_of_year c_now - day_of_year c) = 1 then Yesterday
  else if C.(week c_now = week c) then Week
  else if C.(month c_now = month c) then Month
  else if C.(year c_now = year c) then Year
  else
    Unknown

let format_start = function
  | Hour -> "at <b>%T</b>"
  | Day -> "at <b>%T</b>"
  | Yesterday
    -> "<b>yesterday at <b>%R</b>"
  | Week
    -> "<b>%A</b> at <b>%R</b>"
  | Month
    -> "the <b>%dth</b> at <b>%R</b>"
  | Year
    -> "the <b>%dth</b> <b>%B</b> at <b>%R</b>"
  | Unknown
    -> "the <b>%dth</b> <b>%B</b> <b>%Y</b> at <b>%R</b>"

let format_now = function
  | Hour
  | Day
    -> "<b>%T</b>"
  | Yesterday
  | Week
    -> "<b>%A</b> at <b>%R</b>"
  | Month
    -> "<b>%A</b> <b>%dth</b> at <b>%R</b>"
  | Year
    -> "<b>%A</b> <b>%dth</b> <b>%B</b> at <b>%R</b>"
  | Unknown
    -> "<b>%A</b> <b>%dth</b> <b>%B</b> <b>%Y</b> at <b>%R</b>"

let pp_duration ppf p =
  let years, months, days, seconds = C.Period.ymds p in
  let hours, minutes, seconds =
    let m = seconds / 60 in
    let h = m / 60 in
    h, m - 60*h, seconds - m*60
  in
  let condfmt ppf (i,fmt,fmts) =
    if i > 1 then Fmt.pf ppf fmts i
    else if i = 1 then Fmt.pf ppf fmt
    else assert false
  in
  let pp_list ppf l =
    let l = CCList.filter (fun (i,_,_) -> i <> 0) l in
    match List.rev l with
    | [] -> ()
    | [b] -> Fmt.pf ppf "%a" condfmt b
    | b :: l ->
      Fmt.pf ppf "%a and %a"
        Fmt.(list ~sep:comma condfmt) (List.rev l)
        condfmt b
  in
  Fmt.(pf ppf "@[%a@]" pp_list)
    [ years, "1 year", "%i years";
      months, "1 month", "%i months";
      days, "1 day", "%i days";
      hours, "1 hour", "%i hours";
      minutes, "1 minute", "%i minutes";
      seconds, "1 second", "%i seconds";
    ]

let pp_short ppf d =
  pp_duration ppf @@ duration d

let pp_explain ppf d =
  let c_now = C.now () in
  let precision = decide_precision d.start c_now in
  let duration = duration d in
  Fmt.pf ppf "It is %a.\n"
    (calendar_pp_with @@ format_now precision)
    c_now ;
  if precision = Hour then
    Fmt.pf ppf "Alert started %a ago."
      pp_duration duration
  else
    Fmt.pf ppf "Alert started %a.\n%a ago."
      (calendar_pp_with @@ format_start precision) d.start
      pp_duration duration

(** Parsing *)


module Iso8601 = struct
  open Angstrom

  let char_ci i =
    let x = CCChar.lowercase_ascii i and y = CCChar.uppercase_ascii i in
    satisfy (fun c -> c = x || c = y)

  let digit =
    let f i =
      match int_of_string i with
      | v -> return v
      | exception _ -> fail @@ Fmt.strf "Not a valid integer: %s" i
    in
    let b = function '0'..'9' -> true | _ -> false in
    (take_while1 b >>= f) <?> "Integer"

  let duration =
    let elem c =
      option None (digit <* char_ci c >>| fun x -> Some x)
    in
    let date =
      let f year month day (hour, minute, second) =
        C.Period.lmake ?year ?month ?day ?hour ?minute ?second () in
      lift3 f (elem 'Y') (elem 'M') (elem 'D')
    in
    let time =
      lift3 (fun a b c -> a,b,c) (elem 'H') (elem 'M') (elem 'S')
    in
    char_ci 'P' *>
    date <*>
    option (None,None,None) (char_ci 'T' *> time)

  let parse = parse_string ~consume:Consume.All (duration <* end_of_input)
  
end

let duration_of_daypack_duration (x : Daypack_lib.Duration.t) : duration =
  C.Period.lmake ~day:x.days ~hour:x.hours ~minute:x.minutes ~second:x.seconds ()

let get_current_tz_offset_s () =
  Ptime_clock.current_tz_offset_s () |> Option.get

let search_param =
  Daypack_lib.Search_param.make_using_years_ahead
    ~search_using_tz_offset_s:(get_current_tz_offset_s ()) 5
  |> Result.get_ok

let parse_duration l =
  let s = String.concat " " l in
  Daypack_lib.Duration.of_string s
  |> Result.map duration_of_daypack_duration

let parse_time_point l =
  let open Daypack_lib in
  let s = String.concat " " l in
  match Time_expr.of_string ~enabled_fragments:[`Time_point_expr] s with
  | Ok x ->
    begin match
        Time_expr.next_match_time_slot search_param x
      with
      | Error msg -> Error msg
      | Ok None -> Error "Failed to find a matching time point"
      | Ok Some (time_slot_start, _time_slot_end) ->
        let cur = Time.Current.cur_unix_second () in
        let diff = if time_slot_start >= cur then Int64.sub time_slot_start cur else 0L in
        Duration.of_seconds diff
        |> Result.get_ok
        |> duration_of_daypack_duration
        |> Result.ok
    end
  | Error s -> Error s

let parse_deadline l =
  match l with
  | [] -> Error "Empty expression"
  | "in" :: xs -> parse_duration xs
  | "at" :: xs -> parse_time_point xs
  | l -> 
     begin match parse_duration l with
       | Ok x -> Ok x
       | Error _ ->
         parse_time_point l
     end

let parse l =
  CCResult.map of_duration @@ parse_deadline l
