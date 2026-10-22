type 'res request = {
  meth : Transport.meth;
  path : string;
  query : (string * string) list;
  body : string option;
  content_type : string;
  accept : string;
  id : string option;
  decode : string -> ('res, Error.t) result;
  error_of_body : (string -> Error.t option) option;
}

type ('req, 'res) t = { name : string; prepare : 'req -> 'res request }
