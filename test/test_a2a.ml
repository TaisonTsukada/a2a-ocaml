let () =
  Alcotest.run "a2a-client"
    [ ("codec", Test_codec.tests); ("jsonrpc", Test_jsonrpc.tests); ("sse", Test_sse.tests);
      ("client", Test_client.tests); ("http", Test_http.tests) ]
