# a2a-ocaml

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![A2A](https://img.shields.io/badge/A2A-v1.0%20%7C%20v0.3-green.svg)](https://github.com/a2aproject/A2A/blob/v1.0.1/docs/specification.md)
![OCaml](https://img.shields.io/badge/OCaml-%E2%89%A5%205.1-orange.svg)

OCaml 5 向けの、型安全な [A2A (Agent2Agent) Protocol](https://github.com/a2aproject/A2A) **v1.0** クライアントです。[Eio](https://github.com/ocaml-multicore/eio) と [cohttp-eio](https://github.com/mirage/ocaml-cohttp) の上に構築しています。**v0.3** のエージェントとも後方互換で通信できます。バージョンは Agent Card から自動で選ばれ、利用側のコードは変わりません。

[English README](README.md)

```ocaml
match A2a_client.send_text client "この企業の最新の開示資料を要約してください" with
| Ok (Message m) -> print_endline (A2a_client.Message.text m)
| Ok (Task t) -> Printf.printf "task %s: %s\n" t.id (A2a_client.Task_state.to_string t.status.state)
| Error e -> prerr_endline (A2a_client.Error.to_string e)
```

## 特徴

- **JSON-RPC 2.0 による A2A v1.0 対応**：`SendMessage`、`SendStreamingMessage`、`GetTask`、`CancelTask`、`SubscribeToTask` を実装しています。
- **v0.3 との後方互換**：v0.3 のエージェントにも同じ操作（`message/send`、`message/stream`、`tasks/get`、`tasks/cancel`、`tasks/resubscribe`）を、同じ型と結果で行えます。
- **エージェントの発見**：`/.well-known/agent-card.json` から Agent Card（v1.0 と v0.3 のどちらの形式でも可）を取得し、JSON-RPC interface とプロトコルバージョン（`tenant` を含む）を選びます。
- **型付きデータモデル**：`AgentCard`、`Message`、`Part`、`Task`、`Artifact`、ストリーミングイベントを record で表します。`TaskState`、`Role`、`Part` の内容、エラーコードは variant です。
- **不正な入力で例外を投げない**：すべての操作が `result` を返します。不正な JSON、スキーマ違反、JSON-RPC の ID 不一致は、問題箇所の JSON パスを含む `Error` になります。
- **逐次処理の SSE ストリーミング**：TCP のチャンク境界に関係なく、イベントが届いた時点でコールバックを呼びます。status と artifact の更新は最終的な `Task` に畳み込みます。
- **Task のライフサイクル支援**：`Outcome` variant（`Completed`、`Failed`、`Input_required` など）、上限付きでバックオフするポーリング、`taskId` と `contextId` を引き継ぐ追加メッセージを用意しています。
- **Eio ネイティブ**：タイムアウトとキャンセルに対応し、`Switch` によって接続を必ず解放します。Lwt や Async は使いません。
- **差し替え可能な Transport**：HTTP 層は 1 つの関数型なので、既存の HTTP スタックやモックに置き換えられます。
- **機密情報をログに出さない**：`Logs` で出力するログに、ヘッダー、認証情報、本文は含まれません。

## インストール

公開 opam リポジトリにはまだ登録していません。GitHub から直接インストールでき、依存関係は opam が解決します。

```sh
opam pin add a2a-client https://github.com/TaisonTsukada/a2a-ocaml.git
```

特定のリリースを使う場合は、末尾にタグを付けます（例：`…/a2a-ocaml.git#v0.1.0`）。ローカルに clone したリポジトリからは、ルートで `opam install .` を実行します。

インストール後、`dune` ファイルに追加します。

```dune
(executable
 (name main)
 (libraries a2a-client eio_main))
```

**動作要件：** OCaml 5.1 以上、eio 1.0 以上、cohttp-eio 6.0 以上、yojson 3.0 以上。

## クイックスタート

```ocaml
let () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.mono_clock env in
  let transport = A2a_client.Transport.cohttp (Eio.Stdenv.net env) in
  match A2a_client.connect ~clock ~transport (Uri.of_string "http://localhost:9999") with
  | Error e -> prerr_endline (A2a_client.Error.to_string e)
  | Ok client -> (
      match A2a_client.send_text client "Hello" with
      | Ok (Message m) -> print_endline (A2a_client.Message.text m)
      | Ok (Task t) -> print_endline t.id
      | Error e -> prerr_endline (A2a_client.Error.to_string e))
```

`connect` は `<base>/.well-known/agent-card.json` から Agent Card を読み込み、プロトコルバージョンを選びます（[プロトコルバージョン](#プロトコルバージョン)を参照）。JSON-RPC のエンドポイントが分かっている場合は、代わりに `A2a_client.create ~clock ~transport endpoint` を使えます。

## 使い方

### メッセージの送信

よくある用途には `send_text` が使えます。`send_message` は任意の `Message.t` を送れます。

```ocaml
open A2a_client

let message =
  Message.user
    [ Part.text "この画像を説明してください";
      Part.url ~media_type:"image/png" "https://example.com/chart.png";
      Part.data (`Assoc [ ("locale", `String "ja-JP") ]) ]

let response =
  send_message client message
    ~configuration:(Send_message_configuration.make ~accepted_output_modes:[ "text/plain" ] ())
```

エージェントは `Message` か `Task` を返します。`Task` はまだ実行中の場合があります。

### Task のライフサイクル

`send_message_and_wait` はメッセージを送信したあと、Task が終端状態（completed、failed、canceled、rejected）か中断状態（input-required、auth-required）になるまで `GetTask` でポーリングします。

```ocaml
match send_message_and_wait client ~timeout:300. (Message.user_text "ACME 社について調査して") with
| Ok (Outcome.Message m) -> (* Task を作らず直接返答した *) ...
| Ok (Outcome.Completed task) -> List.iter (fun a -> print_endline (Artifact.text a)) task.artifacts
| Ok (Outcome.Failed task | Outcome.Rejected task | Outcome.Canceled task) -> ...
| Ok (Outcome.Input_required task) ->
    (* 同じ Task を継続する。taskId と contextId は引き継がれる *)
    send_message client (Task.follow_up_text task "東京本社の方です")
| Ok (Outcome.Auth_required task) -> ...
| Ok (Outcome.In_progress _) -> assert false (* send_message_and_wait は返さない *)
| Error (Error.Poll_timeout { last_task }) -> (* 300 秒たっても実行中 *) ...
| Error e -> ...
```

- `wait_for_task client ~timeout task_id` は、既存の Task をポーリングします。待ち時間は `interval`（既定 1 秒）から始まり、`backoff`（既定 1.5 倍）ずつ伸び、`max_interval`（既定 10 秒）で頭打ちになります。待機には `Eio.Time` を使うので、ドメインをブロックしません。
- `~timeout` は必須引数なので、ポーリングが無限に続くことはありません。
- `get_task` と `cancel_task` も直接呼べます。
- 状態の判定には `Task_state.is_terminal`、`is_interrupted`、`is_active` を使えます。

### ストリーミング

```ocaml
send_streaming_message client (Message.user_text "レポートを書いて")
  ~on_event:(function
    | Stream_response.Task t -> Printf.printf "task %s\n%!" t.id
    | Message m -> print_endline (Message.text m)
    | Status_update e -> Printf.printf "[%s]\n%!" (Task_state.to_string e.status.state)
    | Artifact_update e -> print_string (Artifact.text e.artifact))
(* : (Outcome.t, Error.t) result。すべての更新を畳み込んだ最終 Task を返す *)
```

- **受信：** ソケットからバイトが届くたびにイベントを解析し、1 件ずつ `on_event` に渡します。レスポンス全体をバッファすることはありません。
- **正常終了：** `Message` を受け取ったとき、または Task が終端状態になったときに終了します。input-required と auth-required の間は、仕様（§7.6.1）に従って読み続けます。この状態でサーバーがストリームを閉じた場合も正常終了として扱います。
- **途中での切断：** 上記以外のタイミングでストリームが閉じた場合は `Error (Stream_ended { last_task })` を返します。`subscribe_to_task` か `wait_for_task` で再開できます。
- **中断と後始末：** 途中で止めるには、呼び出し側のファイバーをキャンセルします（`Eio.Fiber.first`、`Eio.Time.with_timeout` など）。`on_event` が例外を投げた場合、その例外は呼び出し元に伝播します。どの場合も接続は閉じられます。
- **capability の確認：** `capabilities.streaming` を宣言していない Agent Card からクライアントを作った場合、リクエストを送らずに `Unsupported_capability` を返します。

### プロトコルバージョン

クライアントは A2A 1.0 と 0.3 を話せます。バージョンによって変わるのは通信形式だけで、リクエスト・結果・エラーは同じ OCaml の型を使います。上のコードはどちらのバージョンでもそのまま動きます。

`connect`（と `of_agent_card`）は、Agent Card の中からプロトコル 1.x の JSON-RPC interface を先頭から探して選びます。1.x がなければ、0.3.x の JSON-RPC interface を選びます。v0.3 形式の Agent Card（`url`、`preferredTransport`、`additionalInterfaces`、`protocolVersion`）も読み込めます。それ以外のバージョンは使わず、`No_compatible_interface` を返します。

```ocaml
let client = connect ~clock ~transport base |> Result.get_ok in
match A2a_client.version client with
| V1_0 -> print_endline "A2A 1.0 で通信中"
| V0_3 -> print_endline "A2A 0.3 で通信中"

(* 1.0 だけを許可する場合 *)
connect ~protocol_version:V1_0 ~clock ~transport base

(* Agent Card なしで、v0.3 のエンドポイントに直接つなぐ場合 *)
create ~protocol_version:V0_3 ~clock ~transport (Uri.of_string "https://agent.example.com/a2a")
```

プロトコル 0.3 では、次のように扱います。

- メソッド名は `message/send`、`message/stream`、`tasks/get`、`tasks/cancel`、`tasks/resubscribe` です。
- `return_immediately` は、その否定の `blocking` として送ります。
- 拡張機能は `A2A-Extensions` と `X-A2A-Extensions` の両方のヘッダーで送ります。
- `tenant` は送りません。0.3 にはこのフィールドがないためです。
- テキストパートとデータパートのメディアタイプは送りません。0.3 にはこれを表すフィールドがないためです。
- オブジェクトでないデータパートは、公式 SDK の慣例に従って `{"value": …}` で包み、metadata に `data_part_compat: true` を付けて送ります。受信時には元に戻します。

### 設定と認証

```ocaml
A2a_client.create ~clock ~transport
  ~auth:(Auth.bearer token)                   (* または Auth.header "X-API-Key" key、Auth.dynamic f *)
  ~headers:[ ("X-Request-Source", "my-service") ]
  ~extensions:[ "https://example.com/ext/v1" ]  (* A2A-Extensions ヘッダーとして送信 *)
  ~protocol_version:V1_0                      (* または V0_3。既定は V1_0 *)
  ~tenant:"acme"
  ~timeout:30.                                (* 単発呼び出しとストリームのヘッダー受信。既定 30 秒 *)
  ~stream_idle_timeout:120.                   (* ストリームの無通信許容時間。既定は無制限 *)
  ~max_response_size:(16 * 1024 * 1024)       (* 本文または SSE イベント 1 件あたり。既定 16 MiB *)
  endpoint
```

- `Auth.dynamic` はリクエストのたびに呼ばれるので、OAuth トークンの更新に使えます。
- すべてのリクエストで、クライアントのプロトコルバージョンを `A2A-Version` ヘッダー（`1.0` または `0.3`）として送信します。

### HTTPS

このライブラリは TLS 実装に依存しません。`Transport.cohttp` に TLS ラッパーを渡してください。型は `Cohttp_eio.Client.make` が受け取るものと同じです。[tls-eio](https://github.com/mirleft/ocaml-tls) と [ca-certs](https://github.com/mirage/ca-certs) を使う例です。

```ocaml
let () = Mirage_crypto_rng_unix.use_default ()  (* TLS には初期化済みの乱数生成器が必要 *)

let https =
  let authenticator = Ca_certs.authenticator () |> Result.get_ok in
  let config = Tls.Config.client ~authenticator () |> Result.get_ok in
  fun uri raw ->
    let host = Uri.host uri |> Option.map (fun h -> Domain_name.(host_exn (of_string_exn h))) in
    Tls_eio.client_of_flow ?host config raw

let transport = A2a_client.Transport.cohttp ~https (Eio.Stdenv.net env)
```

ラッパーを渡さずに `https://` の URL を使うと、`Transport_error` を返します。このエラーメッセージに URL は含まれません。

### 既存サービスへの組み込み

- `Transport.t` と `A2a_client.t` は不変値です。起動時に 1 度作成し、リクエストハンドラ間で共有できます。
- 各呼び出しは、専用の `Switch` の中で接続を開きます。ハンドラのファイバーがキャンセルされると（クライアントの切断など）、A2A の呼び出しもキャンセルされ、接続は解放されます。
- 既存の HTTP スタックを使う場合は、`Transport.t` を実装します。

  ```ocaml
  type t = sw:Eio.Switch.t -> Transport.request -> Transport.response
  ```

  開いた接続は `sw` に結び付けてください。同じ仕組みでテスト用のモックも簡単に作れます（`test/mock.ml` を参照）。

### ログ

ログは `Logs` のソース `A2a_client.src`（名前は `"a2a-client"`）に出力します。内容はメソッド名、リクエスト ID、userinfo と query を除いた URL、エラーだけです。ヘッダー、認証情報、本文は出力しません。

## エラー

すべての操作は `(_, A2a_client.Error.t) result` を返します。外に伝播する例外は Eio のキャンセルだけです。

| コンストラクタ | 意味 |
| --- | --- |
| `Rpc_error { code; message; details }` | エージェントが JSON-RPC エラーを返した。`code` は `Task_not_found`、`Task_not_cancelable`、`Version_not_supported` などの variant、または JSON-RPC の標準コード。`Error.error_info` で `google.rpc.ErrorInfo` を取り出せる |
| `Http_error { status; body }` | 2xx 以外の HTTP ステータス。`body` は先頭 1 KiB までの抜粋 |
| `Transport_error msg` | 接続、DNS、リセット、TLS の失敗 |
| `Timeout what` | `timeout` または `stream_idle_timeout` を超えた |
| `Invalid_response msg` | 不正な JSON、JSON-RPC エンベロープの違反、スキーマ違反（例：`at $.result.task.status.state: unknown TaskState "done"`）、サイズ超過 |
| `Stream_ended { last_task }` | Task が確定する前にストリームが閉じた |
| `Poll_timeout { last_task }` | ポーリングがタイムアウトした |
| `No_compatible_interface`、`Unsupported_capability` | Agent Card をもとにローカルで判定したエラー。`No_compatible_interface` は、プロトコル 1.x と 0.3.x のどちらの JSON-RPC interface もないことを表します |

## プロトコルの互換性

| | |
| --- | --- |
| プロトコル | A2A **1.0**：[仕様 v1.0.1](https://github.com/a2aproject/A2A/blob/v1.0.1/docs/specification.md)、[`a2a.proto`](https://github.com/a2aproject/A2A/blob/v1.0.1/specification/a2a.proto)（`lf.a2a.v1`） |
| 後方互換 | A2A **0.3**：[仕様 v0.3.0](https://github.com/a2aproject/A2A/blob/v0.3.0/docs/specification.md)、[JSON スキーマ](https://github.com/a2aproject/A2A/blob/v0.3.0/specification/json/a2a.json) |
| バインディング | JSON-RPC 2.0 over HTTP。ストリーミングは Server-Sent Events |
| ワイヤー形式 | 1.0：ProtoJSON（camelCase のフィールド名、`TASK_STATE_*` / `ROLE_*` の enum 名、oneof はメンバー名で判別）。0.3：`kind` で種類を示すオブジェクトと、小文字の enum（`working`、`input-required`、`user`） |
| 旧バージョン | v0.2 以前には対応していません。それしか提供しないエージェントには `No_compatible_interface` を返し、実装していないバージョンに黙ってフォールバックすることはありません（仕様 §3.6.3） |

以下の点は公式 SDK の挙動に合わせています。

- **デコード：** ProtoJSON と同様に、未知のフィールドは無視し、欠けたスカラー値は既定値として扱います。クライアントの動作に必要なフィールドは検証します。対象は、Task の `id` と `status.state`、イベントの `taskId`、`Part` の内容がちょうど 1 種類であること、`SendMessageResponse` と `StreamResponse` のペイロードがちょうど 1 つであることです。
- **enum：** 1.0 では名前と数値の両方を受け付けます。0.3 の状態 `unknown` は `Unspecified` として扱います。
- **0.3 での寛容な扱い：** `kind` がない場合はフィールドから種類を推定します。タイムゾーンのないタイムスタンプは UTC として読み、解釈できないタイムスタンプはイベント全体を失敗させずに捨てます。status 更新の `final` は使いません。1.0 と同じく、ストリームの終わりは Task の状態で判断します。複数のフローを持つ v0.3 の `OAuthFlows` は、authorization code、client credentials、implicit、password の順で最初のものだけを残します。
- **SSE のイベント型：** `message` と `error` 以外の型のイベントは無視します。`event: error` のデータは JSON-RPC エラーとして解釈します。
- **SSE 以外の応答：** ストリーミング要求に `application/json` が返ってきた場合は、単一の JSON-RPC 応答として扱います。通常はストリーム開始前に発生したエラーです。

## モジュール構成

| モジュール | 役割 |
| --- | --- |
| `A2a_client` | クライアントの操作、エージェントの発見、ポーリング。データモデルも再エクスポート |
| `Types` | プロトコルのデータモデル |
| `Codec` | 1.0 のワイヤー形式の JSON 変換。Agent Card はどちらの形式も読めます |
| `Codec_v0_3` | 0.3 のワイヤー形式の JSON 変換 |
| `Protocol_version` | `V1_0` / `V0_3` |
| `Transport` | HTTP の抽象化と cohttp-eio による実装 |
| `Lifecycle` | `Outcome` による状態の分類と、ストリームイベントの Task への畳み込み |
| `Error` | エラー型と A2A のエラーコード |

API リファレンスは `.mli` ファイルから `dune build @doc` で生成できます。

## 使用例

[`examples/a2a_cli.ml`](examples/a2a_cli.ml) は小さなコマンドラインクライアントです。

```sh
dune exec examples/a2a_cli.exe -- http://localhost:9999 send   "Hello"
dune exec examples/a2a_cli.exe -- http://localhost:9999 wait   "この企業を調査して"
dune exec examples/a2a_cli.exe -- http://localhost:9999 stream "レポートを書いて"
dune exec examples/a2a_cli.exe -- http://localhost:9999 get    TASK_ID
A2A_TOKEN=... dune exec examples/a2a_cli.exe -- http://localhost:9999 cancel TASK_ID
```

## 制限事項

次の機能にはまだ対応していません。

- HTTP+JSON（REST）と gRPC のバインディング
- Push Notification の設定（`SendMessageConfiguration` の `taskPushNotificationConfig` を含む）
- `ListTasks` と `GetExtendedAgentCard`
- Agent Card の署名（JWS）の検証。`signatures` の解析は行いますが、検証はしません
- Agent Card の HTTP キャッシュ
- コネクションプールと keep-alive
- `Last-Event-ID` を使った SSE の自動再接続。代わりに `subscribe_to_task` を使ってください
- A2A v0.2 以前。v0.3 のプッシュ通知関連メソッドと `agent/getAuthenticatedExtendedCard`
- サーバー側のコンポーネント（Agent Executor、Task Store）。このライブラリはクライアント専用です

## ライセンス

[MIT](LICENSE)
