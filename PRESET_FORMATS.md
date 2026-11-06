# プリセット識別・保存先の調査記録

2026-09-19 に、この Mac の既存ディレクトリ、少数のプリセットの先頭部分、公式資料を読み取り確認。以下は実装判断の根拠であり、全形式の動作保証・対応一覧ではありません。ユーザーのプリセット、設定、認証情報は変更していません。

## 識別と保存先

`~` は実行ユーザーのホームです。既存のカスタム保存先を優先します。

| 製品 | 確認できた識別条件 | プリセット保存先 |
|---|---|---|
| Serum 1 | `.fxp`、先頭 `CcnK`、バイト 8–11 `FPCh`（実ファイルで観測）または `FxCk`（VST2標準）、16–19 `XfsX` | `<Serum 1 root>/Presets/<Pack>/…` |
| Serum 2 | 大文字小文字を無視した `.serumpreset`、先頭 `XferJson`、初期 JSON の `fileType` が `SerumPreset` | `<Serum 2 root>/Presets/User/<Pack>/…` |
| Vital | `.vital`、JSON の `synth_version` と `settings` | v1.2は `<Vital root>/<Pack>/Presets/…` に配置。製品には `User/Presets` も存在 |
| Sylenth1 | `.fxp` / `.fxb`、先頭 `CcnK`、バイト 16–19 `syl1` | `~/Library/Application Support/LennarDigital/Sylenth1/Presets/<Pack>/…`。`.fxb` は `SoundBanks/<Pack>/…` |
| u-he | `.h2p` の先頭 8 KiB 内に `#AM=Diva` / `Hive` / `Zebra2` / `ZebraHZ` の行 | `~/Library/Audio/Presets/u-he/<製品>/…` |

拡張子 `.fxp` / `.fxb` / `.h2p` だけでは製品を特定できません。既存の製品フォルダ内にも他製品のプリセットが混在していました。未確認の ID は自動で割り当てず、手動指定対象にします。

## 保存先の検出

- Serum 1: `~/Library/Preferences/SerumPrefs.json` の `Serum Presets Path`。空白の場合は `/Library/Audio/Presets/Xfer Records/Serum Presets`。
- Serum 2: `~/Library/Preferences/Serum2Prefs.json` の同じキー。標準ルートは `/Library/Audio/Presets/Xfer Records/Serum 2 Presets`。
- Vital: `~/Library/Application Support/vital/Vital.config` の `data_directory`。この Mac では `~/Music/Vital`。製品ルート内にパック名フォルダ、その直下に `Presets` / `Wavetables` / `Samples` / `LFOs` が存在します。

これらの確認済みルートは、この Mac ではシンボリックリンクではありません。設定の書き換えや認証ファイルの読み取りは不要です。

v1.2 のアプリで手動指定したルートはPluginPorter自身のUserDefaultsに保存します。シンセの環境設定を書き換えて参照先を移す機能ではありません。CLIの `preset-plan` はシンセ設定と標準保存先から検出します。

## 付属音源とフォルダ構造

- Serum 1 の付属データは `Tables` / `Noises` / `LFO Shapes` / `Effect Chains` 等。
- Serum 2 の付属データは `Tables` / `Samples` / `Multisamples` / `LFO Shapes` / `LFO Paths` / `Effect Chains` 等。
- 明示的なカテゴリの下にある相対パスは保存します。例: `Noises/BrandPack/noise.wav` → `<Serum 1 root>/Noises/BrandPack/noise.wav`。`Imported` や外側のパック名を勝手に挿入しません。
- カテゴリ外の一般的な WAV / AIFF / FLAC は、波形テーブルや Noise と断定できません。サンプルパック全体を音源フォルダに流し込まないよう、未判定にします。
- 内容の異なる既存付属音源は上書き・自動改名せず、競合を表示します。プリセット内の参照を壊す可能性があるためです。
- **Serum 1 の `Noises` を Serum 2 の `Samples` のどこへ対応させるかは、今回の公式資料調査では一意に確認できませんでした。** Serum 1 FXP の保存先を Serum 2 に変更した場合も、その Noise を `Samples/User` 等へ推測で配置しません。未判定として元構造を保ち、ユーザーの保存先指定または Serum 内での再リンクを必要とします。
- `Serum 2 Presets/Samples/Factory Non-Tonal/Noises` はローカルに存在しますが、この事実だけではすべての旧プリセットの参照先になるとは判断できません。
- `.presetpack` / `.vitalbank` 等のネイティブパックは単一プリセットではありません。専用インポートまたは検証済みの安全な展開処理が必要です。

### Serum 2 の補助形式（ファイル名から確認）

| ディレクトリ | 観測した主要形式 |
|---|---|
| `Multisamples` | `.sfz` と付属 `.flac` / `.wav` |
| `Effect Chains` | `.serumfx` / `.serumfxrack` / `.fxs` |
| `LFO Shapes` | `.xfershape` |
| `LFO Paths` | `.xferpath` |

補助形式の中身の完全解析やロード検証はしていません。SFZ のサンプル参照もあるため、個別の SFZ だけ抽出する設計は避けます。

## 公式根拠

- [Xfer: サードパーティープリセットのインポート](https://support.xferrecords.com/article/22-how-do-i-import-3rd-party-presets-in-to-serum): `Presets` 配下に配置し、Serum の「Rescan folders on disk」で更新。
- [Xfer 開発者: Serum プリセットと Noise の参照](https://xferrecords.com/forums/general/serum-presets-do-not-work/page-3): Noise のファイル名・フォルダ位置を自由に変更できない旨。カスタム波形テーブルはプリセットに埋め込まれるとの説明。
- [Serum 2 公式マニュアル](https://www.xferrecords.com/manual/serum-2/docs): Appendix C に設定、Appendix D にライブラリ構造。Noise oscillator の節にサンプルの読み込みとプリセットへの埋め込み。
- [Serum 2 インストール資料](https://xferrecords.com/web-manual/serum-2/installing-serum): macOS コンテンツと `Serum2Prefs.json` の場所。
- [Vital 作者のソース `load_save.cpp`](https://raw.githubusercontent.com/mtytel/vital/main/src/common/load_save.cpp): `data_directory`、プリセット JSON、User および各カテゴリのフォルダ名。
- [LennarDigital: Soundbanks and Presets](https://www.lennardigital.com/support/soundbanks.php) / [Sylenth1 公式マニュアル](https://www.lennardigital.com/files/Sylenth1Manual.pdf): `.fxp` プリセット、`.fxb` バンク、Data Folder。
- [JUCE 8.0.0 のVSTホスト実装](https://raw.githubusercontent.com/juce-framework/JUCE/8.0.0/modules/juce_audio_processors/format_types/juce_VSTPluginFormat.cpp): `CcnK`、`FxCk` / `FPCh`（単一プリセット）、`FxBk` / `FBCh`（バンク）、製品IDのヘッダ位置。

ヘッダの具体的な ID とローカルの補助形式は、上記資料からの保証ではなく、この Mac の既存ファイルに対する読み取り観測です。

## Serum 2 ヘッダの追加確認

5 件の既存 `.serumpreset` で次の構造を読み取り検証しました。

| 0 始まりのオフセット | 内容 |
|---|---|
| 0–7 | ASCII `XferJson` |
| 8 | NUL (`0x00`) |
| 9–16 | JSON のバイト長。リトルエンディアンの 64 ビット整数として読み取れる |
| 17 以降 | 指定長の JSON オブジェクト。`fileType` は正確に `SerumPreset` |

JSON の観測長は 297 / 309 / 315 / 297 / 302 バイトで、その長さを読むと各 JSON が完全に解析できました。`.serumfx` / `.serumfxrack` / `.xfershape` も同じ外形を持ち、それぞれ `SerumFX` / `SerumFXRack` / `XferShape` の型名でした。判定では JSON の読み取り長に上限を設け、ファイルサイズを超えないことを確認し、解析後の `fileType` を比較します。ファイル全体に `SerumPreset` という文字列が含まれるだけでは判定しません。後続の圧縮データの解析は不要です。
