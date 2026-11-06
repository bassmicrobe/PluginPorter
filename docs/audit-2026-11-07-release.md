# 2026-11-07 CLI・配布物監査

> この文書は監査実施時点の記録です。以降の署名・公証・公開状況はREADMEとGitHub Releasesを参照してください。

## 対象と環境

- ソース基準: `4083c52d10fb0b02162f0ec5574533952d061ce1`。開始時の作業ツリーはクリーン。
- 公開配布物: [v1.2.0 / PluginPorter 1.2 build 4](https://github.com/bassmicrobe/PluginPorter/releases/tag/v1.2.0)。Developer IDによるZIP直接配布。Mac App Store向けではない。
- 今回のソース修正候補: PluginPorter 1.2 build 5。ローカルビルドのアドホック署名は実行したが、新規Developer ID署名・公証提出・公開・インストールは行っていない。
- 環境: Apple M5 / arm64 / 32 GiB、macOS 27.2 (26B123)、Xcode 27.2 (27B52)、Swift 6.4.2、SDK 27.2。製品のコンパイル指定はSwift言語モード5、`-O`、`arm64-apple-macos12.0`。
- 対象: `Sources/main.swift`、`build.command`、`pluginporter`、`scripts/notarize-release.sh`、`docs/NOTARIZATION.md`、公開ZIP内の実アプリ。Intel・Universal対応は仕様外。

## 確認できた不具合と修正

### CLI-01: JSON出力による元データの上書き（高）

READMEは移行元・購入パックを変更せず、既存のコピー先を上書きしない仕様を示している。しかし、コピー本体の検証を通過した後、CLIの`--report`は指定先を無条件でJSONに置き換えていた。`preset-install PLAN --report 元のLead.h2p`や`restore ARCHIVE --home HOME --report ARCHIVE/manifest.json`で、元ファイルや復元に必要なmanifestを破壊できた。`preset-plan PACK --output PACK/Lead.h2p`にも同じ問題があった。ローカルCLIで誤った出力先を指定した場合のデータ消失であり、遠隔からの任意コード実行という判定ではない。

`validateJSONOutput`を追加し、元パック（認識項目のない入力を含む）、元ファイル、入力プラン、アーカイブ、コピー先と重なるJSON保存先をコピー開始前に拒否する。復元ではmanifestに記録された元sourcePathも保護する。保存先がコピー対象の祖先の場合も、コピーが成功した後でreportを保存できなくなるため拒否する。シンボリックリンク・既存パスの大文字小文字を解決して照合し、存在しない親やフォルダ自体への出力も先に拒否する。scanでは検索前の全検出項目を保護する。

テストで拒否時の終了コード1に加えて、元ファイル・manifest・入力planが不変で、コピー先が未作成であることを確認した。scanのフィルタ除外項目保護はテスト用Inventoryで確認し、実プラグインは読み取っていない。敵対的な別プロセスによる検証直後のパス差し替えは未検証。

公開build 4の追加再現では、リポジトリの`.build/`内の専用fixtureで、preset-installのreport指定による元プリセットのJSON置換、preset-planによる元プリセットのJSON置換、restoreのreport指定によるmanifestのJSON置換を、それぞれ終了コード0・変更前後のバイト列差・置換後のJSONキーで確認した。利用中の購入パック・アーカイブは使用していない。

### CLI-02: 対応しない`--dry-run`を無視して実コピーする（中）

build 4は全コマンド共通のオプション解析のため、`export ... --dry-run`と`preset-install ... --dry-run`を受理したうえで通常のコピーを実行した。dry-runはrestore専用であり、未対応の指定を受け入れると、利用者が確認のみと考えた操作で書き込みが発生する。

コマンド別の許可オプションを検査し、未対応・重複・値不足・空値を副作用の前に拒否する。restoreの`--dry-run --report`も、レポートを生成したように誤認されないよう拒否する。正常なrestore dry-runは保存先表示だけを行い、ファイルを作成しないことを確認した。

## 実施した防御的補強（確認済み不具合とは区別）

exportの`--plan`は、manifestやプリセットプランと違って、ファイルの種類とサイズを確認せず`Data(contentsOf:)`へ渡していた。読み込むJSONの範囲をmanifestと揃え、通常ファイルかつ32 MiB未満に制限した。シンボリックリンク・FIFO・32 MiB超の疎ファイルを拒否し、コピー先が作成されないことを回帰テストで確認した。build 4でシンボリックリンクのplanが受理されることは確認したが、これ自体を仕様違反や攻撃成立とは判定しない。FIFOはbuild 4でも約0.014秒でexit 1となり、待ち続ける現象は再現しなかった。巨大入力によるメモリー枯渇も再現していないため、障害を実証した指摘には数えない。

## 自動検証

`./Tests/run-cli-tests.sh`はCLIをテスト用GUI・Inventoryに接続してコンパイルし、専用一時ディレクトリ内だけで実行する。アプリの認証や署名チェックを差し替えるものではない。

- 初回9グループを公開build 4に実行: **2成功 / 7失敗**。元データ上書き・未対応dry-runの受理を修正前に再現。
- JSON保護・オプション修正後: **12/12成功**。
- 追加したプラン境界・検索除外項目の保護テスト: 修正前 **12/14成功**、修正後 **14/14成功、skipなし**。
- 最終レビューで、manifestの元sourcePathと未作成コピー先の祖先をreportに指定するケースを追加: 修正前の実build 5で **12/14成功、1 skip**、追修正後のCLIテストは **15/15成功、skipなし**。
- 正常系: export → verify → restore dry-run → restore → 衝突時スキップ、プリセット解析、インストール、再実行、元データ維持、日本語・絵文字・空白入りパスを含む。
- 不正系: `--report`による元データ・manifest・入力plan・コピー先の上書き、入力パックへのJSON出力、親リンク経由の出力、認識項目のないパック、大文字小文字の別表記、親不存在・フォルダ出力、未対応・重複・値不足のオプション、非通常・上限超のプラン。
- `zsh -n build.command pluginporter`、`bash -n scripts/notarize-release.sh Tests/run-cli-tests.sh`、`git diff --check`: 成功。

実ReleaseのCLIへ同じ回帰テストを適用するには、次を使用する。実環境のプラグイン一覧をテストで読まないため、Inventoryを差し替える1グループだけを明示的にskipする。

```sh
PLUGIN_PORTER_CLI="$PWD/dist/PluginPorter.app/Contents/MacOS/PluginPorter" ./Tests/run-cli-tests.sh
```

## 修正後の最終ローカルbuild 5

上記コマンドを最終`dist/PluginPorter.app`へ実行し、**14/14成功、Inventory差し替え用の1グループのみskip**を確認した。この1グループは通常CLIテストで成功済み。最終実行ファイルのSHA-256は`6af329df237e46d60542d6e2c4b3e56c6c4fbcaa36ffccb21ffcf1f9a4e33b97`。

最終アプリはversion 1.2 / build 5 / minimum macOS 12.0 / arm64。リンクする25個の依存はOS標準パスのみ。`codesign --verify --deep --strict --verbose=2`は成功し、署名は`adhoc`でTeamIdentifierは未設定。`spctl --assess --type execute --verbose=2`は**exit 3 / rejected**。これは通常のローカルビルド設定と一致し、Developer IDによる公開配布条件を満たした成果物ではない。公開build 4の署名・公証検証の成功を、この修正後アプリへ転用していない。

専用fixtureで、**build 4 → build 5、build 5 → build 4**の双方について、アーカイブの作成→他版によるverify→restore→再実行時skip、およびプリセットplan作成→他版によるinstall→再実行時skipを確認した。元ファイルとコピー先のバイト列一致・元データ不変も確認済み。アーカイブ・planとも既存のformatVersion 1を維持している。これは形式の相互互換を確認したもので、OSのインストーラ更新・実ライブラリ・実シンセの互換性を確認したものではない。

## 公開build 4の実物検証

READMEの[ZIP](https://github.com/bassmicrobe/PluginPorter/releases/download/v1.2.0/PluginPorter-1.2-build4-arm64-notarized.zip)と[チェックサム](https://github.com/bassmicrobe/PluginPorter/releases/download/v1.2.0/PluginPorter-1.2-build4-arm64-notarized.zip.sha256)を専用一時ディレクトリへ取得して`ditto -x -k`で展開した。公開済みのアプリに対する検証であり、今回の修正済みbuild 5の配布可否は示さない。

| 検証 | 結果 |
|---|---|
| ZIP SHA-256 | 公開値と一致: `5d2acd5979258f373d3037771ba5e79e00821d57c051ac20997dc01c11f17c33` |
| `codesign --verify --deep --strict --verbose=2 APP` | exit 0、valid on disk / Designated Requirement成立 |
| `codesign -d --verbose=4 APP` | Developer ID Application、Hardened Runtime、署名タイムスタンプ、公証ticket添付を確認 |
| `codesign -d --entitlements - APP` | entitlementsなし。Sandbox・デバッグ・JITなどの例外付与なし |
| `xcrun stapler validate APP` | exit 0、添付ticket検証成功 |
| `spctl --assess --type execute --verbose=2 APP` | exit 0、accepted / source=Notarized Developer ID |
| `syspolicy_check distribution APP` | exit 0、配布前検査通過 |
| `xcrun lipo -archs EXECUTABLE` | arm64のみ |
| `otool -l EXECUTABLE` | Mach-O最低OS 12.0、SDK 27.2、RPATHは`/usr/lib/swift` |
| `otool -L EXECUTABLE` | Apple標準Framework・OS/Swiftランタイムのみ。外部同梱ライブラリなし |
| `plutil -p APP/Contents/Info.plist` | version 1.2 / build 4 / minimum 12.0 / Bundle ID `local.pluginporter.app` |
| `EXECUTABLE --cli --help` | exit 0、ヘルプ表示 |

今回のHTTPS取得方法では`com.apple.quarantine`は付いていない。属性を削除した結果ではない。従って、隔離属性付きのFinder初回起動、App Translocation、初回許可ダイアログ、オフライン起動は未確認。spctlの成功をこれらの実操作の成功と置き換えない。notarytoolによる過去申請照会も行っておらず、公証の確認根拠は実配布物の添付ticket・Gatekeeper判定である。

## 配布手順の確認と残件

署名スクリプトはクリーンなGit状態から独立したrunディレクトリへビルドし、Developer ID署名のTeam・証明書・runtime・timestampを確認し、Apple Accepted後に同じアプリへticketを添付する。最終ZIPを再展開して署名・ticket・Gatekeeper・CLI起動を確認する構成。ソースからは既存アプリの自動更新・自動インストール・公開処理は見つからない。公開版と修正版を区別するためローカル候補のbuild番号を5へ更新した。

直接配布ではApp Sandboxは任意で、公証対象ではHardened Runtimeが必要である。今回の公開ZIPはこの観点で確認した範囲では指摘なし。これはApp Store審査・全OS対応・機能全般の安全性を保証するものではない。[Apple: Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)

公証はApp Reviewではなく、署名問題や悪意あるコンポーネントの検査である。アプリ内のデータ保護バグがない証明としては扱わない。[Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Appleは実際の配布容器からの起動、可能なら別Mac、初回・移動後の起動を確認する手順を示している。build 5は最終コード確定後、明示的な配布許可のある時点でDeveloper ID署名・公証・最終ZIP・隔離属性付き起動を再検証する必要がある。[Apple: Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

改善提案として、ReleaseごとにdSYMとMach-O UUIDを保存し、コミット・ZIPハッシュと対応付ける。現行`build.command`は`-g`/dSYM生成を指定しておらず、今回のZIPにもシンボル資料は含まれない。ソース外に保管した既存dSYMの有無は不明であり、クラッシュ解析不能と断定しない。OS 12の実機・別Mac・外付け/ネットワーク保存先・管理者認証・実DAW/シンセはこのCLI/配布検証の対象外で、包括監査側の記録と合わせて扱う。
