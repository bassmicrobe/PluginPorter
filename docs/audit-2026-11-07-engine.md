# PluginPorter 監査: 転送エンジン・インベントリ

> この文書は監査実施時点の記録です。以降の署名・公証・公開状況はREADMEとGitHub Releasesを参照してください。

実施日: 2026-11-07 (JST)。基準コミット: `4083c52d10fb0b02162f0ec5574533952d061ce1`。対象は `Models.swift`、`Engine.swift`、`Inventory.swift` と関連テスト。GUI・CLI引数・プリセット整理・配布物は別担当の監査結果を参照すること。

## A. 範囲と環境

macOS 27.2 (26B123)、arm64、Mac17,3、物理CPU 10コア、メモリ32GiB、APFS上で検証した。Xcode 27.2 (27B52)、Apple Swift 6.4.2。エンジン機能テストは既存の `swiftc` 構成、性能測定は製品と同じ `-swift-version 5 -O -target arm64-apple-macos12.0` を使用した。

対象はApple silicon / macOS 12以降のPluginPorter 1.2ビルド4のソース。最低対応OSでの実機動作は未確認であり、ここではmacOS 27.2上の結果のみを報告する。

| 監査項目 | 判定 | 実施範囲・制限 |
|---|---|---|
| ①転送・検証・復元、⑦ファイル整合性 | 指摘あり | 通常ファイル、内部相対リンク、既存衝突、破損、境界値、途中エラーを合成fixtureで確認。ENG-01/03を修正 |
| ⑥外部入力、⑭Foundation読取 | 指摘あり | メタデータの型・サイズ・実パスを確認。ENG-02を修正 |
| ⑨大容量処理のメモリ | 指摘あり | 合成256MiBの同条件測定。ENG-04を修正 |
| 通信・ログイン・課金・ローカルDB | 対象外 | 担当エンジンに該当機能なし。別サーバーの安全性を主張しない |
| rootでの所有者設定・特権復元 | 未確認 | 管理者認証や実ライブラリへの書込を行っていない |
| スリープ復帰・外部ディスク切断・容量不足 | 未確認 | 実機全体に影響する操作は行わず、専用fixtureだけ使用 |
| 敵対的な同時パス変更 | 未確認 | ファイル種別検証からopen/renameまでの競合攻撃は未検証。静的なsymlink拒否を競合耐性の証明として扱わない |

## B. 確認した不具合と修正

### ENG-01: 外部JSONの容量値が未検証（中、①⑥⑦）

`bytes = -1` や、2項目の合計が `Int64.max + 1` になるplan/manifestを受理していた。前者は不正な容量表示、後者はGUIの `chosen.reduce(Int64(0)) { $0 + $1.bytes }` による整数overflow停止につながる。GUI停止自体はこの担当では実操作再現していないが、旧版が合計overflow入力を受理することは専用実行コードでも確認した。

外部入力を検証する [Engine.swift](../Sources/Engine.swift#L143) で非負値と `addingReportingOverflow` による合計を検証した。拒否時はarchiveを公開せず、復元先も変更しない。通常の正値を持つ過去archiveの形式は変更していない。

回帰テストはexport planとreadManifestの双方を検証し、負値・合計overflowを拒否、元のデータと復元先を保持することを確認した。状態: 修正済み。

### ENG-02: インベントリがバンドル外のメタデータを読み取る（中、⑥⑨⑭）

従来の `bundleInfo` は `Info.plist` の種類を検証せず、symlink自身の長さを上限検証に使用してからリンク先全体を読んでいた。バンドル外plistの `CFBundleExecutable` を実際にCPU判定へ使用することを回帰テストで確認した。また、`Contents/MacOS` が外部ディレクトリへのリンクの場合、主実行ファイルの属性が通常ファイルならそのバンドル外データを読んでいた。どちらも実行ファイルの実行には至らない読取の問題である。

`Info.plist` を通常ファイルに限定し、解決したパスがバンドル内にあること、サイズが既存の2,000,000バイト上限未満であることを確認し、読取自体にも上限を適用した。[Inventory.swift](../Sources/Inventory.swift#L132) 主実行ファイルにも解決後のバンドル内判定を適用した。[Inventory.swift](../Sources/Inventory.swift#L178)

修正前に外部plistと外部実行ファイル祖先リンクのテストが失敗したことを確認。修正後は両方を無視し、CPU情報が得られない場合は既存の「未確認」動作へ戻す。FIFOを開かず処理が戻ること、安全なバンドル内部の相対Info.plistリンクを引き続き扱えることも確認した。FIFOの修正前ハングは未実証であり、明示的に通常ファイルへ限定した防御として扱う。状態: 修正済み。

### ENG-03: 作成成功したarchiveを自身のreaderで開けない（中、①⑦）

readerは20,000項目以下・manifest 32MiB未満に限定していたがexportに対応する制約がなかった。旧版の項目検証が20,001件を受理すること、32MiBを超えるmetadataでexportが成功することをテストで確認した。期待する動作は、読み戻せないarchiveを成功として公開しないことである。

件数とmanifestサイズを [Engine.swift](../Sources/Engine.swift#L7) の共通定数へ集約した。件数はコピー前、encoded manifestサイズはstageを公開する前に拒否する。[Engine.swift](../Sources/Engine.swift#L44)

回帰テストは両制約の修正前失敗を確認し、修正後は拒否、stage削除、元ファイルの保持を確認した。状態: 修正済み。大量metadataの制限はコピー後の検証なので、拒否までコピー時間を要する場合はある。

### ENG-04: ストリーミング検証の読取バッファが操作中に蓄積（中、⑨⑭）

1MiBずつ読み取っていたが、Foundationのautoreleasedバッファの解放が転送処理全体の終了まで遅延し、256MiBの合成データで約1,038MiBのpeak memory footprintを測定した。大容量音源のSHA-256検証時にメモリ負荷が増える問題である。

ハッシュへの入力を変えず、各chunkの読取・hash更新を `autoreleasepool` で囲んだ。[Engine.swift](../Sources/Engine.swift#L225) 大量の一時オブジェクトを生成するループに局所poolを設けてpeak footprintを抑える方式はAppleの説明に対応する。[Apple: Using Autorelease Pool Blocks](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html)

既存のdigest一致・破損拒否・metadata保持・再復元skipテストを維持した。下記の同条件測定でメモリ低下を確認。状態: 修正済み。ファイル一覧の配列は引き続き件数に比例して保持されるため、アプリ全体のメモリを一定量に制限したという意味ではない。

## C. 検証結果

`./Tests/run-engine-tests.sh` の修正前は16/16群成功。追加した境界・リンク・metadataテストで意図したREDを確認した後、最終版は21/21群成功した。比較対象は実在製品ではなく、各テストが作成・削除する専用fixture。テスト用Mach-Oヘッダはデータとして読むだけで、実行しない。

確認した観測結果は、source保持、内部相対symlink保持、mode/xattr/resource fork保持、既存項目をmerge/上書きしないこと、復元対象の全件検証後にコピーを開始すること、破損・traversal・symlinkを拒否した際に拒否先へ書き込まないこと、独立する正常項目は部分失敗でも完成すること。SHA-256は権限・所有者・xattr・resource forkを対象にしないという既存仕様を変更していない。

`git diff --check` 成功。Engine単独の検証結果であり、GUI・配布物・署名・公証の成功を意味しない。プロジェクト全体のcoverageは別途の統合計測を参照すること。

### 性能測定

[EnginePerformance.swift](../Tests/EnginePerformance.swift#L4) の256ファイル×1MiB＝256MiBを、内蔵APFS上の専用ディレクトリで作成→export→verify→restore→削除した。source、archive、復元先は分離した。baselineは上記HEADのModels/Engine、finalは修正後の同ファイル。両方を同じSwift 5言語モード・arm64・最適化・macOS 12 deployment targetでコンパイルし、baseline/finalの順で3回交互に測定した。root権限、実製品、実音源は使用しない。

| 指標 | baseline 3回 | final 3回 | baseline中央値 | final中央値 |
|---|---|---|---:|---:|
| export+verify+restore (秒) | 2.462、1.897、2.218 | 2.058、1.918、1.701 | 2.218 | 1.918 |
| maximum RSS (MiB) | 573.78、786.38、786.38 | 18.73、18.69、18.67 | 786.38 | 18.69 |
| peak memory footprint (MiB) | 1038.44、1038.47、1038.41 | 11.17、10.92、11.91 | 1038.44 | 11.17 |

RSSとfootprintは `/usr/bin/time -l` の別の指標であり、混同しない。各値は親の検証プロセスの数値で、ditto子プロセスを含むアプリ全体の常時メモリ測定ではない。wall秒はfixture生成・削除を除く操作区間、CPU時間・RSSはfixture生成・削除も含むプロセス単位。測定時に他の監査作業が並行しており、時間差を普遍的な高速化率として扱わない。Instruments、GPU、電力、idleやウィンドウ開閉時はこの測定の対象外。

再実行例（リポジトリルートで実行）:

```sh
mkdir -p .build/audit-engine
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos12.0 \
  Sources/Models.swift Sources/Engine.swift Tests/EnginePerformance.swift \
  -o .build/audit-engine/large-final
/usr/bin/time -l .build/audit-engine/large-final
```

生の測定結果とbaselineソースの検証用コピーは、Git対象外の `.build/audit-engine/large-{baseline,final}-{1,2,3}.{result,time}.txt` に保存した。benchmark fixtureは各実行後に削除済み。測定に独自の合否閾値は設けていない。

## D. 改善提案

- `Inventory.scan` は列挙失敗や1製品の読取失敗を無表示で省略する。他製品のスキャン継続は合理的だが、読み取れなかった場所と省略件数を利用者へ返す構造を追加すると、不完全な一覧を完全な一覧と誤認しにくくなる。UI/CLIの表示方針を決めて変更する範囲のため今回の単独修正から分離した。
- `validateItems` の保存先重複判定は二重ループ。上限以内の非常に多い項目ではCPU時間が増える。並び替えやprefix索引による改善は有効な可能性があるが、通常データ量の目標値・測定条件と回帰テストを整えて別途評価する。
- stage掃除の失敗、FileHandle.close失敗の記録は限定的。利用者向けの安全な残骸削除案内と診断ログ方針を揃えて改善する余地がある。元データを消す復旧機能は追加していない。

## E. 残件と判断の限界

通常ユーザーでの合成fixtureに対し、転送・検証・復元の成功と主要拒否経路の保全を確認した。実製品のライセンス、DAWによるロード、別Mac、macOS 12、外部/ネットワークFS、電源断、特権所有者変更、敵対的な同時置換は未確認。これらは対象Mac、テスト用ライブラリ、必要に応じた管理者操作の許可を用意して次に確認する。

この結果はローカルエンジン修正の妥当性を支持するが、公開配布物が修正を含むことや、署名・公証・Gatekeeperを通ることの証明にはならない。
