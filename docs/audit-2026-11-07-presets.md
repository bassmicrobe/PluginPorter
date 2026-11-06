# プリセット整理エンジン監査 — 2026-11-07

> この文書は監査実施時点の記録です。以降の署名・公証・公開状況はREADMEとGitHub Releasesを参照してください。

対象: `4083c52d10fb0b02162f0ec5574533952d061ce1` を基準とする `Sources/PresetEngine.swift`、`Sources/PresetModels.swift`、`Tests/PresetTests.swift`。READMEとPRESET_FORMATS.mdにある「元パックを変更しない」「同名ファイルは上書きしない」「パック名と内部のサブフォルダを保つ」を期待動作とした。GUI・管理者認証・実シンセの音色再現はこの部分監査の実操作対象外であり、全体報告で別途扱う。

## 確認できた不具合と修正

### PRESET-01: Vital補助ファイルの保存階層にパック名が重複する

- 監査項目: ①機能、⑦ファイル保存。
- 重大度: 低。利用者が取り込むVitalのWavetable・LFOのフォルダ構造が仕様より一階層深くなる。元データの削除・上書きや機密情報漏えいは確認していない。
- 発生条件: 購入パック内の `.vitaltable` または `.vitallfo` に、`Wavetables` / `Tables` / `LFOs` などのカテゴリを示す親フォルダがない。例: `<Pack>/Shapes/Wave.vitaltable`。
- 修正前: `<Vital root>/<Pack>/Wavetables/<Pack>/Shapes/Wave.vitaltable` に保存される。カテゴリの前と後に同じパック名を付与していた。
- 期待動作: `<Vital root>/<Pack>/Wavetables/Shapes/Wave.vitaltable`。パック名と入力の相対階層を一度ずつ保つ。
- 根拠: READMEの階層保持説明、PRESET_FORMATS.mdのVitalパック構造。[Vital作者の実装](https://raw.githubusercontent.com/mtytel/vital/main/src/common/load_save.cpp)も2026-11-07に確認し、Wavetables・LFOs等のカテゴリ名とパック単位の構成を照合した。実シンセが旧配置を全く読み込めないとは断定していない。
- 該当処理: `Sources/PresetEngine.swift:266` の `destinationRelative`。Vitalは既にカテゴリより上にパック名があるため、フォールバックの相対パスへ二重追加しないよう修正した。Serum 2のカテゴリ配下への配置規則は保持。
- 検証: `Tests/PresetTests.swift:147`。両補助形式の保存先と、解析→インストール完了2件を確認。追加直後は期待パスの検証が失敗し（30/31）、最小修正後に成功した。
- 残件: この旧配置を含む保存済みプランは、保存先の再計算検証で拒否されるため再解析が必要。旧版が既に作成したファイルを自動移動・削除しない。実シンセの再スキャン・ロードは未確認。

## 検証結果

実行環境: Apple Silicon `arm64`、macOS 27.2 (26B123)、Xcode 27.2 (27B52)、Apple Swift 6.4.2。コマンド: `./Tests/run-preset-tests.sh`。テスト専用一時フォルダを使用し、実プラグイン・実プリセット・実ライブラリへのインストールは行っていない。

| 段階 | 結果 |
|---|---|
| 変更前の既存テスト | 29/29 成功。既存失敗なし |
| Vital回帰テスト追加後 | 30/31。Vitalのパック名二重追加を検出 |
| 最終プリセット実装の検証 | 33/33 成功 |

既存テストで確認したのは、Serum/Sylenth/u-he/Xferヘッダ識別、素材階層保持、明示的な手動割り当て、保存前の全項目検証、同一内容・競合内容の両スキップ、パストラバーサル拒否、シンボリックリンク拒否、入力パック不変、対象ファイルのない入力パックの保護、旧形式プランの読み込みである。テスト数だけで形式の完全性や実シンセの互換性を保証しない。

不具合と断定せず追加確認した項目:

- `SerumPrefs.json` を書き手のないFIFOにした検証用ホームでも、既存実装のライブラリ検出は1秒以内に終了した。コードの見た目から懸念した起動停止は再現せず、当該実装は変更していない（`Tests/PresetTests.swift:110`）。
- 同じ入力パックを大小文字の異なるパスでライブラリへ指定した場合、解析時・インストール時とも書き込み前に拒否した。テスト環境のファイルシステムで大小文字別名が同一ディレクトリを指すことを別途確認した。大文字小文字を区別するボリュームでは、このテストの別名分岐は対象外となる（`Tests/PresetTests.swift:124`）。
- Serum/Vitalのフォルダを併せたテストパックで、対象不明の音声素材が未選択のままになることを確認。実装上の列挙順依存の懸念について、全列挙順での決定性は検証していない。再現できた不具合としては扱わず、実装を変更していない（`Tests/PresetTests.swift:158`）。

## 改善提案・未確認

- 大規模パックでは、付属音声ごとに既に解析した項目を再走査して対象シンセを推定する。パック単位の候補を事前集計する改善余地がある。今回、同条件の処理時間・メモリー前後比較は実施しておらず、速度低下や改善率を数値で断定しない。
- FXP/FXB・Xferのヘッダ確認、Vitalの文字列特徴、u-heの製品名、音声カテゴリは識別用途の検査であり、全フォーマット・内部参照の完全な検証ではない。特にVital補助形式は拡張子による判定である。完全検証の採用には、対象バージョンの実ファイルと互換性条件を調べる必要がある。
- 通常ファイルをコピー前にハッシュ検証し、ステージング先の一致確認後に上書き禁止で確定する。ソース・保存先が別プロセスから敵対的に同時変更される全競合、外部ドライブ切断、容量不足、権限変更はこの部分監査では未確認。
- 管理者権限での所有者設定、実際のプリセット再スキャン、音色・SFZ参照解決、最小対応macOS 12、別CPU、配布物の署名・公証は本テストの成功から判断しない。全体監査の結果または専用環境での追加確認が必要。

## 追加: プロジェクト全体の自動テストカバレッジ

既存4種類のテストを再利用し、計測専用の `Tests/run-coverage.sh` を追加した。既存runnerは変更していない。実行時にSources/TestsのSwiftファイルを `.build/coverage.XXXXXX/snapshot` へコピーし、各ファイルのSHA-256とツール版を保存するため、並行作業で後からソースが変わっても計測対象を特定できる。

再現コマンド: `./Tests/run-coverage.sh`。`swiftc -swift-version 5 -Onone -g -module-name PluginPorterCoverage -profile-generate -profile-coverage-mapping` でEngineTests、PresetTests、AppTests、CLITests、およびCLI子プロセス本体をビルドする。同じ実装関数の計測値が合流するようmodule名を統一し、`LLVM_PROFILE_FILE` の `%m-%p` で実行バイナリ・プロセスごとに記録する。`llvm-profdata merge --sparse --failure-mode=any` と `llvm-cov report/export` で、テストファイル・GUI stub・CLI inventory fixtureを除き `Sources/*.swift` のみを集計する。AppTestsのinventory loaderとCLI scannerは既存テスト用fixtureであり、実プラグインは変更しない。

最終計測成果物: `.build/coverage-final.x9l276ab/`（CLIの最終修正前の全計測は `.build/coverage.3tnq4i/` に保持）。`report.txt`、`core-report.txt`、`coverage.json`、`merged.profdata`、各build/testログ、snapshot、`sources.sha256`を保存。計測完了後、snapshotの全Sources/Tests Swiftファイルが作業ツリーの同名ファイルと一致することを確認した。

| 対象 | LLVMの行カバレッジ | Regionカバレッジ | 関数カバレッジ |
|---|---:|---:|---:|
| 全Sources（GUI・CLIを含む） | **51.42%** | 50.12% | 43.80% |
| Coreのみ（Models / Inventory / Engine / PresetModels / PresetEngine） | **82.04%** | 74.39% | 75.13% |
| Engine.swift | 95.22% | 86.64% | 88.89% |
| PresetEngine.swift | 96.63% | 84.92% | 89.77% |
| Inventory.swift | 53.19% | 45.60% | 40.82% |
| main.swift（CLI子プロセスを含む） | 86.73% | 70.30% | 70.59% |
| App.swift | 41.32% | 17.67% | 31.25% |
| PresetWindow.swift | 0.00% | 0.00% | 0.00% |

**プロジェクト全体の80%目標は未達。** Coreの行カバレッジだけを全体の達成として扱わない。LLVMが報告する実行可能行の統計であり、今回の出力は物理ファイルの行数とは一致しない。単一のapp-testsバイナリでも同じファイル別統計となることを確認し、複数実行バイナリを集計したことによる行数増加ではない。Branch情報はこのSwiftツールチェーンの出力で0件のため、分岐カバレッジが100%とは判定しない。

計測付きテスト結果: Engine 21/21、Preset 33/33、App 6アサーション成功、CLI 15/15（スキップ0）。すべてexit 0。CLIの子プロセスもinstrumentしたため、harnessだけが通った数値ではない。初回snapshot `.build/coverage.jCUSsK` はEngine担当のTDD途中（新規テストが先行し実装が未更新）を取り込み19/21で終了した。そのログを保存し、実装完了後の新しいsnapshotで上記結果を確認した。最終実装の失敗として扱わず、初回結果を成功へ書き換えていない。

次の改善対象は、実在ライブラリを読まないscanner fixtureを使うInventory経路、および画面モデル・保存先指定・選択状態・成功/失敗/キャンセルを検証するPresetWindow/AppのGUIテストである。今回、数値を上げる目的だけのテスト追加や集計対象の恣意的除外は行っていない。GUI実操作、配布物、性能計測の結果を自動テストカバレッジへ加算することもしていない。

最終CLI修正後の再計測では、変更のないEngine/Preset/Appの3つのprofileを再利用し、CLI本体とharnessだけを再コンパイル・実行した。旧CLIのprofile（子30件・harness1件）はmodule署名と関数名を照合して除外し、新CLIのprofileへ置き換えた。`incremental-reuse.json` に再利用元・除外moduleを保存している。`-coverage-prefix-map` で共通ソースの計測上のパスを揃え、`llvm-cov` の `-path-equivalence old,new` で最終snapshotを参照して集計した。出力対象がSourcesの8ファイルのみであること、Core集計が再利用前後で一致すること、最終snapshotが現行Sources/Testsと一致することを確認した。途中のreport出力でpath-equivalence区切り指定の誤りを修正したが、テストとprofile収集は成功済みだったため再実行していない。
