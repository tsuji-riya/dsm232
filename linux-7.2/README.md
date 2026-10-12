# Linux v7.2 for CNC1800L (D-Link DSM-232)

`patches/0001-*.patch` を Linux v7.2 (`v7.2` タグ) に適用する。ビルドは `./build.sh` (要 `gcc-arm-linux-gnueabi`, `u-boot-tools`, `bc flex bison libssl-dev`)。

## 追加内容
| 項目 | 内容 |
|---|---|
| `arch/arm/mach-celestial` | DT_MACHINE_START のみ (`celestial,cnc1800l`) |
| `drivers/irqchip` | 変更なし。BSP の VIC は DW APB ICTL と同一レジスタ配置のため `snps,dw-apb-ictl` を流用 (0x80140000, 32 IRQ) |
| `drivers/clocksource/timer-cnc1800l.c` | AHB timer (0x80270000, IRQ4, 94.5MHz) = clockevent / APB timer (0x801e2000, 47.25MHz) = clocksource+sched_clock |
| UART | `snps,dw-apb-uart` ×2 (0x801f1000 IRQ12 / 0x801f2000 IRQ13), reg-shift 2, io-width 4, 47.25MHz。console は ttyS0 115200 |
| DTS | `arch/arm/boot/dts/celestial/cnc1800l{.dtsi,-dsm232.dts}` |
| defconfig | `cnc1800l_defconfig` (ARM_APPENDED_DTB + ATAG_DTB_COMPAT) |
| メモリ | 0x0–0x08900000 のみ Linux に渡す。それより上はベンダーFWがFB/ビデオ/オーディオ/demux用に使う領域 (`mem_define.h` Tiga-Mini 計算値) |

## 検証状況
- ✅ `zImage` / `dtbs` ビルド成功、`cnc1800l-dsm232.dtb` が dtschema (dt_binding_check / dtbs_check) を通過
- ❌ **実機未検証**。以下は推測を含むため起動しない場合は最初に疑う:
  - CPU が ARM1176JZF-S か (BSP は `CPU_V6` のみ)
  - APB timer は 16bit アクセスのみ安全、という BSP の書き方に合わせてある
  - IRQ ctrl は DW ICTL で FINALSTATUS を読む前提 (BSP の entry-macro.S は未確認)
  - U-Boot (2011.06系) は DTB を渡せないため DTB を zImage 末尾に連結 (`ARM_APPENDED_DTB`)。`bootm` は uImage の load/entry を 0x8000 にしている

## U-Boot からの起動例 (RAM ロード, フラッシュには書かない)
```
tftp 0x2000000 uImage        # or USB/loadb 等
setenv bootargs "earlycon console=ttyS0,115200n8 root=/dev/ram0 rdinit=/init"
bootm 0x2000000
```
(U-Boot 自体が 0x2000000 付近で実行されるため、実際の置き場所は実機の `bdinfo` を見て調整すること)
