# PluginPorter 1.2

Apple Silicon Macから別のApple Silicon Macへ、AU / VST / VST3プラグインをコピーして移すアプリです。AAXも検出します。v1.2では、購入したパックのフォルダをドラッグして、シンセ別にプリセットと付属素材をまとめて保存できます。移行元や購入パックのファイルは移動・削除・書き換えません。

対応: Apple Silicon、macOS 12以降。Pythonや追加ランタイムは不要です。初回の実機検証環境はmacOS 14.8.9です。プラグイン自体の移行先OS・CPU対応は別途必要です。

## リポジトリからビルドする

Apple Silicon MacとXcode Command Line Toolsを使用します。

```sh
git clone https://github.com/bassmicrobe/PluginPorter.git
cd PluginPorter
./build.command
open dist/PluginPorter.app
```

`Sources/` にアプリとCLIのSwiftソース、`Tests/` に検証用コードがあります。ビルド後はリポジトリ直下から `./pluginporter --help` でCLIを実行できます。ビルド生成物と、このMac固有のプラグイン一覧CSVはGitで管理しません。

既存テストは一時的なテスト用ファイルだけで実行できます。

```sh
./Tests/run-engine-tests.sh
./Tests/run-preset-tests.sh
```

## アプリで使う

1. `PluginPorter.app` を起動します。自動でこのMacのプラグインを一覧化します。
2. 移行する項目にチェックを入れます。コピー可能なプラグイン本体は初期選択され、関連データ候補は未選択です。検索してから「表示中を選択」も使えます。検索欄に `Intel専用` と入力するとIntel専用のプラグインに絞れます。「要再導入」の項目は選択対象から外れ、理由を確認できます。
3. 必要なプリセット・音源を追加選択します。「音源フォルダを追加」で外付けSSDなどのフォルダも指定できます。項目をクリックすると注意点やCPU対応が表示されます。
4. DAWとメーカーのアップデーターを終了し、「バックアップを作成…」で保存先を指定します。新しい `.pluginporter` フォルダを作成します。プラグイン本体と選択データの容量分の空きが必要です。
5. **アプリと `.pluginporter` フォルダ全体**を移行先Macへ渡します。Mac間の受け渡しには、メタデータやリンクを保持できるAPFS形式の外付けSSDを推奨します。
6. 移行先でアプリを起動し、「アーカイブを開く」でフォルダを選択します。保存場所の列が移行先のパスに切り替わります。
7. 「このMacへ復元…」を押します。システム領域に保存する場合、macOSの管理者認証が表示されます。復元前に選択データをSHA-256で検証します。
8. 結果の完了・スキップ・失敗件数を確認し、ライセンスを再認証します。必要ならメーカー公式インストーラを実行し、DAWを再起動・再スキャンして普段のプロジェクトを確認してください。

音源フォルダの中身まで列挙するため、初回スキャンや大容量データの検証には時間がかかります。表示容量は論理サイズの概算で、Finderの「ディスク上のサイズ」と異なることがあります。

## 購入パックのプリセットをまとめて整理する

1. ZIPなどの購入パックをFinder等で解凍します。
2. ツールバーの **「プリセット整理…」** を開き、解凍済みフォルダをドラッグエリアへ入れます。複数のパックフォルダを一度に追加できます。フォルダ内を再帰的に解析するので、シンセごとのファイルを先に取り出す必要はありません。
3. Serumの `.fxp` をどちらへ保存するか、**「Serum .fxp の保存先」** でSerumまたはSerum 2を選びます。`.SerumPreset` はSerum 2用として扱います。
4. 一覧で、ファイル・種類・シンセ・保存先・判定理由を確認します。判別できない項目は未選択です。必要なら複数行を選択し、「行の保存先」から対象シンセを選んで **「選んだ行に適用」** を押します。対象シンセと互換性のない形式や破損したヘッダは保存対象にしません。
5. **「選択したプリセットを保存…」** から一括コピーします。共有ライブラリへの書き込みにはmacOSの管理者認証が表示されます。保存結果はウインドウ下部のログで確認できます。
6. シンセ側のプリセット一覧を再スキャンするか、シンセを開き直します。SerumではMenu → Rescan folders on diskを使用します。[Xfer公式手順](https://support.xferrecords.com/article/22-how-do-i-import-3rd-party-presets-in-to-serum)

ドラッグ・解析・保存先の変更だけではファイルはコピーされません。新しいプリセットは**パック名と内部のサブフォルダを保って**保存します。フォルダ全体を無条件にコピーする機能ではありません。

### 自動判別する形式

| シンセ | 対象 |
|---|---|
| Serum | 製品ID `XfsX` を持つ `.fxp`。保存先はSerum / Serum 2を選択可能 |
| Serum 2 | `.SerumPreset`、`.serumfx`、`.serumfxrack`、`.xfershape`、`.xferpath`。各ファイルのXferヘッダ内の種類も照合 |
| Vital | `.vital`、`.vitaltable`、`.vitallfo` |
| Sylenth1 | 製品ID `syl1` を持つ `.fxp` / `.fxb` |
| Diva / Hive / Zebra2 / ZebraHZ | `.h2p` 内の `#AM` 製品名で判別 |

拡張子の大文字・小文字は区別しません。未知の製品IDを持つ有効なFXP/FXBや製品名のないH2Pは、対応候補から手動で対象シンセを指定できます。全シンセ・全形式の変換やインポートに対応するものではありません。[形式の調査記録](PRESET_FORMATS.md)も同梱しています。

### 付属Wavetable・Noise・Sampleの扱い

`Tables` / `Wavetables` / `Noises` / `Samples` / `Multisamples` など、用途が分かるフォルダ内の付属素材も候補に含めます。`.sfz` は `Multisamples` 内にある場合だけ対象にし、同じ構造内の音声ファイルも収集します。一般のループ・ドラム素材、画像、説明書、シンボリックリンク等は対象外です。

付属素材はカテゴリ配下の相対パスを保持します。例えば `Noises/BrandPack/noise.wav` はSerumの `Noises/BrandPack/noise.wav` へ保存します。プリセットと同じように余分なパック名フォルダを追加しないため、元の参照を維持しやすくなります。**プリセットやSFZ内のサンプル参照先は書き換えません。** パックの特殊な構成・絶対パスによってはシンセ側の再リンクが必要です。[Xfer開発者によるNoise参照の説明](https://xferrecords.com/forums/general/serum-presets-do-not-work/page-3)

Serum 1の `Noises` をSerum 2の `Samples` 配下へ自動変換する規則はありません。Serum FXPをSerum 2へ保存するときに旧形式のNoise配置を特定できない場合、その素材は未選択になります。元のSerumライブラリの構造を保つか、シンセの読み込み・再リンク機能で指定してください。

`.presetpack` / `.vitalbank` は一覧に理由を表示し、シンセ本体の専用インポート機能を使用します。ZIPの直接展開・RARの展開は行いません。

### 保存先の変更と既存ファイル

ライブラリ欄の **「保存先を変更…」** で、各シンセのライブラリルートを指定できます。Serumなら `Presets` の中ではなく、`Presets` / `Tables` / `Noises` 等が入る `Serum Presets` または `Serum 2 Presets` フォルダを選びます。独自の保存先はPluginPorter自身の設定に記憶し、シンセ側の環境設定は変更しません。シンセが参照する既存ライブラリのルートを指定してください。

プリセット整理ではファイル単位でコピーします。保存先の同名ファイルは内容が同じか異なるかを区別してログに記録し、どちらも上書きせずスキップします。既存フォルダの中へ新しいファイルを追加できます。元の購入パックはそのまま残ります。

## 一覧のCPU対応表示

一覧の「CPU対応」列で、Intel専用のプラグインをオレンジ色の **Intel専用** と表示します。検索欄には名前・メーカーのほか、`Intel専用` などのCPU対応表示も入力できます。

| 表示 | 検出した主実行ファイルのCPU構成 |
|---|---|
| Intel専用 | Intel 64bit（x86_64）を含み、Apple Silicon用のコードを含まない |
| 両対応 | Apple Silicon（arm64 / arm64e）とIntel（x86_64 / i386）の両方を含む |
| Apple Silicon | Apple Silicon用のコードを含み、Intel用のコードを含まない |
| Intel 32bit | Intel 32bit（i386）を含み、arm64 / arm64e / x86_64を含まない |
| その他 | 上記に該当しないCPU構成 |
| 未確認 | プラグインのCPU構成を取得できなかった |
| — | プリセット・音源などの関連データで、CPU判定の対象外 |

表示は主実行ファイルの検出結果です。プラグイン内部の全依存ライブラリや移行先DAWでの動作を保証するものではありません。CPU対応表示によってコピー可否や初期選択は変わりません。

## プラグイン移行の保存先と衝突の扱い

| 元の区分 | 移行先 |
|---|---|
| システムのプラグイン・プリセット・メーカーサポートフォルダ | 元と同じ `/Library/...` 内の相対パス |
| ユーザーのプラグイン・プリセット・メーカーサポートフォルダ | 移行先ユーザーの `~/Library/...` |
| `/Users/Shared` 内の選択フォルダ | 同じ場所 |
| 自分のDocuments内の選択フォルダ | 移行先ユーザーの `~/Documents/...` |
| 上記以外で手動追加した音源フォルダ | 移行先ユーザーの `~/Music/PluginPorter Libraries/フォルダ名` |

**バックアップからの復元では、同じパスの項目が存在すれば、その項目全体をスキップします。フォルダ同士のマージ、差分更新、上書きはしません。** 例えば `Arturia` フォルダを丸ごと選び、移行先に同名フォルダが既にある場合、中の新しいプリセットも含め全体がスキップされます。必要なサブフォルダだけ手動追加するか、プリセット整理機能・メーカーのプリセット読み込み機能を使用してください。既存ファイルを消して復元する機能はありません。

外部フォルダは元のSSDパスには自動復元しません。復元後、Native Accessや各音源の設定で新しい保存場所を指定してください。プラグインや製品データを外付けSSD上のまま参照するためのリンク作成も行いません。

## 移行できる範囲

- 本体、選択したプリセット・音源・メーカー別関連フォルダをコピーします。権限情報の一部や拡張属性・リソースフォークはmacOSの `ditto` で引き継ぎ、ACLは移行しません。
- 関連データは製品名・メーカー名による候補です。すべての製品の依存ファイルを自動で見つける機能ではありません。候補内に認証関連ファイルが含まれることもあります。不要なフォルダは選択しないでください。
- ライセンスの移行・解除・再認証は行いません。元のMacでの認証状態も変更しません。
- iLokなどの認証ランタイム、UADなどのドライバ・常駐サービス、Wavesなどの共有部品やメーカー管理アプリの登録は、公式インストーラが必要になることがあります。
- AUv3のホストアプリ、macOSのシステム拡張、LaunchDaemon、Keychain、一般的なPreferencesやDAW設定・キャッシュは自動収集しません。Documents内や外付けSSD内のデータは「音源フォルダを追加」から指定してください。ライブラリ管理アプリにインストール済みとして登録する機能もありません。
- Intel専用・旧32bitプラグインがコピーによってApple Silicon対応になることはありません。一覧の構成情報は主実行ファイルのCPU情報で、動作保証や内部の全依存ライブラリの検証ではありません。
- 外部や絶対パスを指すシンボリックリンクを含む項目は、誤った場所への書き込み・不完全なバックアップを防ぐため書き出しを止めます。エラーに出た項目を外し、製品の公式インストーラを利用するか、リンク先の実データを別途指定してください。バンドル内部で完結する相対リンクは保持します。
- Finderエイリアスファイルを音源本体へ展開する機能はありません。エイリアス先の実データを選択し、移行先で保存場所を再指定してください。
- パッケージは圧縮・暗号化されていません。選択元のパス、製品名、データ内容を含むため、受け渡し先を確認してください。

SHA-256は通常ファイルの内容・相対パス・種類・リンク文字列を検証します。拡張属性・リソースフォーク・所有者・アクセス権はハッシュ対象外です。パッケージは自分で作成したものを使用してください。ハッシュは転送破損の検出用で、発行元の署名ではありません。

## ターミナルで使う

リポジトリから使う場合は、先に `./build.command` を実行します。配布用に使う場合は、`pluginporter` と `PluginPorter.app` を同じフォルダに置きます。ランチャーは同じフォルダのアプリを優先し、次に `dist/PluginPorter.app` を探します。以下の `USER` やSSD名は実際の値に置き換えてください。

```sh
# 本体一覧をJSONで保存。まだ何もコピーしません。
./pluginporter scan --output inventory.json

# コピー可能なプラグイン本体をまとめて書き出し（除外した項目はログに表示）
./pluginporter export /Volumes/Transfer/Plugins.pluginporter

# 名前で絞って書き出し
./pluginporter export /Volumes/Transfer/FabFilter.pluginporter --match FabFilter

# 関連データ候補を含む一覧を作り、JSON内の不要な項目を削除してから実行
./pluginporter scan --include-data --output plan.json
./pluginporter export /Volumes/Transfer/Selected.pluginporter --plan plan.json

# パッケージの一覧と破損チェック
./pluginporter inspect /Volumes/Transfer/Plugins.pluginporter
./pluginporter verify /Volumes/Transfer/Plugins.pluginporter

# 移行先で保存先だけ確認（内容検証やコピーは行いません）
./pluginporter restore /Volumes/Transfer/Plugins.pluginporter --home /Users/USER --dry-run

# 移行先で復元。システム領域に保存するためsudoを使用
sudo ./pluginporter restore /Volumes/Transfer/Plugins.pluginporter --home /Users/USER --report /Users/USER/Desktop/pluginporter-result.json

# 解凍済みパックを解析。JSONの保存先・選択状態を確認（まだコピーしません）
./pluginporter preset-plan "/Users/USER/Downloads/Pack A" "/Users/USER/Downloads/Pack B" --serum-target serum1 --output preset-plan.json

# SerumのFXPをSerum 2へ配置するプランを作成
./pluginporter preset-plan "/Users/USER/Downloads/Pack A" --serum-target serum2 --output preset-plan.json

# プランの選択項目を保存。ユーザー領域へのコピーの例
./pluginporter preset-install preset-plan.json --report preset-result.json

# /Library配下など管理者権限が必要な場合。プラン作成は一般ユーザーで実施
sudo ./pluginporter preset-install preset-plan.json --report /Users/USER/Desktop/preset-result.json
```

復元は常に `--home` が必須です。元のMacのホームではなく、**移行先の一般ユーザーのホーム**を指定します。ユーザー領域だけなら `sudo` は不要です。終了コードは0が正常（既存スキップを含む）、1が処理中止、2が一部復元失敗です。CLIを途中で強制終了した場合、転送先に `.PluginPorter-*.partial` フォルダが残ることがあります。元データは変更されません。

`preset-plan` の `--serum-target` は省略時 `serum1` です。プリセット整理プランはバックアップ用プランとは別形式です。`preset-install` は記録された元ファイルと保存先を使い、コピー前に形式とパスを再検証します。解析時の保存先やチェックをアプリで調整したい場合は、アプリ側のドラッグ操作を使用してください。

## アプリの署名と再ビルド

このアプリはローカルでビルドしたアドホック署名版で、AppleのDeveloper ID署名・公証はありません。別のMacへダウンロード経由で渡した場合、Gatekeeperの確認が出ることがあります。自分で作成したアプリであることを確認したうえで、macOSの「プライバシーとセキュリティ」から個別に許可するか、同梱ソースを移行先で再ビルドしてください。Mac全体のセキュリティ設定を無効化する必要はありません。

ソースは `Sources/` に同梱しています。Xcode Command Line ToolsがあるMacで `build.command` を実行すると、`dist/PluginPorter.app` を作成します。

```sh
./build.command
```

検証結果: エンジン16項目、コマンド版の書き出し→検証→復元・衝突・破損検出テストが成功しました。実際のアプリ画面でも、自動スキャン・検索・書き出し不可項目の選択制御を確認しました。

復元テストは実在のプラグインではなく、一時フォルダに作成したテスト用バンドルで実施しています。管理者認証を伴う復元、別Macでの復元、各DAWでの全製品の動作は未検証です。

プリセット整理は25項目のテストを通過しました。一時フォルダに作成したテスト用パックで、識別・シンセ別配置・付属素材の階層維持・既存ファイルの扱い・不正なパスの拒否・元ファイルの保持を確認しています。コマンド版の解析→4件のコピー→再実行時の4件の重複スキップも確認しました。画面ではフォルダ選択から振り分けプレビューまでを確認しています。開発中にユーザーの購入プリセットを実ライブラリへコピーしていません。実際のシンセでの音色再現や、付属音源がすべて自動解決することは未検証です。

アプリは起動したMacを改めてスキャンします。特定のMacで生成したプラグイン一覧CSVは、このリポジトリには含めていません。
