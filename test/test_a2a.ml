let () =
  Alcotest.run "a2a-client"
    [ ("codec", Test_codec.tests); ("jsonrpc", Test_jsonrpc.tests); ("sse", Test_sse.tests);
      ("client", Test_client.tests); ("operations", Test_operations.tests); ("rest", Test_rest.tests);
      ("reconnect", Test_reconnect.tests); ("pool", Test_pool.tests);
      ("http", Test_http.tests); ("v0.3", Test_v0_3.tests) ]
