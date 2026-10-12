# CNC1800L miniloader(1st stage) 解析メモ

対象: GPL パッケージ `signing_tool/miniloader/miniloader.bin_*`(16 種類、全て 46336 byte = 0xB500)。
手法: 静的解析のみ(`objdump -b binary -marm`)。**実機・ROM は未入手**。結論は推測を含む。

## 1. バイナリの構造
| オフセット | 内容 | 状態 |
|---|---|---|
| 0x000–0x1FF | ゼロ | |
| 0x200–0x23F | ヘッダ風の値(0xB000, 0xBC00, 0x6FF00, 0x2000000, DDR周波数コード…) | 平文 |
| 0x240–0x5FF | 乱数様データ(ハッシュ/公開鍵領域と思われる) | 不明 |
| 0x600–0x8DFF | **平文の ARM コード**(約 10K 命令。条件コード 0xE 比率 80–100%) | 解析可能 |
| 0x8E00–0xB4FF | 高エントロピー(約 7.9 bit/byte)。暗号化/圧縮された補助コード(`SCSAuxCode`)と思われる | **読めない** |

`mk_nonsec_image` 出力 (`signed_miniloader.bin`) は、この 0xB500 byte の直後に **パラメータブロック(1627 byte)** を連結したもの:

```
+0x00 0x0000B000  SCSAuxCodeSize (miniloader サイズ)
+0x04 0x00080000  2nd boot loader の flash 上エントリ
+0x08 0x0005FF00  2nd boot loader の最大サイズ
+0x0C 0x02000000  2nd boot loader の実行(DRAM)アドレス
+0x10..0x24       DDR 設定 6 words (先頭 = 周波数コード 0x1500 等)
+0x28 0x00020000  NAND ブロックサイズ
+0x2C 0x00018B01  [bit0]=不良ブロック検出 [15:8]=BootLoaderFlashCfg(0x8B) [16]=dual boot
+0x30,+0x34       ExtDDR 設定 (0x2, 0xE)
```
→ 続いてハッシュ/署名(`sign_sha256.sh` は `openssl sha256` の出力を書くだけ=「insecure」版)。
フラッシュ上の並び: `signed_miniloader` → fail-safe(safe boot) U-Boot (`signed_u-boot.bin`) → 2nd boot loader (`signed_u-boot2.bin`、flash 0x80000)。

## 2. 平文部の機能(確認できたこと)
- SHA-256 定数(0x6A09E667 系)と大数演算が含まれる → **2nd loader のハッシュ/署名検証**を行う。
- **NAND コントローラ**(0x80100000)と **SPI コントローラ**(0x80150000 + pinmux 0xB2110000)の両方のドライバを内蔵。
- フラッシュ種別の判定関数 (オフセット 0x533C):
  ```
  boot_info = *(u32*)0xFFFFF010               // ROM が置く情報と思われる
  if (!(boot_info & BIT(16))) → 自動検出パス (0x50D4)
  else:
      cfg = BootLoaderFlashCfg
      if (cfg & 0x80) cfg &= ~0x80 else cfg = NANDC[0x34]   // 0x80100000+0x34
      if (!(cfg & 1))      → SPI
      else if (cfg & 0x10) → SPI     // 0x9B 系
      else                 → NAND    // 0x83 / 0x8B 系
  ```
  読み出しは種別で SPI 読み(0x8A34)か NAND 読み(0x44C4)に分岐。
- つまり **同一 miniloader が実行時に SPI/NAND どちらからも 2nd loader を読める**。`second_param.txt` のコメントにある「spi 0x9b / nand 0x83」と一致。
- 文字列出力(UART ログ)は見当たらない。

## 3. 「独自 first bootloader を作る」について(できない/勧めない理由)
1. DDR 初期化・鍵処理を担う **0x8E00 以降が暗号化**されており、ROM(未入手)が復号して実行している。DDR コントローラの初期化手順は解読できない。
2. ROM と miniloader の契約(ロードアドレス 0xBC00、検証方式、`0xFFFFF010` の意味)が不明。
3. 実機がなく、誤ると **SPI を外付け書込器で焼き直すまで復旧不能**。
4. 目的(NAND の U-Boot を起動)は、純正 miniloader の設定だけで届く可能性が高い(次節)。

## 4. 現実的な方針: 純正 miniloader + パラメータ変更
- miniloader は SPI に残し、**2nd loader の読み出し先を NAND にする**: `BootLoaderFlashCfg` を NAND 値(例 0x83/0x8B)にし、`Second boot loader flash entry` を NAND 上のオフセットに。
- 未確定: ① ROM が miniloader を SPI から読む条件、② miniloader が NAND の page/cycle をどう決めるか(cfg の bit1–2=ページ長、bit3=アドレスサイクル)、③ fail-safe(safe boot)コピーの置き場。
- **最初にやること**: 純正 SPI をダンプし、`0xB500` 以降のパラメータブロックから実機の DDR 設定(6+2 words)・`BootLoaderFlashCfg`・サイズ/エントリを読む。DDR 設定は推測せず**必ず実機の値を使う**(`miniloader` の ddr コードと param の先頭 word を一致させる)。
- 参考: 現在の U-Boot v2026.07 最小構成は約 190KB で、2nd loader の上限 0x5FF00(384KB)に**収まる**。機能追加で超える場合は `Second boot loader size` と SPI 容量の見直しが必要。

`tools/make_spi_image.sh` は上記パラメータを指定して `mk_nonsec_image` を呼ぶだけの補助スクリプト(未検証)。
