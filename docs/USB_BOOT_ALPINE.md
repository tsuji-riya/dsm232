# USB メモリから Linux 7.2 + Alpine Linux を起動し HDMI にコンソールを出す

> **更新**: HDMI は DRM ドライバ(`linux-7.2/patches/0009`)が EDID を読んで初期化し、`boot.cmd` は `logo` を実行しない。U-Boot の `logo` + `simple-framebuffer` の経路(`setenv hdmi uboot`、`hdmimode`)は削除したので、以下でそれを扱う記述は旧版の記録。USB・Wi-Fi・reboot も対応した。詳細は [LINUX_PERIPHERALS.md](LINUX_PERIPHERALS.md)。

**結論**: 純正 U-Boot(2011.06)の `logo` で HDMI を起動し、そのフレームバッファを Linux の `simple-framebuffer`(fbcon)で引き継ぐ。カーネル(`uImage`)と Alpine の initramfs(`uInitrd`)は U-Boot が USB の FAT から RAM に読む。NAND/SPI には一切書かない(`saveenv` を使う任意手順を除く)。**実機未検証**。

## 1. 根拠(`dump/` の解析で確認したこと)
| 事実 | 出所 |
|---|---|
| 純正 U-Boot は NAND 0x20000 に格納され、0x02000000 にリンクされている(2 本目は 0xA0000) | `dump/nand.bin` のベクタテーブル |
| `logo <mode> <color> <addr> <w> <h> <x> <y>`(0x020042dc)は **0x0C000000 を pitch×高さだけ 0 クリア**し、画像を矩形コピーし、末尾で U-Boot に付加された `hdmi.bin` を実行する | 逆アセンブル 0x02004224–0x020045b0 |
| mode 表(0–20): 0/2/8/10/11=720×576、1/3/9=720×480、4/5/20=1280×720、6/7/12–16=1920×1080、17=640×480、18=800×600、19=1024×768。pitch = 幅×2。color 2 = 2 byte/pixel(color 6 は 4 byte/pixel) | 同上(mode 表 0x02004338)|
| 実タイミング: 0=PAL、1=NTSC、2=576p、3=480p、4=720p50、5=720p60、6=1080i50、**7=1080i60(純正の「1080P」は実はインターレース)**、12/13/14=1080p24/25/30、15=1080p50、**16=1080p60**、17=VGA、19=XGA | mode→タイミング表 0x0203c308 と DISP_* 名テーブル(0x0203a4d0、0x60 byte/件) |
| color 2 は **リトルエンディアン RGB565** | NAND 0x200000 の純正スプラッシュ(1280×720×2)を RGB565 LE として描画すると正しく表示された |
| 純正の起動: `bootcmd=dcache on;run ledon; run show_logo;boots`、`show_logo=nand read 4000000 200000 0x1C2000; logo 5 2 4000000 1280 720 0 0` | `dump/spi.bin` の環境変数 |
| `bootm` は ATAG_CMDLINE / ATAG_MEM / ATAG_INITRD2 を渡し、`initrd_high` を読む。`fatload`・`usb`・`source`・`mw` あり | U-Boot 内のタグ定数と文字列 |
| CPU は TrustZone 付き ARMv6(SCR = CP15 c1,c1,0 を書いている) → ARM1176 と整合 | U-Boot の `mcr` 命令 |

## 2. 変更内容
- `linux-7.2/patches/0004-*`: DTS の `/chosen` に `simple-framebuffer`(0x0C000000, 1920×1080, stride 3840, `r5g6b5`。`boot.cmd` は `logo 16 2 ...` = 1080p60)、`mem=137M`、defconfig に `VFP` / `VT` / `FB_SIMPLE` / `FRAMEBUFFER_CONSOLE`。
  - `mem=137M` は必須: 純正 U-Boot は ATAG_MEM(256MB)を渡し、`ARM_ATAG_DTB_COMPAT` が DT の memory ノードを上書きする。無いとフレームバッファ領域を Linux が通常メモリとして使い、画面が壊れる(既存ポートの潜在バグでもあった)。
- `linux-7.2/build.sh`: 上記の CONFIG が `.config` から消えていたら停止。
- `alpine/build.sh`: Alpine armhf minirootfs(latest-stable、sha256 検証)→ busybox init + tty1/ttyS0 の getty → `uInitrd`、`boot.cmd` → `boot.scr`。
- `alpine/boot.cmd`: USB からの起動スクリプト。
- `build-usb.sh` / `docker/`: Debian trixie コンテナで上記すべてと USB イメージ(`out/dsm232-usb.img`)を作る。root・ループデバイス不要。

RAM 配置: `0x4000000` uImage(<16MB)/ `0x5000000` uInitrd(<16MB)/ `0x6000000` boot.scr / `0x0C000000` FB / Linux は `0–0x08900000`。

## 3. 手順
### 3.1 Docker でビルド(必要なのは Docker とネット接続だけ)
```bash
./build-usb.sh
```
結果: `out/dsm232-usb.img`(512MB、MBR。第 1 パーティションは FAT16 で `uImage` / `uInitrd` / `boot.scr`、第 2 パーティションは ext4 の rootfs。[LINUX_PERIPHERALS.md](LINUX_PERIPHERALS.md) 2 節)。同じ 3 ファイルが `out/usb/` にもある。初回はカーネル取得とビルドで数十分。カーネルソースは Docker ボリューム `dsm232-linux-src` に残り、2 回目以降は差分ビルド(macOS/Windows のホスト側ファイルシステムは大文字小文字を区別せず、カーネルの `xt_DSCP.h`/`xt_dscp.h` 等が壊れるため、リポジトリ内には置かない)。作り直すときは `docker volume rm dsm232-linux-src`。

### 3.2 USB メモリに書く(中身は全部消える)
Linux: デバイス名を `lsblk` で必ず確認してから。
```bash
sudo dd if=out/dsm232-usb.img of=/dev/sdX bs=4M conv=fsync status=progress
```
Windows / macOS: balenaEtcher か Rufus(DD モード)で `out/dsm232-usb.img` を書く。

### 3.3 USB を挿して電源 ON(UART 不要。**実機未検証**)
USB を挿したまま電源を入れると、純正ファームウェアが一度起動してから自動で再起動し、USB の Linux が起動する(純正の起動画面が出てから数十秒かかる)。USB を挿していなければ純正のまま起動する。本体の環境変数は、USB 起動のたびに一時的に書き換えて元に戻すので、終わった後は元と同じになる。

仕組み(根拠は 6 節):
1. 純正 Linux は起動のたびに `usbupg -f` を実行し、USB の第 1 パーティションに `cameo_factory/factory.img` があれば `fwimg` に渡す。
2. `factory.img`(`tools/mk_fwimg_app.py` で作る app タイプのイメージ)は、`fwimg` が jffs2 に展開して `app.sh`(`alpine/fwimg-app.sh`)を root で実行する。署名検証は無い。
3. `app.sh` は U-Boot 環境変数に、1 回だけ使う `bootcmd` と `dsmusb` を書き(`/dlink/env`)、再起動する。
4. U-Boot はまず `bootcmd` を元の値に戻して `saveenv` し、続く `dsmusb` で自分自身を消して再度 `saveenv` してから、USB ストレージ 0〜3 番を順に探して最初に `boot.scr` が読めたものから起動する(`usbdev` に番号が入る)。どれも駄目なら `usb stop` して純正の起動に戻る。
5. USB の Linux は起動時に FAT の `cameo_factory/armed` を消す。

- **再起動ループ防止**: `app.sh` は環境変数を書く前に `cameo_factory/armed` を作る。USB の Linux まで届かずに純正に戻ってくると `armed` が残っているので、そのときは何もせず純正のまま動き、`armed` だけ消す(次の電源 ON で再挑戦)。
- **USB ハブ**: U-Boot はハブの先のストレージも 0〜3 番として数え、Linux はラベル(FAT は `DSM232`、ext4 は `dsm232root`)でパーティションを探すので、ハブ越しでも、他の USB ディスクと一緒でも動く想定。ただし純正の `usbupg` は `/dev/sda` しか見ないので、**USB ディスクを複数つなぐときは、このメモリが `sda` になるとは限らない**(1 本だけなら問題ない)。
- **本体に残るもの**: 何も残らない想定。jffs2 に `app.tar.gz` → `app.sh` が一時的に作られて消える。環境変数は 1 回の USB 起動で 4 回書き換わる(Linux で 2 回、U-Boot で 2 回)。
- **リスク**:
  - 実機の 1.02.29 の `fwimg` が app タイプを受け付けるかは不明(読めたのは GPL 版 1.02.00)。拒否されても何も起きない。
  - 環境変数の書き換え中に電源が切れると、U-Boot は工場出荷時の環境変数(`FIRST_BOOT=1`)に戻す(`Primary NVRAM parameter is corrupted` の処理)。
  - U-Boot が `dsmusb` の `for` ループを解釈できなかった場合も、`bootcmd` 自体は元に戻して保存し純正で起動する。`dsmusb` が環境変数に残るだけ。
  - U-Boot 2011.06 がハブの先の USB 1.1(フルスピード)機器を読めるかは未確認。普通の USB 2.0 メモリなら問題ない想定。

### 3.4 UART を使う場合(フラッシュは書かない)
自動起動を止めて:
```
usb start
fatload usb 0:1 0x6000000 boot.scr
source 0x6000000
```
USB ディスクが複数あるときは `usb storage` で番号を確かめ、`0:1` を `N:1` にして、`source` の前に `setenv usbdev N` とする。

毎回 UART を使わずに済ませる別の方法として、SPI の環境変数の `bootcmd` を書き換えてもよい(1 回だけ。3.3 と違い、設定は書き換わったままになる)。USB を抜けば純正起動に戻る。
```
setenv bootcmd 'usb start; for d in 0 1 2 3; do if fatload usb $d:1 6000000 boot.scr; then setenv usbdev $d; source 6000000; fi; done; usb stop; dcache on;run ledon; run show_logo;boots'
saveenv
```
元に戻す: `setenv bootcmd 'dcache on;run ledon; run show_logo;boots'; saveenv`

### 3.5 解像度を変える
既定は 1920×1080 プログレッシブ 60Hz(mode 16、`logo` が出せる最大)。ディスプレイが受けない場合は次の 2 か所を**同じ値**に変えて `./build-usb.sh` をやり直す(1 か所だけ変えると表示が崩れる)。
- `alpine/boot.cmd`: `logo <mode> 2 ...`
- `linux-7.2/patches/0004-*` の DTS: `width` / `height` / `stride`(= 幅×2)/ `reg` サイズ(= stride×高さ)

| mode | 解像度 | stride | reg サイズ |
|---|---|---|---|
| 16(1080p60)/ 15(1080p50)/ 7(1080i60) | 1920×1080 | 3840 | 0x3F4800 |
| 5 | 1280×720 | 2560 | 0x1C2000 |
| 19 | 1024×768 | 2048 | 0x180000 |

EDID(ディスプレイの対応解像度情報)を読んで自動で合わせる仕組みは無い。

#### 再ビルドせずに 1080 系の mode を試す
`boot.cmd` は環境変数 `hdmimode`(未設定なら 16)を使う。UART で自動起動を止めて:
```
setenv hdmimode 14
run bootcmd
```
14=1080p30(帯域半分)、15=1080p50、7=1080i60。気に入った値は `saveenv` で固定。720p 等の別解像度は DTS も変える必要がある(上の表)。


## 4. 判定基準と切り分け
| 観測 | 意味 / 次の確認 |
|---|---|
| `logo` 直後に HDMI が黒画面で同期する | U-Boot 側 OK |
| UART に `Starting kernel ...` の後なにも出ない | カーネル初期化(タイマ/IRQ/UART の推測値)が原因。HDMI 以前の問題。`earlycon` 出力の有無で切り分け |
| UART に `simple-framebuffer ... fb0: ...` が出るが HDMI が黒のまま | Linux 起動時にスキャンアウトが止まった、またはアドレス違い。U-Boot で `logo 5 2 4000000 1280 720 0 0`(スプラッシュ表示)と比較 |
| HDMI に文字が出るが色/桁ずれ | `format` / `stride` の誤り。`boot.cmd` の mode と DTS の width/height/stride/reg が一致しているか |
| 「信号なし」「非対応」と出る | ディスプレイが 1080p60(mode 16)を受けない。`boot.cmd` だけ mode 15(1080p50)/ 7(1080i60)に変える(DTS はそのまま)。それでも駄目なら下の「解像度を変える」で 720p(mode 5) |
| うっすらチラつく | 仮説: 1080p60 の RGB565 スキャンアウト(約 250MB/s)で共有 DDR の帯域が足りず、表示 FIFO が一瞬欠ける(純正 UI は 1080i = 半分の帯域)。純正 U-Boot に flicker filter・バス優先度の設定は見当たらない。下の手順で mode を変えて比べる |
| 文字がぼやける | mode 7 は 1080i(インターレース)なので mode 16 を使う。それでも甘い場合はテレビのオーバースキャン(画面サイズ「ジャストスキャン」「フルピクセル」「PC」等)を切る |
| `VFP support v0.3` が出ない、`Illegal instruction` | CPU が VFP 無し(ARM1176JZ-S)。Alpine armhf は動かない → 代替は soft-float の静的 busybox |
| `login:` が tty1/ttyS0 に出る | 目標達成。root はパスワード無し(`passwd` で設定) |

## 5. 未確認・限界
- **すべて静的解析と設計のみ**。カーネル/initramfs のビルドもこの環境では未実施(Alpine CDN・kernel.org にアクセス不可)。`alpine/build.sh` はダミーのミラーでの動作確認のみ(非 root UID・再実行も確認)。`docker/build-all.sh` の FAT イメージ作成部分(sfdisk/mkfs.vfat/mtools)は、この環境のコンテナから apt が使えず未実行。
- (更新: USB と Wi-Fi は [LINUX_PERIPHERALS.md](LINUX_PERIPHERALS.md) で対応)Linux 側の USB(EHCI 0x80200000)・Ethernet ドライバは未対応。rootfs は RAM 上で、**変更は再起動で消える**。`apk` もネットワークが無いので使えない。USB 上の rootfs に永続化するには EHCI/OHCI の IRQ とクロック/PHY 初期化の特定が必要(純正カーネルは暗号化されておりダンプからは読めなかった)。
- `hdmi.bin` が HDMI を常時サービスする必要があるか(ホットプラグ・EDID 再交渉)は不明。モニタ抜き差しで消える可能性がある。
- `logo` の color 6(ARGB8888)は未使用。RGB565 は純正で実績がある方を選んだ。

## 6. 純正 FW に「USB を挿して電源 ON だけで起動」する機能はあるか
**無い**。USB を自動で扱う処理は 2 つあるが、どちらも USB からは起動しない。ただし `fwimg` の app イメージを使えば UART 無しで USB 起動できる(3.3 節。下の「fwimg の app イメージ」)。

| 箇所 | 動作 | 出所 |
|---|---|---|
| `bootcmd` | `dcache on;run ledon; run show_logo;boots`。USB を見ない | `dump/spi.bin` の環境変数(工場既定値も同じ) |
| `boots` | NAND の Field イメージ(0x2400000)を RSA 検証して起動し、駄目なら Factory イメージ(0x400000)。USB は読まない。`nousb` は bootargs を加工するための文字列 | 逆アセンブル 0x020036c0–0x020039e4 |
| `main_loop` の `USB_UPDATES2` | 値が `1` なら 0x0200b894 を呼ぶが、`Performing USB_UPDATES2=1` を表示して 0 を返すだけ(GPL 版の起動時 USB 自動更新は製品版では空) | 逆アセンブル 0x02013258、0x0200b894 |
| `update` / `upgrade` / `usbboot` / `fatload` / `source` | コマンドとしてはあるが、起動の流れから呼ばれない(UART で手入力が必要) | U-Boot の文字列とコマンド表 |
| 純正 Linux の `usbupg -f` | 起動のたびに `normalrc` から呼ばれる。USB の `cameo_factory/factory.img` を `fwimg` で NAND に**書く**だけ | GPL ソース `dlink/usbupg/usbupg.c`、`dlink/script/normalrc` |
| 工場テスト `diags` | jffs2 の `diags/` に残っている。USB チェックは `usb_check.bin` を読んで合否を出すだけで、USB 上のものは実行しない。起動するのは `wifiaddr=02:02:02:02:02:30`、または `FIRST_BOOT=1` で SSID `dsmxx_cameo_factory` が見えるとき | `dump/nand.bin` の jffs2、`dlink/script/init.d/rcS` |

- NAND の Field/Factory イメージは暗号化されている(エントロピー 8.00 bit/byte)。`usbupg` で自作カーネルを書けたとしても、`boots` の RSA 検証に通らず起動しない(鍵が無い)。
### fwimg の app イメージ(GPL 版 `dlink/obj/fwimg` の逆アセンブル)
- 形式: U-Boot の旧形式ヘッダ(64 byte)と同じ並びだが、**全フィールドがリトルエンディアン**で magic が `0x70883967`(ファイル上は `67 39 88 70`)。CRC は zlib と同じ表で、初期値 0・最後の反転なし。GPL の `tools/mkimg -T app` の出力と `tools/mk_fwimg_app.py` の出力がバイト単位で一致することを確認した。
- 検査: magic、ヘッダ CRC、データ CRC、名前に `DSM232` か `CAMEO_MANUFACTORY` を含むこと、だけ(0x9e7c、0xa074)。署名検証は無い。
- type 12(app): データを `/mnt/jffs2/app.tar.gz` に書き、`cd /mnt/jffs2/;gunzip -f app.tar.gz;tar -xf app.tar -C /mnt/jffs2;rm -f app.tar` の後、`/mnt/jffs2/app.sh` があれば `chmod 755` して実行し、消す(0x9d98)。`fwimg -f`(`usbupg -f` が使う)でも同じ処理を通る。
- 他の type は `/dev/mtdN` に直接書く(`nvram`・`uboot`・`miniloader` も含む)ので使わない。
- `/dlink/env set 名前 値…` は値を 256 byte のスタック上のバッファにつなげて `/dev/mtd1`(U-Boot の環境変数。`dump/spi.bin` 0xc000)に CRC 付きで書く。長さの検査が無いので、値は 256 byte 未満にする。`env set 名前` だけなら削除。終了コードは成功しても常に 1(`main` が 1 を返す)なので、書けたかは `get` で読み戻して確かめる。

- 未確認: Linux 側は GPL 版 1.02.00 のソースを読んだ結果。実機の 1.02.29 は rootfs が暗号化されていて読めず、app イメージや `env` が GPL 版と同じかも確認できていない。
