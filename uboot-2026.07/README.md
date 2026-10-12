# U-Boot v2026.07 for CNC1800L (D-Link DSM-232)

`patches/0001-*.patch`(+ `0002`)を U-Boot `v2026.07` タグに適用する。`./build.sh`(要 `gcc-arm-linux-gnueabi`, `bison flex libssl-dev`)で `u-boot.bin` ができる(約 190KB)。

## 内容
| 項目 | 内容 |
|---|---|
| CPU/アーキ | `ARCH_CELESTIAL` + `CPU_ARM1176`(`arch/arm/mach-celestial`) |
| ボード | `board/dlink/dsm232`, `include/configs/dsm232.h`, `configs/dsm232_defconfig` |
| 実行アドレス | `TEXT_BASE=0x02000000`(純正 `second_param.txt` の 2nd boot loader 実行エントリと同じ)。初期 SP は 0x01fff000。サイズ上限 0x5FF00(約 393KB)に対し約 190KB |
| コンソール | `snps,dw-apb-uart` を ns16550 ドライバで使用(0x801f1000, reg-shift 2, io-width 4, 47.25MHz, 115200) |
| タイマ | `drivers/timer/cnc1800l-timer.c`(APB timer 0x801e2000、16bit アクセス、down→up 変換) |
| リセット | WDT(0x801e1000)で `reset_cpu`(純正パッチと同じ手順) |
| メモリ | DT は 256MB。U-Boot の再配置上限は 0x08900000(Linux 側 DTS と同じ。上はベンダー FW の FB/ビデオ領域) |
| NAND/SPI | `patches/0002-*`: NAND ドライバ(旧=HW Hamming互換 / 新=標準soft BCH を DT で切替)、`designware_spi` 16bit 対応、`sf`/`nand`/`mtd` コマンド。`dsm232_defconfig`(旧)/`dsm232_newecc_defconfig`(新)。約 347KB。詳細は `docs/FLASH_SUPPORT.md` |
| 無効化 | キャッシュ(I/D)は初回ブリングアップのため OFF。ネットワーク/USB/HDMI は未実装 |

DDR・PLL・ピンマックスは **ベンダー miniloader(バイナリ)** が初期化済みの前提で、`lowlevel_init` は空。

## 検証状況
- ✅ `u-boot.bin` ビルド成功、`ns16550_serial_probe` / `cnc1800l_timer` / `reset_cpu` がリンクされていることを確認
- ❌ **実機未検証**。以下は推測:
  - miniloader から本 U-Boot へジャンプする時点の CPU 状態(MMU/キャッシュ/モード)
  - UART の分周クロックが 47.25MHz のままであること(U-Boot は 115200 に再設定する)
  - ここでは 256MB 全域を DT に書いているが、実 DRAM 容量が 256MB か未確認

## 実機へ入れる(未実施・要注意)
`u-boot.bin` 単体は書き込めない。純正の `signing_tool/mk_nonsec_image`(i386 バイナリ)で miniloader と `second_param.txt` から `flash.img` を作り、SPI フラッシュに書く方式。miniloader は DDR 周波数・容量・NAND ページサイズ別のバイナリから実機に合う 1 つを選ぶ必要がある。
**SPI の U-Boot 領域を誤って書くと UART 無しでは復旧不能**。まず UART を接続し、純正 U-Boot で SPI/NAND をバックアップしてから、可能なら RAM ロード(`loadb` + `go 0x2000000`)で本 U-Boot を試すこと。
