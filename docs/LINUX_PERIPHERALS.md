# Linux 側の reboot / USB / Wi-Fi / HDMI 初期化

**状態**: 4 項目とも `./build-usb.sh` は通るが、**実機未検証**。カーネル変更は `linux-7.2/patches/0007`〜`0010`、ユーザーランドは `alpine/build.sh`・`alpine/boot.cmd`。

根拠の出典の略記:
- **BSP** = 純正 Linux 2.6.32 BSP(`crisprelease/buildroot/linux/kernel-patch/linux-1800l-2-6-32.patch` を当てたツリー)
- **U-Boot** = `crisprelease/buildroot/boot/uboot/2011-06/uboot-patch/uboot-2011.06-cavium-beijing.patch`
- **skeleton** = `dlink/wifi/skeleton.tgz`(純正 rootfs の Wi-Fi 部分)

NAND / SPI には何も書かない。read-only の設定もそのまま。

## 1. reboot / poweroff(パッチ 0007)

### 根拠
- BSP `arch/arm/mach-celestial/include/mach/system.h` の `arch_reset()`: 0x801E1000 の WDT に **16bit で** TORR(+0x04/+0x06)=0、CCVR(+0x08/+0x0A)=0、CR(+0x00)=1 を書く。`uboot-2026.07/patches/0001` の `reset_cpu` と同じ手順。
- 電源断: BSP(`mach-celestial`、`drivers/celestial/peripheral`)と U-Boot パッチに `pm_power_off`・standby・電源 GPIO・PMIC 制御は**無い**。フロントパネル制御(FPC)も LED とボタン用。D-Link の `csgpio.c` も GPIO 2 = LED、GPIO 9 = WPS ボタンだけ。**ソフトウェアで電源を切る手段は無い**。

### 変更
- `arch/arm/mach-celestial/cnc1800l.c`: `.restart` に WDT リセットを実装(`.init_machine` で ioremap。restart は割り込み禁止で呼ばれるため、その場で ioremap しない)。setup_arch が `register_restart_handler` に登録する。
- dw_wdt は使わない: 32bit アクセスになり、純正は 16bit で書いているため。
- poweroff: ハンドラが無いと reboot システムコールが POWER_OFF を HALT に読み替える(`kernel/reboot.c`)。そのため `poweroff` は「System halted」で停止する。**電源は切れない**ので、停止後に AC アダプタを抜く。

### 実機確認
| 操作 | 成功 | 失敗時に見るもの |
|---|---|---|
| `reboot` | UART に `reboot: Restarting system` が出て、1 秒以内に純正 U-Boot のバナーが出る | `Reboot failed -- System halted` が出たら WDT が効いていない。U-Boot で `mw.w 0x801e1004 0; mw.w 0x801e1008 0; mw.w 0x801e1000 1` でリセットされるか確認 |
| `poweroff` | `reboot: System halted` で止まる(電源 LED は点いたまま) | カーネル panic(`Attempted to kill init`)が出たら報告 |

## 2. USB(パッチ 0008)

### 根拠
| 項目 | 値 | 出典 |
|---|---|---|
| EHCI | 0x80200000、IRQ 22 | U-Boot `include/configs/cnc1800l.h` `CONFIG_SYS_USB_EHCI_REGS_BASE`、BSP `mach/irqs.h` `IRQ_USB_EHCI` |
| OHCI | 0x80210000、IRQ 27 | BSP `mach/cnc1800l.h` `PA_USB_OHCI_BASE`、`IRQ_USB_OHCI` |
| リセット | クロックブロック 0xB2100200 bit4 を 0→1(100µs) | BSP `ehci-cnc18xx.c` `cnc18xx_start_ehc()` → `clock_usb_reset()` |
| PHY/クロック | 0xB2100218 \|= 3(PHY bypass、「enable and 48MHz」) | 同 `clock_usb1phy_bypassenable()`、`ohci-cnc18xx.c` `cnc18xx_start_hc()`、U-Boot `drivers/usb/host/ehci-cnc18xx.c` `ehci_hcd_init()` |
| U-Boot の後始末 | `usb stop`(bootm の前)で 0xB2100218 = 0 | U-Boot `ehci_hcd_stop()` |

- **EHCI の先頭アドレスの食い違い**: BSP の Linux は `ioremap(0x80200000) + 0x100` を EHCI capability として使い、起動前に `+0x10` に `|= 3` を書く(`usb_hcd_cnc18xx_make_hc()`)。一方 U-Boot は 0x80200000 をそのまま capability として使い、実機で USB 起動できている。0x100 ごとにレジスタが折り返して見えるなら、`+0x110` は USBCMD(RUN|HCRESET)にあたり、標準のリセットと同じ意味になる(推測)。今回は**実績のある U-Boot の値**を使った。
- PHY は bypass ビットを立てるだけで、専用の PHY ドライバは不要。そのため `generic-ehci` / `generic-ohci` で足りる。リセットとビット設定は machine の init(`cnc1800l.c`)で行う。

### 変更
- DTS: `generic-ehci` @0x80200000(IRQ 22)、`generic-ohci` @0x80210000(IRQ 27)。
- `cnc1800l.c`: 上記のリセットパルスと 0x218 の設定。
- defconfig: `USB_EHCI_HCD_PLATFORM`・`USB_OHCI_HCD_PLATFORM`・`USB_STORAGE`・`SCSI`・`BLK_DEV_SD`・`EXT4_FS`・`VFAT_FS`・NLS(cp437 / iso8859-1)。`linux-7.2/build.sh` の必須 CONFIG にも追加。

### 実機確認
起動に使った USB メモリが、Linux からもそのまま見えるはず。
```
dmesg | grep -i -e ehci -e ohci -e 'usb 1-' -e sda
mount /dev/sda1 /mnt && ls /mnt     # uImage uInitrd boot.scr が見えれば成功
```
- 成功: `ehci-platform 80200000.usb: EHCI Host Controller`、`usb 1-1: new high-speed USB device`、`sd 0:0:0:0: [sda]` が出て、マウントできる。
- 失敗時: 上の `dmesg` 全体と `cat /proc/interrupts` を貼ってほしい。
  - EHCI の probe でエラーが出る、または `new high-speed` が出ない場合は、DTS の EHCI を `reg = <0x80200100 0xf00>`(BSP の配置)に変えて比較する。
  - `irq 22: nobody cared` は IRQ 番号の誤りを示す。

### 任意: USB 上の ext4 を rootfs にする
`alpine/build.sh` は initramfs と同じ中身を `out/rootfs.tar.gz` にも出力する。initramfs の `/init` は、カーネル引数に `root=` があればそのデバイスをマウントし、`switch_root` する(失敗したら initramfs のまま起動)。
1. PC で USB メモリにイメージを書いた後、64MB より後ろに第 2 パーティションを作り、ext4 にする(Linux PC の例: `sudo fdisk /dev/sdX` で 2 番を追加 → `sudo mkfs.ext4 /dev/sdX2`)。
2. `sudo mount /dev/sdX2 /mnt && sudo tar -xzpf out/rootfs.tar.gz -C /mnt && sudo umount /mnt`(所有者を root にするため sudo が必要)
3. U-Boot で `setenv extraargs root=/dev/sda2; run bootcmd`(固定するなら `saveenv`。書き換わるのは SPI の環境変数領域だけ)

## 3. Wi-Fi(パッチ 0009)

### 根拠
| 項目 | 値 | 出典 |
|---|---|---|
| SDIO ホスト | 0x80290000(0x1000)、IRQ 18 | BSP `mach-celestial/mshci.c`(`PA_MSHCI_BASE`、`MSHCI_SIZE`)、`mach/irqs.h` `IRQ_SDIO`/`IRQ_MSHCI` |
| ホストの種類 | **DesignWare Mobile Storage Host**(Samsung の呼び名で「MSHCI」)。レジスタ配置 CTRL 0x00 … FIFODAT 0x100 は dw_mmc と同じ | BSP `drivers/mmc/host/mshci.h` |
| カードクロック源 | 47.25MHz 固定(= PCLK) | `mshci-cnc1800l.c` `mshci_cnc1800l_get_max_clk()` |
| 機能 | 4bit、SD/MMC high speed、SDIO IRQ、常時接続 | `mshci.c` `cnc1800l_mshci_platform_data`、`MSHCI_CD_PERMANENT` |
| probe 前の設定 | 0xB2100140(`CLOCK_PLL_CLK_EN`)= 0xFFFFFFFF、0xB2110024(`REG_PINMUX_SDIO`)= 1、100ms 待ち | `mshci-cnc1800l.c` `mshci_cnc1800l_probe()`、`cnc1800l_mux.c` |
| Wi-Fi リセット | **GPIO 10**(High で動作。remove 時に Low) | 同 probe の `CONFIG_CELESTIAL_TIGA_MINI` 部(「GPIO 10 is Wi-Fi reset」) |
| GPIO ブロック | 0x80260000。DR +0x20、DDR +0x24(**1 = 入力**)、入力値 +0x60。ポート B は +0x34/+0x38/+0x64 | BSP `drivers/celestial/peripheral/cnc18xx_gpio.c` `gpio_hw_set_direct()` / `gpio_hw_write()` |
| FIFO | 純正は FIFOTH = 0x20100010(しきい値 16 → 深さ 32)。dw_mmc はリセット値から深さを自動で読む | `mshci.c` `mshci_fifo_init()` |
| チップ | **Atheros AR6003 hw2.1.1**。純正も compat-wireless の `ath6kl.ko` を使用 | skeleton `cavium/start_ath.sh`、`lib/firmware/ath6k/AR6003/hw2.1.1/` |
| board data | `bdata_jp.bin` / `bdata_us.bin` / `bdata_gb.bin`(各 1792 byte)。U-Boot 環境変数 `country` で選ぶ(実機の値は JP) | skeleton `start_ath.sh`、`dump/spi.bin` の環境変数 |
| MAC アドレス | U-Boot 環境変数 `wifiaddr`(実機 `C8:D3:A3:A9:45:8A`)。純正はファームに `softmac` ファイルで渡す | `start_ath.sh`、`dump/spi.bin` |

### 変更
- DTS:
  - GPIO: `wd,mbl-gpio`(汎用 `gpio-mmio`。`dat`=+0x60、`set`=+0x20、`dirin`=+0x24 で逆極性の方向レジスタを表現。ポート A のみ)。
  - SDIO: `snps,dw-mshc`(biu/ciu = PCLK)。設定は 4bit、non-removable、cap-sdio-irq、cap-sd-highspeed、`max-frequency` 25MHz(**推測**)。
  - Wi-Fi の電源: `mmc-pwrseq-simple`(`reset-gpios = <&gpio 10 GPIO_ACTIVE_LOW>`、`post-power-on-delay-ms` 100 は**推測**)。
- `cnc1800l.c`: 純正 probe と同じ 0x140 / ピンマックスの設定。
- defconfig: `NET`・`INET`・`UNIX`・`PACKET`・`CFG80211`・`NETDEVICES`・`ATH6KL_SDIO`・`MMC_DW_PLTFM`・`PWRSEQ_SIMPLE`・`GPIO_GENERIC_PLATFORM`(Ethernet ドライバ群は無効)。
- Alpine(`alpine/build.sh`): ビルドマシン用の `apk.static` で armhf の `wpa_supplicant`・`iw`・`wireless-regdb`・`linux-firmware-ath6k` を initramfs に入れる(署名はミニ rootfs の鍵で検証、armhf のスクリプトは実行しない)。ファームは AR6003/hw2.1.1 だけ残す(Alpine のファームは zstd 圧縮なので、カーネルに `FW_LOADER_COMPRESS_ZSTD` を入れた)。
- board data:
  - 純正の `bdata_*.bin` には**ライセンス表記が無いため、リポジトリには入れない**。
  - 使う場合は `alpine/bdata.bin` に置いてビルドする(`.gitignore` 済み)。例: `tar -xzf <GPL>/ott/dlink/wifi/skeleton.tgz -O skeleton/lib/firmware/ath6k/AR6003/hw2.1.1/bdata_jp.bin > alpine/bdata.bin`
  - 置かない場合、ath6kl は linux-firmware の汎用 `bdata.SD31.bin` を使う。動作はするはずだが、送信出力の校正と規制ドメインは純正と異なる。
  - NAND の data パーティションから取り出す必要はない(GPL 同梱で足りる。実機の純正ファームが同じ bdata を使っているかは未確認)。

### 実機確認
```
dmesg | grep -i -e mmc -e dw_mmc -e ath6kl
iw dev                                   # wlan0 が出れば認識成功
ip link set wlan0 up
iw dev wlan0 scan | grep SSID            # 周囲の AP が出ればスキャン成功
wpa_passphrase 'SSID' 'パスフレーズ' > /etc/wpa_supplicant.conf
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
udhcpc -i wlan0
ping -c 3 1.1.1.1
```
- 成功の目安:
  - dmesg に `mmc0: new high speed SDIO card at address 0001` と `ath6kl: ar6003 hw 2.1.1 sdio fw ...` が出る。
  - `iw dev` に wlan0 が出て、スキャン結果に AP が並ぶ。
  - `udhcpc` が `lease of ... obtained` を出す。
- MAC アドレスを純正と同じにする場合: U-Boot の `printenv wifiaddr` の値を使い、`ip link set wlan0 down; ip link set wlan0 address C8:D3:A3:A9:45:8A`。mainline の ath6kl には純正の `softmac` 相当が無い。
- 失敗時に見るもの:
  - `new ... SDIO card` が出ない(`mmc0: error -110` やタイムアウト): リセット GPIO・クロック・ピンマックスを疑う。`mount -t debugfs none /sys/kernel/debug; cat /sys/kernel/debug/gpio` と、dmesg の dw_mmc の行(`Version ID`、`FIFO depth`、`Using internal DMA controller`)を貼ってほしい。
  - ath6kl がファーム読み込みや BMI のエラーを出す: その行と `ls /lib/firmware/ath6k/AR6003/hw2.1.1/` を貼ってほしい。

## 4. HDMI を Linux 側で初期化(パッチ 0010)

### 根拠
`logo 16 2 …` で純正 U-Boot が行う処理を、同じ順序と値で再現した。

| 段階 | 出典 | 内容 |
|---|---|---|
| クロック | U-Boot `board/cavium/cnc1800l/power_clock.c` `clock_dispset_clockmoderaw(disp0, _YUV_1080P_60Hz, _tve_pll)` | 0x140 &= ~0x50 → TVE PLL sleep(0x20C bit1→bit0)→ 0x200 bit13 クリア → 0x108 = `0x8000 \| fb 21 << 8 \| m 2`(`disp_pll_cfg[]` の 148.5MHz 行)→ PLL wake → 0x148 下位 16bit = 0x2242(HdmiTmds 2 / Disp 2 / TveClk6 4 / TveClk0 2)→ 0x200 bit13 セット → 0x140 \|= 0x50 |
| (同) | `clock_disp_reset()` | 条件が `(_disp1) ? …` と定数になっている純正のバグで、disp0 でも bit13 を操作する。トレースでも bit13 なので、同じにした |
| (同) | `clock_hdmiset_clockmode()` | TMDS クロックを一度止めて同じ分周値を書き直すだけなので省略 |
| TVE | U-Boot `drivers/cnc1800l/df/df.c` `InitTVE0Raw()` | **1080p 系では何もせず return**。HDMI 経路には関係しない |
| DF 出力 | 同 `DFSetOutIFVideoFmt()`、`df_reg_fmt.h` のビットフィールド | 0x340 = 0x4405(DispEn / IsHD / DownMode / DitherEna)、0x344 = 1920 / 2200、0x348 = 1080 / 1125、0x34C = HBP 148 / HSW 44 / HFP 88、0x350 = VBP 36 / VSW 5 / VFP 4、0x354 = VGA レベル(white 800 / black 252) |
| DF GFX0 | 同 `CS_LoadDisplay()` | 0x44 = 2(RGB565)、0x58 = 0x0C000000、0x5C = 3840、0x60 = 1919 << 16、0x64 = 1080 << 16、0x48 = 0x3FF、0x4C〜0x54 = 0、0x40 = 0x49(enable / color key / RGB→YUV) |
| HDMI リセット | `hdmi.bin` が jump table 46 で呼ぶ `clock_hdmi_reset()`(U-Boot `include/_exports.h` で `memset` の直後) | 0x200 bit19 を 0→1。間の待ち 10µs は**推測** |
| HDMI TX | `hdmi.bin`(バイナリのみ)の mode 16 書き込み列(`tools/display_emu/run.sh 16` → `trace16.txt`) | 下表 |

HDMI TX(0x72 ページ = 0x80400000 + reg×4、AV ページ = 0x80400400 + reg×4。名前は omapdrm `hdmi4_core.h`):

| 順 | レジスタ | 値 | 意味 |
|---|---|---|---|
| 1 | 72:08 SYS_CTRL1 | 0x31 | 電源投入。bit4/5 = HEN/VEN(HSYNC/VSYNC を取り込む)は残す(下の「実機ダンプ」) |
| 2 | 72:4B–4D VID_BLANK | 80 10 80 | ブランキング = YCbCr の黒 |
| 3 | 72:82 TMDS_CTRL | 0x25 | 純正値 |
| 4 | AV:2F HDMI_CTRL | 0x01 | HDMI モード(DVI ではない) |
| 5 | 72:33 DE_CTRL / 72:4A VID_MODE | 0 / 0 | 変換なし(`hdmi.bin` の最終値。1 回目は VID_MODE=0x27 だが 2 回目で 0) |
| 6 | 72:08 / 72:48 / 72:49 / 72:08 | 0x35 / 0 / 0x40 / 0x37 | 純正の順序。0x37 は実機で `logo` 後に読んだ値 |
| 7 | 72:05 SRST | 0x03 → 0 | ソフトリセットと FIFO リセット |
| 8 | 72:0F HDCP_CTRL | 0 | 暗号化なし |
| 9 | AV:3E PB_CTRL1 → AV:40–50 → AV:3E | 0 → AVI → 0x03 | AVI InfoFrame(VIC 16、BT.709、16:9、YCbCr444、アンダースキャン、IT コンテンツ)。チェックサムはコードで計算(= 0xE5、boot.cmd と同じ) |
| 10 | AV:DF CP_BYTE1 / AV:3F PB_CTRL2 | 0x10 / 0x0C | AVMUTE 解除の GCP を毎フレーム送る |

`hdmi.bin` から**省いたもの**:
- DDC による EDID 読み出し(72:ED–F5)
- オーディオ(ACR N=6144、AV:14 AUD_MODE、I2S 設定、Audio InfoFrame AV:80–8D)
- 割り込み設定(72:71/75/79)
- DCTL の一時的な書き換え
- HDCP 認証
- 2 パス目の重複した書き込み

### 変更
- `arch/arm/mach-celestial/cnc1800l-display.c`(新規): `init_machine` から呼ぶ。
  1. 0x0C000000 の 1920×1080×2 byte を 0 クリア
  2. クロック → DF → HDMI TX の順に設定
  3. `cnc1800l-display: HDMI 1920x1080p60, RGB565 at 0xc000000` を出力
- フレームバッファは従来どおり DTS の `simple-framebuffer` と fbcon を使う。DRM 化はしていない。
- カーネル引数 `cnc1800l_display.skip=1` を付けると何もせず、U-Boot の設定を残す。
- `alpine/boot.cmd`:
  - **既定では `logo` を実行しない**(Linux が初期化する)。
  - `setenv hdmi uboot` で従来の `logo` + AVI 修正 + `hdcpoff` の経路になり、`cnc1800l_display.skip=1` を渡す。`hdmimode` はこの経路だけで有効。
  - 全プリセット(なし / `hdmi=uboot` / `+hdmimode=14,15,7` / `+hdcpoff=1` / `extraargs=...`)で、`tools/display_emu/run_script.py` によりコマンドと bootargs を確認済み。
- `tools/display_emu/run_logo.py`: jump table 46 のラベルを `clock_hdmi_reset` に訂正。

### 実機確認
1. 新しい `boot.scr` でそのまま起動する(`logo` は走らない)。
   - 成功: UART に `cnc1800l-display: HDMI 1920x1080p60, RGB565 at 0xc000000` と `simple-framebuffer ... fb0` が出る。テレビに tty1 の `login:` が表示され、ちらつかない。テレビの入力情報が 1920×1080p / 60Hz。
2. 比較用(U-Boot 経路): `setenv hdmi uboot; run bootcmd`
3. 映らない、または色や同期がおかしい場合は、カーネル引数 `cnc1800l_display.dump=1` で表示関係のレジスタ(クロック 0xB2100100–0x21F、ピンマックス 0xB2110000–0x2F、DF 0xB1800000–0x9F と 0x300–0x35F、HDMI TX 2 ページ)を UART に出し、両方の経路で比べる(Alpine の busybox には `devmem` が無い)。
   ```
   setenv extraargs cnc1800l_display.dump=1
   usb start; fatload usb 0:1 0x6000000 boot.scr; source 0x6000000
   ```
   - Linux 経路: `before` = U-Boot プロンプト時点(`logo` 未実行)の実機の値、`after` = 初期化後。
   - `setenv hdmi uboot` を足すと `before` が `logo` 実行後(映る状態)になる。
   - `setenv hdmi uboot; setenv extraargs cnc1800l_display.dump=1 cnc1800l_display.skip=0` は、映っている状態の上から Linux の初期化をかける(後の `skip=0` が優先)。これで映像が消えるかどうかで、書いている値が悪いのか、足りない手順があるのかを切り分けられる。
   - HDMI TX の 0x80400024(SYS_STAT): bit0 = 入力クロック安定、bit1 = HPD、bit2 = 受信側の終端検出(SiI の定義)。

### 実機ダンプでの修正(`cnc1800l_display.dump=1`)
最初の版は「初期化は完了と表示されるが映らない」状態だった。`logo` 後(映る)と Linux 初期化後(映らない)のダンプを比べた結果、クロックと DF のタイミングは一致し、違いは次の 2 点だった。
- **72:08 SYS_CTRL1**: 映る状態は `0x37`、旧版は `0x07`。HEN/VEN が落ちていて、TX が測った入力の総画素数・総ライン数(72:3A–3D)が 0 になっていた(映る状態では 2200×1125)。エミュレータが 0 を読ませていたため、`hdmi.bin` の RMW が残すビットを再現できていなかった。
- **DF 0x44**: 映る状態は `0x12`(RGB565 + AlphaIsValid)、旧版は `0x02`。

残りの差は HDCP(72:0F、BKSV、Ri)、音声(AV:01–24、Audio InfoFrame)、割り込みマスク、DDC だけで、映像には関係しない想定。

### 黒画面の切り分け(進行中)
SYS_CTRL1 を直した後、テレビは 1080p60 で同期するようになったが、画面は真っ黒のまま。
- `logo` で映っている状態の上から Linux の初期化をかけても黒くなる。この操作で値が変わるのは、HDMI TX の HDCP(72:0F 0x4F→0)、音声、72:CC(0x0F→0x01)だけだった。
- `hdcpoff=1` の試験では、`hdmi.bin` の HDCP 認証が失敗した回に、`hdmi.bin` 自身が SYS_CTRL1 を 0x36(PD#=0、電源断)にしていた。純正は HDCP が通らないと出力を止める作りと見られる。
- `steps` で切り分けた結果(`logo` で映っている状態の上から実行): DF だけ = 映る。HDMI TX のレジスタだけ = 黒。
- U-Boot で `logo` を実行し、上半分を赤く塗った後に 1 か所ずつ書き換えた結果: HDCP_CTRL=0 で黒になった。SRST パルスでは色化けし(暗号化中のリセット)、Audio InfoFrame を止めても変化はなかった。
- HDCP_CTRL=0x04(HDCP ブロックはリセット解除、暗号化なし)でも黒だった。**送信部は HDCP で暗号化していないと映像の代わりにブランク色を出す**と判断した。純正 Linux ドライバ `SiITX.c` `siiTX_HDMI_Init()` にも「set the default output color to black when HDCP authentication not success」とある。
- そこで HDCP 1.x 認証を実装した(`steps` の bit4)。純正 `SiITXHDCP.c` `siiTXHDCP_Authentication()` と同じ手順で、次の順に処理する。**未検証**。
  1. DDC マスタ(72:ED–F5)で受信側の BKSV を読み、1 と 0 が 20 個ずつあるか確認する
  2. CP_RESETN を立て、BCAPS で受信側がリピータかを見る
  3. AN を生成して受信側に書き、送信部の AKSV も受信側に書く
  4. 150ms 待ってから、BKSV を送信部に書く(R0 の計算が始まる)
  5. R0 を照合して一致すれば ENC_EN を立てる。前後は AVMUTE で挟む
  - HDCP 鍵は送信部が内蔵している(AKSV がコールド状態でも読める)。
  - リピータ用の第 2 段階(SHA)と、Ri によるリンク監視は実装していない。そのため、テレビを挿し直すと黒に戻る。
- 最初の版は起動処理の中で 1 回だけ認証し、`-22`(当時は BKSV 不正もこの番号)で失敗した。純正 U-Boot でも、最初の数回は `DDC Time Out` → `No HDCP Dev` で失敗してから認証が通る。そこで、起動処理とは別に 1 秒おき・最大 30 回まで再試行するようにした。
- UART に `cnc1800l-display: HDCP authenticated (try N)` が出れば認証成功。`HDCP authentication failed (エラー番号)` の番号の意味は次のとおり。
  - -19: HPD なし
  - -5: DDC 失敗
  - -6: 受信側の BKSV が不正(1 の数が 20 個でない)
  - -22: 送信部が BKSV エラーを返した
  - -13: R0 不一致
- 原因の段階を特定するため、`cnc1800l_display.steps=<ビットマスク>` で一部の段階だけを実行できるようにした。bit0 = クロック、bit1 = DF、bit2 = HDMI ブロックのリセット、bit3 = HDMI TX のレジスタ、bit4 = HDCP 認証。既定は 0x1F(全段階)。

### 未確認・限界
- エミュレータは未知のレジスタを 0 として読むため、read-modify-write の結果は「リセット値が 0」と仮定したものになっている。DF と HDMI の書き込みは、その結果の値をそのまま書いている。
- HDMI のリセットパルスで HDMI TX のレジスタが初期値に戻る前提で、純正が書く値だけを書いている。
- EDID・ホットプラグ・音声には対応していない。テレビを挿し直すと映像が止まる可能性がある。
