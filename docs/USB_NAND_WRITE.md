# USB から NAND を書き換える方法 (GPL ソースから確認できたもの)

結論: **ある。純正 U-Boot に USB マスストレージ(FAT)から読み込んで NAND/SPI に書く機能が複数あり、UART も不要な経路もある。** ただし以下は全てソース読解のみで、実機では未検証。

## 経路 A: U-Boot `update` コマンド (misc.img)
- U-Boot パッチ `common/cmd_update.c` / `do_auto_update()` (`CONFIG_AUTO_UPDATE`, `CONFIG_USB_STORAGE`)。
- 動作: `usb_init` → `usb_stor_scan` → 1 番目のパーティションを FAT として読み、**ルートの `misc.img`** を RAM (`CONFIG_USB_UPGRADE_DATA_ADDR` = 0x10000000 または 0x1000000) に読み込む。
- RAM 上に既にあるイメージから書く場合は `update <hexサイズ>`。
- `misc.img` の形式 (`6611L_TigaMini/usb_upgrade/encrypt.c`): 全バイトを **XOR 0xE3** しただけ (暗号ではなく難読化)。
  ```
  [1B bootargs長][1B bootcmd長][bootargs][bootcmd(4B境界に空白パディング)]
  [8文字hex start/len ×3 = u-boot, kernel, ramdisk]  (48B)
  [uImage形式ヘッダ(64B)+データ] ← crc32 検証あり。中身は u-boot(firmware) / kernel / ramdisk(rootfs) が連結
  ```
  署名検証 (RSA) はこの経路には無い。
- 書き込み先: kernel/ramdisk は `nand erase.spread` + NAND 書込、firmware (u-boot) は `sfer` (SPI フラッシュ)。成功すると `bootargs` / `bootcmd` を設定して `saveenv`。
- 作り方: `6611L_TigaMini/usb_upgrade/create_usb_image.sh` (u-boot / uImage / rootfs を `mkimage` で連結 → `encrypt.c`)。
- 純正 `encrypt.c` の bootargs が示す NAND パーティション:
  `mtdparts=cnc_nand.0:3m(Kernel),504m(fs),3m(kernel_update),2m(bad_blks_table)`、`root=/dev/mtdblock4`。
  → ただし `encrypt.c` の kernel_st=0x0 / ramdisk_st=0x300000 の絶対アドレスは実機の最終レイアウトと合っているか要確認。

## 経路 B: U-Boot `upgrade` コマンド (D-Link 形式 .img)
- `upgrade -f <filename>` (USB から) / `upgrade -a <addr>` (RAM から)、`-i` で STB の ID 表示。
- D-Link 独自の download header (manufactor_code / hardware_version / minimum_uboot_version / partition 数) + partition header (memory_type = EEPROM / **SPI** / **NAND**, 開始アドレス, erase_only 等) を解釈して書く。ID 不一致や U-Boot バージョン不足はエラー。
- `digital_signature` フィールドは読むだけで、ソース上では検証していない(`cmd_rsa.c` は別コマンド)。

## 経路 C: Linux 側 (通常起動中)
- `dlink/usbupg/usbupg.c`: USB 挿入を検知し `mount` → `/mnt/usb/gcg_firmware/dsm232.img` があれば `fwimg dsm232.img` (`dlink/obj/fwimg`, `fwup` はバイナリのみ) を実行。
- 工場用: `cameo_factory/factory.img`。
- fwimg/fwup のソースは同梱されておらず、形式は経路 B と同じ可能性が高いが未確認。

## 自作カーネルを入れる実用手順 (推奨順)
1. **まず UART を繋ぎ、U-Boot で `printenv` / `bdinfo` / `nand info` / `mtdparts` を記録し NAND を `nand read` でバックアップ** (USB メモリへ書く手段は経路 A/B には無いので、`tftp`/`loadb` か UART で吸い出す。`fatwrite` が有効かは `help` で確認)。
2. 書き込み前に RAM 起動で検証: USB から `fatload usb 0 0x2000000 uImage` → `bootm` (U-Boot 自身の実行域と衝突しないアドレスを使う)。
3. 問題なければ経路 A の `misc.img` を自作して kernel のみ書く (u-boot を含めない = SPI/ブートローダを壊さない)。`encrypt.c` の bootargs / start,len は実機の値に合わせる。
4. u-boot (`sfer`) 側は**変動させない**。ここを書き損じると UART/USB 経路ごと失う。

## 注意 / 未確認
- 実機の U-Boot バイナリが GPL 版と同一か、`update` / `upgrade` が有効かは未確認 (`help` で確認)。
- 開始アドレスのスケール (encrypt.c の 8桁 hex が byte 単位か) と NAND パーティションの対応は実機で `nand info` と突き合わせること。
- miniloader/U-Boot 領域(SPI)に誤って書くと文鎮化する。

---
## 追記: UART 無し・USB を挿して電源 ON だけで書き換える方法

**確実に動くと確認できた方法はない**(実機未検証、`fwimg`/`fwup` はバイナリのみで検証内容が読めない)。ソースから見て最有力なのは次の 1 つ。

### 有力: 純正 Linux の起動スクリプトによる自動 USB 更新
- `6611L_TigaMini/skeleton/etc/normalrc` (= `dlink/script/normalrc`) が起動のたびに **`usbupg -f`** を実行する。
- `usbupg -f` (`dlink/usbupg/usbupg.c`): `/dev/sda` があれば `mount /dev/sda1 /mnt/usb` し、
  `/mnt/usb/cameo_factory/factory.img` があれば `cd /mnt/usb/cameo_factory; fwimg -f factory.img` を実行(表示: "Firmware found")。
  なければ何もしない。
- `-f` 無し(UI などから呼ばれる場合)は `gcg_firmware/dsm232.img` を `fwimg dsm232.img` で書く。
- つまり **FAT フォーマットの USB メモリに `cameo_factory/factory.img` を置いて挿し、電源を入れる**と、純正 FW が起動後に自動で書き込む可能性が高い。

### factory.img の作り方 (GPL 付属ツールで再現可能)
`tools/rootfs/build` より:
```
bootpImage (kernel + initramfs を一体化)            # DSM-232 の rootfs は initramfs 方式
  → mkimage -a 0x8000 -e 0x8000 -T kernel  → ubootpImage
  → CreateCavm18NetHdImageAligned ubootpImage dsm232.bin [padding] [align=128K]   # i386 静的バイナリ、実行確認済み
  → mkimg -A ARM -C none -T flashfs -n DSM232_FlashFS -d dsm232.bin dsm232.img      # fwimg 用 (gcg_firmware/dsm232.img)
  → mkimg -A ARM -C none -T fffs    -n DSM232_FlashFS -d dsm232.bin dsm232_fact.img # 工場用 → factory.img
```
- `dsm232.bin` は「bootloader からのアップグレード用」(U-Boot の `upgrade`/`update` 経路)。
- Linux 7.2 を載せるなら、`bootp` は無いので **initramfs を内蔵した zImage + DTB 連結 → uImage(0x8000)** を `ubootpImage` の代わりに使う想定。
- `mkimg` は 32bit 動的バイナリのため `libc6:i386` が必要 (`dpkg --add-architecture i386`)。

### リスク (UART 無しの場合は特に重要)
- `fwimg` が署名・機器 ID・サイズ・パーティション範囲を検査するかは不明。拒否されても無害だが、通れば **NAND/SPI の対象領域を上書き**する。
- 書き込み先が kernel/rootfs 領域のみか、U-Boot(SPI) まで含むか **イメージ形式から確認できていない**。U-Boot が壊れると UART 無しでは復旧不能。
- 自作カーネルが起動しなかった場合、画面・UART が無いと原因が見えない。純正に戻すには再度 USB 更新が必要だが、純正 Linux が消えていれば `usbupg` 経路も使えなくなる(U-Boot 側の USB `update`/`upgrade` が残っていることに依存)。
- 先に「純正 FW の `dsm232.img`」を USB に入れて**同じ手順で書けること**を確認し、`mkimg -l` で純正イメージのヘッダを解析して書き込み領域を把握してから進めるのが安全。
