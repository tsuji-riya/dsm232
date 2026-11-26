# Linux 側の周辺機能(reboot / USB / Wi-Fi / HDMI / GPIO / CEC)

**状態**: カーネル変更は `linux-7.2/patches/0006`〜`0028`、ユーザーランドは `alpine/build.sh`・`alpine/boot.cmd`。実機で確認できたものは次のとおり。
- HDMI(2026-11-20、DRM ドライバ): EDID を読み、1080p60 / 1080p50 / 720p60 / 480p / 1024x768 と、XRGB8888 / RGB565 のカラーバーが正しい色で出た。HDCP 認証は毎回 1〜2 回目で成功。
- HDMI ホットプラグ: ケーブルの抜き差しとテレビの入力切り替えのどちらでも、画面が戻った(2026-11-01、旧実装。DRM ドライバは同じ処理)。
- USB: 起動に使った USB メモリが `sda` として認識され、ext4 root で起動した。
- Wi-Fi: ath6kl が AR6003 hw2.1.1 のファーム 3.2.0.144 を読み込み、`wpa_supplicant` + `udhcpc` で DHCP のアドレスを取得し、インターネットへの ping が通った。MAC は U-Boot env の `wifiaddr` になる(2026-11-20、パッチ 0024〜0027)。
  - `rfkill: Cannot open RFKILL control device` は、カーネルが RFKILL 無しでビルドされているため出るだけで、無害。
  - ping の遅延が 27〜322ms とばらついたが、`iw dev wlan0 set power_save off` で 20ms 台に安定した。そのため、カーネルの既定を省電力なしにした。
- reboot(dw_wdt 経由)/ poweroff: `reboot` で再起動し、`poweroff` で停止した。
- ボタン(GPIO 割り込み): 押すたびに `KEY_PROG1` の 1 / 0 が出た。LED は点灯。
- SSH(dropbear)、起動時の Wi-Fi 自動接続と NTP。
- NAND / SPI-NOR: 読み出しのみ確認(詳細は [FLASH_SUPPORT.md](FLASH_SUPPORT.md))。
- CEC: 送信と「ACK なし」の検出は動く。CEC 対応のテレビが無く(PC モニターは CEC 非対応)、相手との通信は**未検証**。

根拠の出典の略記:
- **BSP** = 純正 Linux 2.6.32 BSP(`crisprelease/buildroot/linux/kernel-patch/linux-1800l-2-6-32.patch` を当てたツリー)
- **U-Boot** = `crisprelease/buildroot/boot/uboot/2011-06/uboot-patch/uboot-2011.06-cavium-beijing.patch`
- **skeleton** = `dlink/wifi/skeleton.tgz`(純正 rootfs の Wi-Fi 部分)

NAND / SPI には何も書かない。read-only の設定もそのまま。

## 1. reboot / poweroff(パッチ 0017)

### 根拠
- BSP `arch/arm/mach-celestial/include/mach/system.h` の `arch_reset()`: 0x801E1000 の WDT に **16bit で** TORR(+0x04/+0x06)=0、CCVR(+0x08/+0x0A)=0、CR(+0x00)=1 を書く。`uboot-2026.07/patches/0001` の `reset_cpu` と同じ手順。
- BSP `drivers/celestial/peripheral/cnc18xx_wdt.c`(`/dev/watchdog`)は同じ WDT を **32bit で**アクセスする(TORR、CRR = 0x76、CR = 0x1f)。
- 電源断: BSP(`mach-celestial`、`drivers/celestial/peripheral`)と U-Boot パッチに `pm_power_off`・standby・電源 GPIO・PMIC 制御は**無い**。フロントパネル制御(FPC)も LED とボタン用。D-Link の `csgpio.c` も GPIO 2 = LED、GPIO 9 = ボタンだけ。**ソフトウェアで電源を切る手段は無い**。

### 変更
- DTS: `snps,dw-wdt`(clocks = PCLK)。mainline の `dw_wdt` が `/dev/watchdog` と restart ハンドラを出す(machine のコードは無い)。
- 32bit の読み出しは上位 16bit が 0 になる(COMP_VERSION が `0x322A`)。使うレジスタの値は 16bit に収まるので、残り時間の表示以外には影響しない。
- poweroff: ハンドラが無いと reboot システムコールが POWER_OFF を HALT に読み替える(`kernel/reboot.c`)。そのため `poweroff` は「System halted」で停止する。**電源は切れない**ので、停止後に AC アダプタを抜く。

### 実機確認
| 操作 | 成功 | 失敗時に見るもの |
|---|---|---|
| `reboot` | UART に `reboot: Restarting system` が出て、1 秒以内に純正 U-Boot のバナーが出る | `Reboot failed -- System halted` が出たら WDT が効いていない。U-Boot で `mw.w 0x801e1004 0; mw.w 0x801e1008 0; mw.w 0x801e1000 1` でリセットされるか確認 |
| `poweroff` | `reboot: System halted` で止まる(電源 LED は点いたまま) | カーネル panic(`Attempted to kill init`)が出たら報告 |

## 2. USB(パッチ 0018)

### 根拠
| 項目 | 値 | 出典 |
|---|---|---|
| EHCI | 0x80200000、IRQ 22 | U-Boot `include/configs/cnc1800l.h` `CONFIG_SYS_USB_EHCI_REGS_BASE`、BSP `mach/irqs.h` `IRQ_USB_EHCI` |
| OHCI | 0x80210000、IRQ 27 | BSP `mach/cnc1800l.h` `PA_USB_OHCI_BASE`、`IRQ_USB_OHCI` |
| リセット | クロックブロック 0xB2100200 bit4 を 0→1(100µs) | BSP `ehci-cnc18xx.c` `cnc18xx_start_ehc()` → `clock_usb_reset()` |
| PHY/クロック | 0xB2100218 \|= 3(PHY bypass、「enable and 48MHz」) | 同 `clock_usb1phy_bypassenable()`、`ohci-cnc18xx.c` `cnc18xx_start_hc()`、U-Boot `drivers/usb/host/ehci-cnc18xx.c` `ehci_hcd_init()` |
| U-Boot の後始末 | `usb stop`(bootm の前)で 0xB2100218 = 0 | U-Boot `ehci_hcd_stop()` |

- **EHCI の先頭アドレスの食い違い**: BSP の Linux は `ioremap(0x80200000) + 0x100` を EHCI capability として使い、起動前に `+0x10` に `|= 3` を書く(`usb_hcd_cnc18xx_make_hc()`)。一方 U-Boot は 0x80200000 をそのまま capability として使い、実機で USB 起動できている。0x100 ごとにレジスタが折り返して見えるなら、`+0x110` は USBCMD(RUN|HCRESET)にあたり、標準のリセットと同じ意味になる(推測)。今回は**実績のある U-Boot の値**を使った。
- PHY は bypass ビットを立てるだけで、専用の PHY ドライバは不要。そのため `generic-ehci` / `generic-ohci` で足りる。リセットは reset-simple、bypass ビットはクロックドライバの `usb` クロックとして、DT からドライバに渡す。

### 変更
- DTS: `generic-ehci` @0x80200000(IRQ 22)、`generic-ohci` @0x80210000(IRQ 27)。
- DTS: `resets = <&rst 4>`(解除だけ。パルスはかけない。コントローラは自分でリセットする)、`clocks = <&clk CNC1800L_CLK_USB>`(0x218 bit0/1)。
- defconfig: `USB_EHCI_HCD_PLATFORM`・`USB_OHCI_HCD_PLATFORM`・`USB_STORAGE`・`SCSI`・`BLK_DEV_SD`・`EXT4_FS`・`VFAT_FS`・NLS(cp437 / iso8859-1)。`linux-7.2/build.sh` の必須 CONFIG にも追加。

### 実機確認
起動に使った USB メモリが、Linux からもそのまま見えるはず。
```
dmesg | grep -i -e ehci -e ohci -e 'usb 1-' -e sda
mount /dev/sda1 /mnt && ls /mnt     # uImage uInitrd boot.scr cameo_factory が見えれば成功
```
- 成功: `ehci-platform 80200000.usb: EHCI Host Controller`、`usb 1-1: new high-speed USB device`、`sd 0:0:0:0: [sda]` が出て、マウントできる。
- 失敗時: 上の `dmesg` 全体と `cat /proc/interrupts` を貼ってほしい。
  - EHCI の probe でエラーが出る、または `new high-speed` が出ない場合は、DTS の EHCI を `reg = <0x80200100 0xf00>`(BSP の配置)に変えて比較する。
  - `irq 22: nobody cared` は IRQ 番号の誤りを示す。

### USB 上の ext4 を rootfs にする(既定)
`out/dsm232-usb.img` は 512MB で、次の 2 パーティションを持つ(実機の ext4 root で起動を確認)。
- 1: FAT16 63MB(`uImage`・`uInitrd`・`boot.scr`)
- 2: ext4 448MB(ラベル `dsm232root`)。中身は initramfs と同じ Alpine。ビルド時に `fakeroot` + `mke2fs -d` で、所有者 root のまま作る。

起動の流れ:
1. `boot.cmd` は既定で `root=LABEL=dsm232root` を渡す(USB ハブ越しや複数の USB ディスクで `sdX` がずれても見つかるよう、ラベルで探す)。
2. initramfs の `/init` が `findfs` でラベル `dsm232root` の ext4 を最大 20 秒待ち、マウントして `switch_root` する。
3. 見つからない、またはマウントできない場合は、そのまま RAM 上の initramfs で起動する。

ext4 上では、`apk add` した物や設定が再起動後も残る。終了時は inittab の `umount -a -r` で読み込み専用に戻すので、`reboot` / `poweroff` で止めること(電源を抜かない)。
- RAM だけで動かしたいとき: U-Boot で `setenv rootdev ram`
- 448MB より大きくしたいとき: PC 上で第 2 パーティションを広げて `resize2fs` する(例: GParted)。
- 別のパーティションに入れる場合は、`out/rootfs.tar.gz` を root 権限で展開する: `sudo tar -xzpf out/rootfs.tar.gz -C /mnt`。そのうえで U-Boot で `setenv rootdev /dev/sdaN`(またはラベルで `setenv rootdev LABEL=名前`)とする。

確認(成功の目安):
- UART に `waiting for LABEL=dsm232root` が数回出たあと、`login:` が出る。
- `mount | grep ' / '` が `/dev/sdX2 on / type ext4 (rw,...)` になる(USB ディスクが 1 台なら `sda2`)。
- 適当なファイルを作って `reboot` し、残っていれば成功。

## 3. Wi-Fi(パッチ 0019)

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
| MAC アドレス | U-Boot 環境変数 `wifiaddr`(本体ごとに違う。`dump/` の本体は `C8:D3:A3:A9:45:8A`)。純正はファームに `softmac` ファイルで渡す | `start_ath.sh`、`dump/spi.bin` |
| U-Boot env | SPI フラッシュ 0xC000、8KiB(先頭 4 byte が CRC32)。0x10000 からは miniloader と env の 2 つ目のコピー(env は初期値) | `dump/spi.bin` の CRC 照合 |

### 変更
- DTS:
  - SDIO: `snps,dw-mshc`(biu/ciu = PCLK)。設定は 4bit、non-removable、cap-sdio-irq、cap-sd-highspeed、`max-frequency` 25MHz(**推測**)。
  - SDIO のピン: `pinctrl-0 = <&sdio_pins>`(pinctrl-single、0xB2110024 bit0)。
  - Wi-Fi の電源: `mmc-pwrseq-simple`(`reset-gpios = <&gpio 10 GPIO_ACTIVE_LOW>`、`post-power-on-delay-ms` 100 は**推測**)。
- 0x140 の全クロック有効は、クロックドライバの probe が行う(どのビットが SDIO 用かは不明)。
- defconfig: `NET`・`INET`・`UNIX`・`PACKET`・`CFG80211`・`NETDEVICES`・`ATH6KL_SDIO`・`MMC_DW_PLTFM`・`PWRSEQ_SIMPLE`(Ethernet ドライバ群は無効)。
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
- **起動時の自動接続**: `/etc/wpa_supplicant.conf` があれば、inittab から `/usr/local/sbin/dsm232-net` が起動し、次を順に行う。ext4 root では設定ファイルが残るので、作るのは 1 回でよい。
  1. wlan0 が現れるのを最大 30 秒待つ
  2. `wpa_supplicant -B`
  3. `udhcpc -b`
  4. `ntpd -p pool.ntp.org`
- **時刻**: DSM-232 には RTC が無く、起動直後の時計は 1970 年になる。このままだと `apk update` が「TLS: server certificate not trusted」で失敗するため、上の自動接続で NTP を合わせている。手動でやる場合は `ntpd -q -n -p pool.ntp.org`。
- **省電力**: カーネルの `CFG80211_DEFAULT_PS` を無効にした。実機で `iw dev wlan0 set power_save off` を実行すると、ping が 27〜322ms のばらつきから 20ms 台に安定したため。純正も同じコマンドを実行していた。
- **MAC アドレス**(パッチ 0024〜0027): U-Boot env の `wifiaddr` を使う。
  - AR6003 は board data 中の MAC(0x16)を使うが、OTP がモジュール固有の MAC(AzureWave の `40:2c:f4:…`)で上書きする。そのため board data ファイルを書き換えても効かない(実機で確認)。mainline の ath6kl は MAC の変更(`ip link set address`)にも対応していない。
  - そこで ath6kl が OTP の実行後に、DT の `mac-address`(nvmem セル)をターゲット RAM 上の board data に書く。チェックサム(0x04、16bit ワードの XOR)は差分の XOR で保つ。
  - DT: SPI の `u-boot-env` パーティションに `nvmem-layout { compatible = "u-boot,env"; }` を置き、SDIO 関数ノード `wifi@1` が `wifiaddr` セルを指す。パーティション自体に `compatible = "u-boot,env"` を付けると、MTD の nvmem と 2 つ重なってセルが見つからない(`-ENOENT`)。
  - `wifiaddr` が無い・読めない場合は、モジュール固有の MAC のまま動く。
  - MAC が変わると DHCP の IP も変わる。
- 失敗時に見るもの:
  - `new ... SDIO card` が出ない(`mmc0: error -110` やタイムアウト): リセット GPIO・クロック・ピンマックスを疑う。`mount -t debugfs none /sys/kernel/debug; cat /sys/kernel/debug/gpio` と、dmesg の dw_mmc の行(`Version ID`、`FIFO depth`、`Using internal DMA controller`)を貼ってほしい。
  - ath6kl がファーム読み込みや BMI のエラーを出す: その行と `ls /lib/firmware/ath6k/AR6003/hw2.1.1/` を貼ってほしい。

## 4. HDMI(DRM ドライバ、パッチ 0020〜0022)

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
- `drivers/gpu/drm/tiny/cnc1800l.c`(新規): DF の出力 0 とグラフィックス層 1、HDMI 送信部を 1 つの DRM デバイスにする。`simple-framebuffer` と U-Boot の `logo` はもう使わない。
  - 送信部の DDC マスタを I2C アダプタにして EDID を読み、モードを選ぶ。EDID が読めなければ 1920×1080 を既定にし、HDMI として扱う。
  - 画素クロックはクロックドライバの表示 PLL。対応は 148.5MHz 以下のプログレッシブで、PLL の表で ±0.5% に入るもの。
  - フォーマット: RGB565 / XRGB8888 / ARGB8888。fbdev(fbcon)は RGB565。メモリは CMA(16MB)。
  - AVI InfoFrame はモードから `drm_hdmi_avi_infoframe_from_display_mode()` で作る(YCbCr 4:4:4、HD は BT.709 / SD は BT.601、アンダースキャン、IT コンテンツ)。DVI の受信側には RGB(DF の RGB→YUV 変換なし)で InfoFrame なし。
  - HDCP 認証・Ri のリンク監視・HPD のポーリングは下の「黒画面の切り分け」のとおり。HPD の変化で DRM のホットプラグイベントを出す。
- `alpine/boot.cmd` の U-Boot 経路(`setenv hdmi uboot`、`hdmimode`、`hdcpoff`)と `tools/display_emu/avi_check.py` は削除した。

### 実機確認
1. 起動すると UART に `[drm] Initialized cnc1800l 1.0.0` と `fb0: cnc1800ldrmfb frame buffer device`、続いて `HDCP authenticated (try N)` が出て、tty1 の `login:` が映る。
2. モードとフォーマット(`apk add libdrm-tests`):
   ```
   modetest -M cnc1800l -c                        # EDID のモード一覧(コネクタ 35、CRTC 38)
   sleep 20 | modetest -M cnc1800l -s 35@38:1280x720-60@XR24
   ```
   カラーバーは左から白・黄・水色・緑・紫・赤・青。
3. HDMI TX の 0x80400024(SYS_STAT): bit0 = 入力クロック安定、bit1 = HPD、bit2 = 受信側の終端検出(SiI の定義)。

### 実機ダンプでの修正(`cnc1800l_display.dump=1`)
最初の版は「初期化は完了と表示されるが映らない」状態だった。`logo` 後(映る)と Linux 初期化後(映らない)のダンプを比べた結果、クロックと DF のタイミングは一致し、違いは次の 2 点だった。
- **72:08 SYS_CTRL1**: 映る状態は `0x37`、旧版は `0x07`。HEN/VEN が落ちていて、TX が測った入力の総画素数・総ライン数(72:3A–3D)が 0 になっていた(映る状態では 2200×1125)。エミュレータが 0 を読ませていたため、`hdmi.bin` の RMW が残すビットを再現できていなかった。
- **DF 0x44**: 映る状態は `0x12`(RGB565 + AlphaIsValid)、旧版は `0x02`。

残りの差は HDCP(72:0F、BKSV、Ri)、音声(AV:01–24、Audio InfoFrame)、割り込みマスク、DDC だけで、映像には関係しない想定。

### 黒画面の切り分け(解決: HDCP 認証が必要だった)
SYS_CTRL1 を直した後、テレビは 1080p60 で同期するようになったが、画面は真っ黒のまま。
- `logo` で映っている状態の上から Linux の初期化をかけても黒くなる。この操作で値が変わるのは、HDMI TX の HDCP(72:0F 0x4F→0)、音声、72:CC(0x0F→0x01)だけだった。
- `hdcpoff=1` の試験では、`hdmi.bin` の HDCP 認証が失敗した回に、`hdmi.bin` 自身が SYS_CTRL1 を 0x36(PD#=0、電源断)にしていた。純正は HDCP が通らないと出力を止める作りと見られる。
- `steps` で切り分けた結果(`logo` で映っている状態の上から実行): DF だけ = 映る。HDMI TX のレジスタだけ = 黒。
- U-Boot で `logo` を実行し、上半分を赤く塗った後に 1 か所ずつ書き換えた結果: HDCP_CTRL=0 で黒になった。SRST パルスでは色化けし(暗号化中のリセット)、Audio InfoFrame を止めても変化はなかった。
- HDCP_CTRL=0x04(HDCP ブロックはリセット解除、暗号化なし)でも黒だった。**送信部は HDCP で暗号化していないと映像の代わりにブランク色を出す**と判断した。純正 Linux ドライバ `SiITX.c` `siiTX_HDMI_Init()` にも「set the default output color to black when HDCP authentication not success」とある。
- そこで HDCP 1.x 認証を実装した(`steps` の bit4)。純正 `SiITXHDCP.c` `siiTXHDCP_Authentication()` と同じ手順で、次の順に処理する。実機で認証が通ることを確認済み。
  1. DDC マスタ(72:ED–F5)で受信側の BKSV を読み、1 と 0 が 20 個ずつあるか確認する
  2. CP_RESETN を立て、BCAPS で受信側がリピータかを見る
  3. AN を生成して受信側に書き、送信部の AKSV も受信側に書く
  4. 150ms 待ってから、BKSV を送信部に書く(R0 の計算が始まる)
  5. R0 を照合して一致すれば ENC_EN を立てる。前後は AVMUTE で挟む
  - HDCP 鍵は送信部が内蔵している(AKSV がコールド状態でも読める)。
  - リピータ用の第 2 段階(SHA)と、Ri によるリンク監視は実装していない。そのため、テレビを挿し直すと黒に戻る。
- 最初の版は起動処理の中で 1 回だけ認証し、`-22`(当時は BKSV 不正もこの番号)で失敗した。純正 U-Boot でも、最初の数回は `DDC Time Out` → `No HDCP Dev` で失敗してから認証が通る。そこで、起動処理とは別に 1 秒おき・最大 30 回まで再試行するようにした。
- **ホットプラグ対応**: 同じ処理が 1 秒おきに次の 2 つを確認する。
  - SYS_STAT の HPD(H→L→H の変化で挿し直しと判断する)。純正 `siiTXHDCP_CheckHPDChanged()` が見ている INT1 bit6(HPD 変化)は使わない。実機では再設定そのものでこのビットが立ち直り、数秒ごとに再設定を繰り返して画面が点滅した。
  - 2 秒おきに、受信側と送信部の Ri を照合する(テレビの入力切り替えのように HPD が変わらずに HDCP が切れる場合に備える)
  - 挿し直しや、2 回続けての Ri 不一致を検出したら、送信部のレジスタを設定し直し(リセットパルスはかけない)、HDCP を再認証する。
  - ログ: 抜くと `HDMI unplugged`、挿すと `HDMI plugged, setting up again` → `HDCP authenticated`。Ri が合わないと `HDMI link lost, setting up again`。実機で確認済み。
- `HDCP authenticated (try N)` が出れば認証成功。30 回失敗すると `HDCP still failing (エラー番号)` が出る。番号の意味は次のとおり。
  - -5: DDC 失敗
  - -6: 受信側の BKSV が不正(1 の数が 20 個でない)
  - -22: 送信部が BKSV エラーを返した
  - -13: R0 不一致
- 原因の段階の特定には `cnc1800l_display.steps=<ビットマスク>`(bit0 = クロック、bit1 = DF、bit2 = HDMI ブロックのリセット、bit3 = HDMI TX のレジスタ、bit4 = HDCP 認証)を使った。解決後に削除した。

### 未確認・限界
- エミュレータは未知のレジスタを 0 として読むため、read-modify-write の結果は「リセット値が 0」と仮定したものになっている。DF と HDMI の書き込みは、その結果の値をそのまま書いている。
- TMDS PLL(72:80、72:83–85)は送信部のリセット値のまま。純正 `SiITX.c` `siiTX_TMDS_Setup()` は画素クロックの範囲ごとに書き換えるが、確認した 25〜148.5MHz の全モードで書き換えなしで映った。
- 音声は未対応(下の 8)。
- 垂直帰線割り込み(DF IRQ 7、0x10 bit3)は使っていない。ページフリップの完了は即時に通知する。

## 5. GPIO・LED・ボタン(パッチ 0008、0009、0015、0023)

### 根拠
| 項目 | 値 | 出典 |
|---|---|---|
| GPIO ブロック | 0x80260000。ポート A(0–31): DR +0x20、DDR +0x24(**1 = 入力**)、入力値 +0x60。ポート B(32–40): +0x34 / +0x38 / +0x64 | BSP `cnc18xx_gpio.c` |
| 割り込み | SoC IRQ 6。マスク +0x28 / +0x3C(1 = マスク)、極性 +0x2C / +0x40(1 = Low で割り込み)、状態 +0x68 / +0x6C。レベルのみ | 同 `cnc_gpio_irq_*()` |
| LED | GPIO 2、1 = 点灯 | 純正 U-Boot 環境変数 `ledon=gpio write 2 1` |
| ボタン | GPIO 9、押すと 0 | D-Link `csgpio.c` |

### 変更
- `drivers/gpio/gpio-cnc1800l.c`(新規): 41 本を 1 つの gpio_chip にする。エッジ割り込みは、エッジのたびに逆のレベルを待つように極性を切り替えて作る。`gpio-mmio` はポート B と割り込みを表せないため。
- DTS: `gpio-leds`(LED、起動時に点灯)、`gpio-keys`(ボタン = `KEY_PROG1`)。

### 実機確認
```
apk add evtest; evtest /dev/input/event0      # 押すと KEY_PROG1 value 1、離すと 0
grep button /proc/interrupts
```

## 6. クロック・リセット・ピンマックス(パッチ 0006、0007、0016)
- `drivers/clk/clk-cnc1800l.c`(新規): 表示 PLL(TVE PLL = 27MHz × (fb + 1) / m、設定は純正 `disp_pll_cfg[]` の 108 / 297 / 50.4 / 129.6 / 216MHz)と、表示・HDMI TMDS の分周(0x148 [11:8] / [15:12])、クロック有効ビット(0x140: 表示 bit4、TMDS bit6、音声 bit22、CEC bit26)、USB PHY bypass(0x218)。分周とゲートは汎用の clk-divider / clk-gate。番号は `include/dt-bindings/clock/celestial,cnc1800l-clk.h`。
- 0x200 のリセット(0 = リセット)は mainline の reset-simple(`snps,dw-low-reset`)。USB = 4、表示 = 13、HDMI = 19(純正 `clock_*_reset()`)。
- ピンマックス(0xB2110000、16bit レジスタ)は mainline の pinctrl-single。
- machine のコード(`arch/arm/mach-celestial/*.c`)は無くなり、汎用の DT マシンで起動する。
- 注意: CEC クロック(bit26)が止まっている間に 0x80401000 以降(CEC)を読むと、バスが止まって応答しなくなる。`devmem2` で触るときは先に CEC を有効にする(`cec-ctl --playback`)。

## 7. CEC(パッチ 0021)
- 送信部 +0x1000 の Silicon Image CPI(純正 `si_apiCpi.c`、レジスタは `si_cpi_regs.h` のバイトオフセットのまま)を、DRM ドライバが CEC アダプタ(`/dev/cec0`)として出す。20ms ごとにポーリングする。物理アドレスは EDID から取る。
- 確認(`apk add v4l-utils`):
  ```
  cec-ctl --playback --osd-name DSM-232    # 論理アドレス 4 を取る
  cec-ctl -S                               # トポロジ(テレビ = 0 が見えれば通信できている)
  cec-ctl --to 0 --image-view-on           # テレビの電源を入れる
  ```
- 実機では論理アドレスを取り、送信は「Not Acknowledged」で終わった。つないだ PC モニターが CEC 非対応のためで、CEC 対応テレビでの確認は**未実施**。
- CEC のビットタイミングを決める分周(0xB2100120 の下位 8bit)は U-Boot が設定した値(0xBB)のまま。

## 8. 試験カーネルの起動(kexec)
USB のカーネルを書き換えずに試す。起動しなかったら電源を入れ直せば USB 上のカーネルに戻る。
```
mount -o ro /dev/sda1 /mnt && dd if=/mnt/uInitrd of=/tmp/initrd bs=64 skip=1 && umount /mnt
kexec -l /tmp/zImage --dtb=/tmp/cnc1800l-dsm232.dtb --initrd=/tmp/initrd --command-line="$(cat /proc/cmdline) panic=10"
kexec -e
```
`root=LABEL=` は initramfs の `/init` が解決するので、`--initrd` を省くと root をマウントできずに panic する。

### 上位 RAM 119MB を Linux に足す(仮説・実機未検証)
`mem=137M` は、純正 FW が 0x08900000 以上をフレームバッファ等に使い、旧版では U-Boot の `logo` が 0x0C000000 に描いた画面を `simple-framebuffer` で引き継いでいたための制限。現在は DRM ドライバが CMA(Linux 側の RAM)から画面を取り、USB 起動経路(`fwimg-app.sh` が仕掛ける `bootcmd`)では純正 U-Boot が `show_logo` も `boots` も実行しない。したがって 0x08900000–0x0FFFFFFF に書き込む DMA は無い、というのが仮説。ARM の `mem=` は 2 個目以降が領域の追加になるので、カーネルを作り直さずに試せる:
```
# 上の kexec 手順で、--command-line だけを変える(UART 不要)
kexec -l /tmp/zImage --dtb=/tmp/cnc1800l-dsm232.dtb --initrd=/tmp/initrd --command-line="$(cat /proc/cmdline) mem=119M@0x08900000 panic=10"
kexec -e
```
UART があれば純正 U-Boot で `setenv extraargs mem=119M@0x08900000` としても同じ(`boot.cmd` が bootargs に足す)。
検証: `free -m` で約 119MB 増えること、`memtester 100M 3`(`apk add memtester`)が通ること、その状態で HDMI・Wi-Fi・USB を数時間使って異常が出ないこと。問題が出ても電源を入れ直せば元に戻る。確認が取れるまで DTS の既定(137MB)は変えない。

## 9. 未対応
- **HDMI 音声**: 音声ブロック(0xB1200000)は DSP で動き、PCM は DSP のファーム(GPL パッケージの `crisprelease/firmware/audio_fw_{text,data,ext_data}.bin`)経由で I2S に出る。ファームへの指示(メールボックス、ホスト IF 領域)はベンダーの `libcsaud.a`(バイナリ)にしか無く、解析が必要。送信部側(I2S 入力、N/CTS、Audio InfoFrame)は `SiITX.c` にある。音の出る機器での確認が必要なため保留。
- **I2C**: ベンダー独自のブロック 2 つ(0x80170000 IRQ 2 / 0x80174000 IRQ 3、`cnc18xx_i2c.c`)。HDMI の DDC は送信部の中にあり、この I2C とは別。
  - 純正 U-Boot の `i2c` は I2C0(0x80170000)だけを扱う。ピンマックス 0xB2110004 bit0 は U-Boot の時点で 1(I2C0 選択済み)。
  - `i2c probe` は 00〜7F の全アドレスを「Valid」と出すが、当てにならない。純正の `i2c_probe()` は割り込み状態(+0x14)に何かのビットが立った最初の時点で、0x20(ACK なし)が無ければ成功とするため。
  - `i2c md <addr> 0 1` を 0x03〜0x77 の全アドレスで実行すると、すべて「Error reading the chip」(2026-11-20)。純正の `i2c_read()` は失敗時に割り込み状態を消すかコントローラをリセットするので、後から理由は読めない。
  - そこで `mw.w` で読み出しを組み立てた(`IC_DATA_CMD` +0x0C に `0x100|addr<<1`、`0x200|sub`、`0x101|addr<<1`、`0x600` を順に書き、`IC_RAW_INTR_STAT` +0x14 を読む)。アドレス 0x50 で:
    - I2C0(0x80170000、GPIO 16/17): 0x40(純正の定義でアービトレーション負け)。
    - I2C1(0x80174000、GPIO 0/1、ピンマックス 0xB2110004 bit1 を立て、SCLH/SCLL = 0x76): 0x41。
    - どちらも ACK なし(0x20)ではなく、開始条件の時点で線が期待した電圧になっていない。プルアップが無い(配線されていない)ときの形。
  - DSM-232 では I2C0・I2C1 とも何もつながっていない可能性が高い。ただし応答する既知のデバイスで手順を確かめてはいない。試験後、ピンマックスと I2C1 のレジスタは元の値に戻した。
  - U-Boot の 1 行は 256 文字まで(`CONFIG_SYS_CBSIZE`)。全アドレスを試すときは `for a in 03 04 ...; do echo $a; i2c md $a 0 1; done` を 8 アドレスずつに分ける。
- **SPI の DMA**(DW DMAC): 公開している SPI フラッシュは 128KiB の読み出し専用なので、利点が無く未対応。
- **LAN**: DSM-232 に端子が無い。
