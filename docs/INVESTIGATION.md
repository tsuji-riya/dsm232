# D-Link DSM-232 (rev A1) 調査メモ

調査元: `DSM-232_A1_GPL_FWv1.02.00.rar` (478MB, D-Link GPL, 2013-08-19)。
内容: `DSM232-A1_FOSS_20130819.tgz` (GPLソース) / `arm-2010q1.tgz` (CodeSourcery ARM toolchain) / ライセンス資料。
展開物は容量が大きいためリポジトリには含めていない (取得URLは上記)。

## 1. SoC・プラットフォーム

| 項目 | 内容 |
|---|---|
| SoC | Celestial Semiconductor (後に Cavium) **CNC1800L** (SDKコードネーム "Tiga Mini") |
| CPU | ARM (v6/v7系, Linux側 `MACH_CELESTIAL_CNC1800L`, `CELESTIAL_TIGA_MINI`) |
| RAM | カーネル設定 `CELESTIAL_MEM_SIZE=256` (256MB)。物理 RAM 先頭 0x00000000 |
| Flash | NAND (`MTD_NAND_CELESTIAL`) + JFFS2 rootfs、miniloader は SPI または NAND |
| UART | 8250互換 ×2。UART0=0x801F1000 (IRQ12), UART1=0x801F2000 (IRQ13) |
| 主要レジスタ | IO 0x80100000, Graphics 0xB0000000, Media 0xB1000000, Audio 0xB1200000, SysCtl 0xB2100000, GPIO 0x80260000, I2C 0x80170000, EHCI 0x80200000 |
| 周辺 | USB(EHCI/OHCI), SDIO(WiFi: AR6000系ドライバ+キャリブ bin), Ethernet MAC, CEC, FB (`FB_CELESTIAL`) |
| 出力 | HDMI(TMDS) + SD TVOUT。FB0=16MB ARGB、FB2=8MB (RAM上端から逆順に予約) |

※ レジスタアドレスは `linux-1800l-2-6-32.patch` 内 `mach/cnc1800l.h` による。

## 2. ソース構成 (`ott/`)

- `buildgpl.sh` / `myenv` : ビルドエントリ。toolchain は `/opt/arm-2010q1` (`arm-none-linux-gnueabi-`)。要 Ubuntu 10.04 相当の古いホスト (i386想定)。
- `crisprelease/buildroot/` : Buildroot 一式 + `tarfiles/` (linux-2.6.32, u-boot-2011.03, busybox 1.19.4, DirectFB 1.4.17, ffmpeg 0.10.2 ほか)
- `crisprelease/buildroot/linux/kernel-patch/linux-1800l-2-6-32.patch` : **vanilla 2.6.32 に当てる 8.8MB のSoC BSP パッチ** (mach-celestial, drivers/celestial/*)
- `crisprelease/buildroot/linux/kernel-config/cnc1800l_TigaMini_defconfig` / `dlink/config/kernel.config` : カーネル設定
- `dlink/kernel-patch/` : D-Link 固有差分 (nand.c, nand_ids.c, mem_define.h, cnc1800l_df.c, spidev, audio.h)
- `crisprelease/buildroot/boot/uboot/2011-06/uboot-patch/uboot-2011.06-cavium-beijing.patch` : **U-Boot 2011.06 向け 7.2MB BSP パッチ** (tarfiles には 2011.03 があり、2011.06 ベースかは要確認)
- `.../uboot/2011-06/source/signing_tool/` : miniloader (バイナリ) + `mk_nonsec_image` (非セキュア用フラッシュイメージ作成)。`hdmi_pic_bin` は U-Boot 後ろに連結される HDMI PIC コード。
- `crisprelease/core/lib`, `extensions/lib`, `firmware/` : **バイナリのみ** のメディア/表示ライブラリと音声FW (libcsvid, libcstvout, libcsosd 等)。ソースは含まれない。
- `6611L_TigaMini/usb_upgrade/create_usb_image.sh` : U-Boot + uImage + rootfs を `misc.img` に束ねる USB アップグレード手順。

## 3. ブートチェーン (わかったこと)

1. ROM → **miniloader** (署名/非署名、DDR周波数・容量・NANDページサイズ別のバイナリ。非ソース)
2. 2nd boot loader = **U-Boot** (`second_param.txt`: flash entry 0x80000, サイズ 0x5FF00, 実行アドレス 0x2000000)
3. U-Boot → uImage (Linux 2.6.32-SDK-0.2) + JFFS2 rootfs。U-Boot パッチ内に USB アップグレード機能 (bootargs/bootcmd を USB イメージから設定) あり。

## 4. 目標 (U-Boot/Linux 対応 → 書き込み → HDMI 出力) に向けた評価

**難所**
- miniloader (DDR 初期化) はバイナリのみ。DDR設定値は `second_param.txt` のパラメータで与える形。基板の DDR 型に合うバイナリを選ぶ必要あり。
- Linux は 2.6.32 に BSP パッチ。最新カーネルへの移植は現実的でなく、**まず 2.6.32 + 付属 toolchain で動かす**のが現実解。HDMI は `drivers/celestial` の独自 FB と、U-Boot 側 `hdmi_pic_bin` / `clock_hdmiset_clockmode` が関わる。
- メディア系 (デコード等) はバイナリライブラリ依存。**フレームバッファ経由の HDMI 出力**が最短目標。
- 古い toolchain (32bit ホスト向け) をこの環境で動かすには i386 互換が必要。

**未確認 (実機/追加情報が必要)**
- 実機の UART 端子位置・電圧、フラッシュ型番、NAND パーティション (mtdparts) と純正の bootargs
- 工場出荷 U-Boot が secure boot 有効か (署名ツールは "insecure" 向けと記載)
- 実機のダンプ (NAND/SPI) の有無 — 変更前に必ずバックアップを推奨

## 5. 次のステップ案

1. 実機のシリアルコンソールを接続し、純正 U-Boot の `printenv`・`mtdparts`・`bdinfo` を採取、NAND をバックアップ
2. toolchain 準備後、`buildgpl.sh` でそのまま純正相当の `dsm232.img` をビルドして再現性確認
3. U-Boot を単体ビルド (patch 適用) → UART から TFTP/USB ロードで RAM 起動 (フラッシュ書換前に検証)
4. Linux 2.6.32 + patch + TigaMini defconfig で FB(HDMI) 出力確認 → その後に NAND 書き込み
