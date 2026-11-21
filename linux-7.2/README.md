# Linux v7.2 for CNC1800L (D-Link DSM-232)

`patches/0001`〜`0028` を順に Linux v7.2 (`v7.2` タグ) に適用する。ビルドは `./build.sh` (要 `gcc-arm-linux-gnueabi`, `u-boot-tools`, `bc flex bison libssl-dev`)。

upstream の形式に合わせて、DT バインディング・ドライバ・DTS・defconfig を別のパッチにしている。新しいファイルは `MAINTAINERS` の `ARM/CELESTIAL CNC1800L SOC SUPPORT` に載せる。

## 追加内容
| パッチ | 内容 |
|---|---|
| 0001–0003 | DT バインディング: ベンダープレフィックス `celestial`、ボード(`dlink,dsm-232-a1`)、タイマー |
| 0004 | `timer-cnc1800l.c`(AHB timer 0x80270000 IRQ4 94.5MHz = clockevent / APB timer 0x801e2000 47.25MHz = clocksource+sched_clock) |
| 0005 | `arch/arm/mach-celestial/Kconfig`(C コードなし、汎用 DT マシン) |
| 0006–0007 | クロック(`clk-cnc1800l.c`: 表示 PLL・分周・クロック有効ビット・USB PHY)のバインディングとドライバ |
| 0008–0009 | GPIO(`gpio-cnc1800l.c`、41 本、レベル割り込み + エッジの代用)のバインディングとドライバ |
| 0010 | DTS: 割り込み `snps,dw-apb-ictl`(0x80140000)、UART `snps,dw-apb-uart` ×2(ttyS0 115200)、タイマー、`mem=137M` |
| 0011 | spi-dw の全レジスタを `reg-io-width` で 16bit アクセス |
| 0012–0013 | CNC1800L NAND コントローラ(旧=HW Hamming互換 / 新=標準 soft ECC を DT で切替)のバインディングとドライバ |
| 0014 | DTS: NAND と DW SSI + spi-nor(mode 3、read-only)。DTS は旧 `cnc1800l-dsm232.dts` / 新 `cnc1800l-dsm232-newecc.dts`。詳細は `docs/FLASH_SUPPORT.md` |
| 0015–0016 | DTS: GPIO、クロック、リセット(`reset-simple`)、ピンマックス(`pinctrl-single`) |
| 0017 | DTS: ウォッチドッグと reboot(`dw_wdt`) |
| 0018 | DTS: USB(`generic-ehci` 0x80200000 IRQ22 + `generic-ohci` 0x80210000 IRQ27) |
| 0019 | DTS: SDIO(`snps,dw-mshc` 0x80290000 IRQ18)と AR6003 Wi-Fi(`ath6kl_sdio` + `mmc-pwrseq-simple` GPIO10) |
| 0020–0022 | HDMI(DRM `drivers/gpu/drm/tiny/cnc1800l.c`: EDID・モード切替・HDCP・ホットプラグ・CEC)のバインディング・ドライバ・DTS |
| 0023 | DTS: LED(GPIO2)、ボタン(GPIO9 = `KEY_PROG1`) |
| 0024–0025 | nvmem の U-Boot env レイアウトで `wifiaddr` も MAC アドレスとして読む |
| 0026 | ath6kl: DT の MAC アドレス(nvmem セル可)を OTP 実行後の AR6003 board data に書く |
| 0027 | DTS: SPI の U-Boot env(0xc000、8KiB)を nvmem レイアウトとして公開し、Wi-Fi の MAC に `wifiaddr` を使う |
| 0028 | `cnc1800l_defconfig`(ARM_APPENDED_DTB + ATAG_DTB_COMPAT、USB メモリ/ext4/vfat、Wi-Fi、HDMI コンソール、kexec) |

メモリは 0x0–0x08900000 のみ Linux に渡す。それより上はベンダーFWがFB/ビデオ/オーディオ/demux用に使う領域 (`mem_define.h` Tiga-Mini 計算値)。詳細は `docs/LINUX_PERIPHERALS.md`。

## 検証状況
- ✅ `zImage` / `dtbs` ビルド成功、`cnc1800l-dsm232.dtb` が dtschema (dt_binding_check / dtbs_check) を通過
- ✅ 実機で起動し、HDMI コンソール・USB・Wi-Fi・reboot が動く(詳細と未検証項目は `docs/LINUX_PERIPHERALS.md`)
- U-Boot (2011.06系) は DTB を渡せないため DTB を zImage 末尾に連結 (`ARM_APPENDED_DTB`)。`bootm` は uImage の load/entry を 0x8000 にしている

## U-Boot からの起動例 (RAM ロード, フラッシュには書かない)
```
tftp 0x2000000 uImage        # or USB/loadb 等
setenv bootargs "earlycon console=ttyS0,115200n8 root=/dev/ram0 rdinit=/init"
bootm 0x2000000
```
(U-Boot 自体が 0x2000000 付近で実行されるため、実際の置き場所は実機の `bdinfo` を見て調整すること)
