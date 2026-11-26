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

## 純正 U-Boot から USB 経由で RAM 起動する(未実施)
SPI/NAND に書かずに試す方法。純正 U-Boot(`dlink_U-Boot 2011.06`)の `usb`・`fatload`・`go` で、USB の FAT 第 1 パーティションに置いた `u-boot.bin` を RAM に読んでジャンプする。

```
usb start
fatload usb 0:1 0x2000000 u-boot.bin
dcache off
icache off
go 0x2000000
```

本 U-Boot も純正も 0x02000000 にリンクされているが、純正は起動時に RAM 上部へリロケーションするので、0x02000000 に読んでも実行中の純正を上書きしない。根拠は `dump/nand.bin` の 0x20000(純正 U-Boot)の逆アセンブル:

| 箇所 | 内容 |
|---|---|
| `dram_init`(0x02037ce4) | `get_ram_size(0, 0x10000000)` で容量を検出 |
| `board_init_f`(0x020007d0〜0x02000804) | relocaddr = ((容量 − 32MB − 16KB) を 64KB 切り下げ − 0x192a9c)を 4KB 切り下げ。その下に malloc(約 12MB)とスタック |
| `start.S`(0x020000d4〜0x02000168) | 現在地 ≠ relocaddr ならコピーと `R_ARM_RELATIVE`/`R_ARM_ABS32` の再配置を行う |

容量 256MB なら relocaddr = 0x0DE5D000(純正の使用域は概ね 0x0D25xxxx〜0x0DFFxxxx)。256MB は仮説(FB の 0x0C000000 が使えているので 192MB 以上は確実)で、実機の `bdinfo` の `relocaddr` で確認すること。128MB だった場合は 0x05E5D000 になり、0x02000000 とは衝突しないが `alpine/boot.cmd` の uInitrd 領域(0x5000000〜)と重なる。

`dcache off` は必須。純正の `bootcmd` は `dcache on` を実行しており、2011.06 の `go` はキャッシュを片付けずにジャンプするため、本 U-Boot(キャッシュ OFF 前提)が古いデータを見る恐れがある。
