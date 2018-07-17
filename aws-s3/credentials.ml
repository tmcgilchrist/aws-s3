open !StdLabels
let sprintf = Printf.sprintf
open Cohttp
open Protocol_conv_json

type time = float
let time_of_json t =
  Json.to_string t |> Time.parse_rcf1123_string

type t = {
  access_key: string [@key "AccessKeyId"];
  secret_key: string [@key "SecretAccessKey"];
  token: string option [@key "Token"];
  expiration: time option [@key "Expiration"];
} [@@deriving of_protocol ~driver:(module Json)]

let make ~access_key ~secret_key ?token ?expiration () =
  { access_key; secret_key; token; expiration }


module Make(Compat : Types.Compat) = struct
  open Compat
  open Deferred.Infix

  module Iam = struct
    let instance_data_host = "instance-data.ec2.internal"
    let get_role () =
      let inner () =
        let uri = Uri.make ~host:instance_data_host ~scheme:"http" ~path:"/latest/meta-data/iam/security-credentials/" () in
        Cohttp_deferred.call `GET uri >>= fun (response, body) ->
        match Cohttp.Response.status response with
        | #Code.success_status ->
          Cohttp_deferred.Body.to_string body >>= fun body ->
          Deferred.return (Ok body)
        | _ ->
          Cohttp_deferred.Body.to_string body >>= fun body ->
          failwith (sprintf "Failed to get role from %s. Response was: %s" (Uri.to_string uri) body)
      in
      Deferred.Or_error.catch inner

    let get_credentials role =
      let inner () =
        let path = sprintf "/latest/meta-data/iam/security-credentials/%s" role in
        let uri = Uri.make ~scheme:"http" ~host:instance_data_host ~path () in
        Cohttp_deferred.call `GET uri >>= fun (response, body) ->
        match Cohttp.Response.status response with
        | #Code.success_status -> begin
            Cohttp_deferred.Body.to_string body >>= fun body ->
            let json = Yojson.Safe.from_string body in
            of_json json |> Deferred.Or_error.return
          end
        | _ ->
          Cohttp_deferred.Body.to_string body >>= fun body ->
          failwith (sprintf "Failed to get credentials from %s. Response was: %s" (Uri.to_string uri) body)
      in
      Deferred.Or_error.catch inner
  end

  module Local = struct
    let get_credentials ?(profile="default") () =
      let home = Sys.getenv_opt "HOME" |> function Some v -> v | None -> "." in
      let creds_file = Printf.sprintf "%s/.aws/credentials" home in
      Deferred.Or_error.catch @@
      fun () ->
      let ini = new Inifiles.inifile creds_file in
      let access_key = ini#getval profile "aws_access_key_id" in
      let secret_key = ini#getval profile "aws_secret_access_key" in
      make ~access_key ~secret_key () |> Deferred.Or_error.return
  end

  module Helper = struct
    let get_credentials ?profile () =
      match profile with
      | Some profile -> Local.get_credentials ~profile ()
      | None -> begin
          Local.get_credentials ~profile:"default" () >>= function
          | Result.Ok c -> Deferred.Or_error.return c
          | Error _ ->
            Iam.get_role () >>=? fun role ->
            Iam.get_credentials role
        end
  end
end
