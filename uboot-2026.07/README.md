# U-Boot v2026.07 for CNC1800L (D-Link DSM-232)

`patches/0001-*.patch`(+ `0002`)を U-Boot `v2026.07` タグに適用する。`./build.sh`(要 `gcc-arm-linux-gnueabi`, `bison flex libssl-dev`)で `u-boot.bin` ができる(約 343KB)。

## 内容
| 項目 | 内容 |
|---|---|
| CPU/アーキ | `ARCH_CELESTIAL` + `CPU_ARM1176`(`arch/arm/mach-celestial`) |
| ボード | `board/dlink/dsm232`, `include/configs/dsm232.h`, `configs/dsm232_defconfig` |
| 実行アドレス | `TEXT_BASE=0x02000000`(純正 `second_param.txt` の 2nd boot loader 実行エントリと同じ)。初期 SP は 0x01fff000。サイズ上限 0x7FF00(523,008 byte、実機 SPI の miniloader パラメータ値。`CONFIG_BOARD_SIZE_LIMIT` でビルド時に検査)に対し約 343KB |
| コンソール | `snps,dw-apb-uart` を ns16550 ドライバで使用(0x801f1000, reg-shift 2, io-width 4, 47.25MHz, 115200) |
| タイマ | `drivers/timer/cnc1800l-timer.c`(APB timer 0x801e2000、16bit アクセス、down→up 変換) |
| リセット | WDT(0x801e1000)で `reset_cpu`(純正パッチと同じ手順) |
| メモリ | DT は 256MB。U-Boot の再配置上限は 0x08900000(Linux 側 DTS と同じ。上はベンダー FW の FB/ビデオ領域) |
| NAND/SPI | `patches/0002-*`: NAND ドライバ(旧=HW Hamming互換 / 新=標準soft BCH を DT で切替)、`designware_spi` 16bit 対応、`sf`/`nand`/`mtd` コマンド。`dsm232_defconfig`(旧)/`dsm232_newecc_defconfig`(新)。SPI は mode 3 / 12MHz(Linux で実機確認した値)。旧方式では on-flash BBT を使わない(純正 BBT を認識できず probe 時に新しい BBT を書いてしまうため。Linux 側と同じ方針)。mtdparts は実機 128MiB の配置。詳細は `docs/FLASH_SUPPORT.md` |
| env | 純正と同じ SPI 0xC000、8KiB、CRC32(冗長フラグなし)。純正の env(`wifiaddr` 等)をそのまま読める。`saveenv` が消すのは 0xC000–0xDFFF のみ |
| キャッシュ | I/D とも ON(純正 U-Boot も `bootcmd` で `dcache on` している)。切り分け時は `dcache off` |
| 未実装 | ネットワーク/USB/HDMI |

DDR・PLL・ピンマックスは **ベンダー miniloader(バイナリ)** が初期化済みの前提で、`lowlevel_init` は空。

## 検証状況
- ✅ `u-boot.bin` ビルド成功、`ns16550_serial_probe` / `cnc1800l_timer` / `reset_cpu` がリンクされていることを確認
- ❌ **実機未検証**。以下は推測:
  - miniloader から本 U-Boot へジャンプする時点の CPU 状態(MMU/キャッシュ/モード)
  - UART の分周クロックが 47.25MHz のままであること(U-Boot は 115200 に再設定する)
  - ここでは 256MB 全域を DT に書いているが、実 DRAM 容量が 256MB か未確認

## ダンプから分かった実機の配置
`dump/spi.bin` / `dump/nand.bin` の解析結果(GPL の `second_param.txt` とは値が違う):

| 項目 | 実機の値 | 根拠 |
|---|---|---|
| 2nd loader の格納先 | **NAND** 0x20000(`BootLoaderFlashCfg`=0x8B=NAND)。同一内容の 2 つ目が NAND 0xA0000 | SPI 0xB500 のパラメータブロック、NAND ダンプ |
| 2nd loader の最大長 | 0x7FF00(GPL は 0x5FF00) | 同上 |
| 署名 | スロット = 本体 0x7FF00(0x00 詰め)+ RSA-2048 PKCS#1 v1.5 SHA-256 署名 256 byte。公開鍵の modulus は SPI 0x480(e=65537) | `tools/uboot_slot.py check dump/spi.bin dump/nand.bin` で両スロットとも検証が通る |
| SPI の内容 | miniloader(0x0–0xBBFF、パラメータ・署名込み)+ env 0xC000。0x10000 以降は工場出荷時(FW1.01)の写しで、現行と env だけが違う | SPI ダンプ |

つまり **U-Boot の差し替えに SPI の書き込みも `mk_nonsec_image` も要らない**。NAND 0x20000 のスロットを、旧方式 ECC(HW Hamming 互換)で書き換えるだけでよい。ただし miniloader が署名を検証している可能性が高く(仮説。署名の存在は確認済みだが、検証を省略するかは未確認)、署名には実機の鍵に対応する秘密鍵が要る。GPL の `signing_tool/insecure_key.pem` がその鍵かは未確認で、`openssl rsa -in insecure_key.pem -noout -modulus` と SPI 0x480 の 256 byte を比べれば確かめられる。`tools/uboot_slot.py sign` は、署名結果が SPI ダンプの鍵で検証できない限りファイルを出力しない。

## 実機へ入れる(未実施・要注意)
1. UART を接続し、純正 U-Boot で SPI/NAND をバックアップする。
2. まず RAM ロード(`loadb` + `go 0x2000000`)で本 U-Boot を試す。フラッシュは書かない。
3. 鍵が一致した場合のみ `python3 tools/uboot_slot.py sign dump/spi.bin u-boot.bin insecure_key.pem slot.bin` を作り、**NAND 0x20000 のスロットだけ**を書く。0xA0000 の純正コピーは残す(miniloader のパラメータは dual boot=0 なので、0xA0000 へ自動で切り替わるかは未確認)。
**NAND 0x20000 を壊すと UART 無しでは復旧不能**。SPI(miniloader)は触らない。
