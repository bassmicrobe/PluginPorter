# Developer ID署名とApple公証

`scripts/notarize-release.sh` は、コミット済みのソースからApple Silicon用アプリをビルドし、Developer ID署名、公証、チケット添付、最終ZIPの展開検証まで実行します。GitHubへの公開や、このMacへのインストールは行いません。

対象は既存の `local.pluginporter.app`、arm64、macOS 12以降です。バージョンとビルド番号は `build.command` のInfo.plist定義を使用します。Universal化やBundle IDの変更は行いません。

## 実行前の確認

Apple Silicon Mac、Xcode Command Line ToolsまたはXcode、公証に使用できる既存のDeveloper ID Application証明書と秘密鍵、公証用キーチェーンプロファイルが必要です。証明書とプロファイルが、このアプリに使用するApple Developerチームのものか確認してください。

通常のビルドと既存テストを先に実行します。

```sh
./build.command
./Tests/run-engine-tests.sh
./Tests/run-preset-tests.sh
./Tests/run-cli-tests.sh
./pluginporter --help
```

ソースとスクリプトをコミットして作業ツリーをクリーンにしてから公証します。`dist/` はGit管理対象外です。スクリプトは未コミット変更や未追跡ファイルがあると停止し、ビルド中にコミットや作業ツリーが変わった場合もApple送信前に停止します。

```sh
SIGNING_IDENTITY="<Developer ID Application証明書の40桁SHA-1>" \
TEAM_ID="<10桁のTeam ID>" \
NOTARY_PROFILE="<既存のnotarytoolプロファイル名>" \
SIGNING_KEYCHAIN="/absolute/path/to/signing.keychain-db" \
./scripts/notarize-release.sh
```

既定のキーチェーン検索リストに署名identityがある場合は `SIGNING_KEYCHAIN` を省略できます。この変数は署名鍵の検索先だけを指定します。公証認証は `NOTARY_PROFILE` の既存設定を使用します。必要ならコマンド単位で `DEVELOPER_DIR` を指定してください。

パスワード、トークン、秘密鍵データをスクリプト、Git、作業ログへ書かないでください。新しい証明書や認証情報の作成・変更は、このスクリプトでは行いません。

## 作成される成果物と証跡

毎回 `dist/notarization/run-日時.ランダム値/` に新しいアプリをビルドします。開発用の `dist/PluginPorter.app` は作業場所に使用しません。現在のアプリは単一のMach-O実行ファイルで、Hardened Runtimeとタイムスタンプを付けて署名します。予期しない埋め込みMach-Oが増えた場合は自動で停止するため、内側からの署名順序や必要なentitlementsを別途検討してください。

署名のTeam ID、Developer ID Application、runtime、Timestamp、埋め込み証明書のSHA-1を確認してから送信します。申請と待機は別コマンドにして、待機前に申請IDを保存します。Appleの状態が `Accepted` の場合だけ、同じアプリにチケットを添付します。

- `build-context.txt`: ソースコミット、tree SHA、ビルド日時、OS・Swift・Xcode選択先。
- `submission.json` / `submission-id.txt`: Appleへの申請と申請ID。
- `status.json` / `notary-log.json`: Appleの結果と詳細ログ。
- `signature.txt` / `gatekeeper.txt`: 署名・Gatekeeperの確認結果。
- `PluginPorter-<version>-build<build>-arm64-notarized.zip` と `.sha256`: チケット添付後の配布用アプリとSHA-256。
- `extracted/` と `extracted-*`: 最終ZIPの展開先、展開後の署名・チケット・Gatekeeper・CLIヘルプの確認結果。
- `release-summary.txt`: 配布物のバージョン、ビルド番号、ソースコミット、申請ID、最終ZIPのSHA-256。

配布用ZIPには `PluginPorter.app` が入ります。CLIはアプリ内の `Contents/MacOS/PluginPorter --cli --help` でも実行でき、展開後にこの経路を確認します。アプリを起動して実プラグインを移行する検証は、署名・公証の検証とは別です。

## 失敗・タイムアウト時

作業ディレクトリとAppleの申請情報を保持して停止します。タイムアウトしてもApple側の処理は継続するため、スクリプトをすぐ再実行して重複申請しないでください。保存した同じ申請IDの状態を確認します。

```sh
xcrun notarytool info "<submission-id>" --keychain-profile "<profile>"
xcrun notarytool wait "<submission-id>" --keychain-profile "<profile>" --timeout 30m
xcrun notarytool log "<submission-id>" --keychain-profile "<profile>" "notary-log.json"
```

`Accepted` を確認した場合は、保持された同じ申請用アプリに対してチケット添付以降を続行します。アプリを再ビルドしたり変更した場合は、新しい署名と申請が必要です。最終ZIPと申請用 `submission.zip` のSHA-256は異なるため、配布時は最終ZIP側のチェックサムを使用してください。
