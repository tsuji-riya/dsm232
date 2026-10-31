# USB メモリから Linux 7.2 + Alpine Linux を起動し HDMI にコンソールを出す

**結論**: 純正 U-Boot(2011.06)の `logo` で HDMI を起動し、そのフレームバッファを Linux の `simple-framebuffer`(fbcon)で引き継ぐ。カーネル(`uImage`)と Alpine の initramfs(`uInitrd`)は U-Boot が USB の FAT から RAM に読む。NAND/SPI には一切書かない(`saveenv` を使う任意手順を除く)。**実機未検証**。

## 1. 根拠(`dump/` の解析で確認したこと)
| 事実 | 出所 |
|---|---|
| 純正 U-Boot は NAND 0x20000 に格納され、0x02000000 にリンクされている(2 本目は 0xA0000) | `dump/nand.bin` のベクタテーブル |
| `logo <mode> <color> <addr> <w> <h> <x> <y>`(0x020042dc)は **0x0C000000 を pitch×高さだけ 0 クリア**し、画像を矩形コピーし、末尾で U-Boot に付加された `hdmi.bin` を実行する | 逆アセンブル 0x02004224–0x020045b0 |
| mode 5 = 1280×720、pitch 2560、color 2 = 2 byte/pixel(color 6 は 4 byte/pixel) | 同上(mode 表 0x02004338)|
| color 2 は **リトルエンディアン RGB565** | NAND 0x200000 の純正スプラッシュ(1280×720×2)を RGB565 LE として描画すると正しく表示された |
| 純正の起動: `bootcmd=dcache on;run ledon; run show_logo;boots`、`show_logo=nand read 4000000 200000 0x1C2000; logo 5 2 4000000 1280 720 0 0` | `dump/spi.bin` の環境変数 |
| `bootm` は ATAG_CMDLINE / ATAG_MEM / ATAG_INITRD2 を渡し、`initrd_high` を読む。`fatload`・`usb`・`source`・`mw` あり | U-Boot 内のタグ定数と文字列 |
| CPU は TrustZone 付き ARMv6(SCR = CP15 c1,c1,0 を書いている) → ARM1176 と整合 | U-Boot の `mcr` 命令 |

## 2. 変更内容
- `linux-7.2/patches/0003-*`: DTS の `/chosen` に `simple-framebuffer`(0x0C000000, 1280×720, stride 2560, `r5g6b5`)、`mem=137M`、defconfig に `VFP` / `VT` / `FB_SIMPLE` / `FRAMEBUFFER_CONSOLE`。
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
結果: `out/dsm232-usb.img`(64MB、MBR + FAT16 に `uImage` / `uInitrd` / `boot.scr`)。同じ 3 ファイルが `out/usb/` にもある。初回はカーネル取得とビルドで数十分。カーネルソースは `.cache/linux-src` に残り、2 回目以降は差分ビルド。

### 3.2 USB メモリに書く(中身は全部消える)
Linux: デバイス名を `lsblk` で必ず確認してから。
```bash
sudo dd if=out/dsm232-usb.img of=/dev/sdX bs=4M conv=fsync status=progress
```
Windows / macOS: balenaEtcher か Rufus(DD モード)で `out/dsm232-usb.img` を書く。

### 3.3 初回は UART から手動で(フラッシュは書かない)
純正 bootcmd は USB を見ないので、**最低 1 回は UART 操作が必要**。自動起動を止めて:
```
usb start
fatload usb 0:1 0x6000000 boot.scr
source 0x6000000
```
### 3.4 以後は「USB を挿して電源 ON」だけにする
SPI の環境変数領域だけを書き換える(1 回だけ)。USB を抜けば純正起動に戻る。
```
setenv bootcmd 'usb start; if fatload usb 0:1 0x6000000 boot.scr; then source 0x6000000; fi; dcache on;run ledon; run show_logo;boots'
saveenv
```
元に戻す: `setenv bootcmd 'dcache on;run ledon; run show_logo;boots'; saveenv`

## 4. 判定基準と切り分け
| 観測 | 意味 / 次の確認 |
|---|---|
| `logo` 直後に HDMI が黒画面で同期する | U-Boot 側 OK |
| UART に `Starting kernel ...` の後なにも出ない | カーネル初期化(タイマ/IRQ/UART の推測値)が原因。HDMI 以前の問題。`earlycon` 出力の有無で切り分け |
| UART に `simple-framebuffer ... fb0: ...` が出るが HDMI が黒のまま | Linux 起動時にスキャンアウトが止まった、またはアドレス違い。U-Boot で `logo 5 2 4000000 1280 720 0 0`(スプラッシュ表示)と比較 |
| HDMI に文字が出るが色/桁ずれ | `format` / `stride` の誤り(1080p にするなら `logo 7 2 ...` と DTS を 1920×1080, stride 3840, reg サイズ 0x3F4800 に) |
| `VFP support v0.3` が出ない、`Illegal instruction` | CPU が VFP 無し(ARM1176JZ-S)。Alpine armhf は動かない → 代替は soft-float の静的 busybox |
| `login:` が tty1/ttyS0 に出る | 目標達成。root はパスワード無し(`passwd` で設定) |

## 5. 未確認・限界
- **すべて静的解析と設計のみ**。カーネル/initramfs のビルドもこの環境では未実施(Alpine CDN・kernel.org にアクセス不可)。`alpine/build.sh` はダミーのミラーでの動作確認のみ(非 root UID・再実行も確認)。`docker/build-all.sh` の FAT イメージ作成部分(sfdisk/mkfs.vfat/mtools)は、この環境のコンテナから apt が使えず未実行。
- Linux 側の USB(EHCI 0x80200000)・Ethernet ドライバは未対応。rootfs は RAM 上で、**変更は再起動で消える**。`apk` もネットワークが無いので使えない。USB 上の rootfs に永続化するには EHCI/OHCI の IRQ とクロック/PHY 初期化の特定が必要(純正カーネルは暗号化されておりダンプからは読めなかった)。
- `hdmi.bin` が HDMI を常時サービスする必要があるか(ホットプラグ・EDID 再交渉)は不明。モニタ抜き差しで消える可能性がある。
- `logo` の color 6(ARGB8888)は未使用。RGB565 は純正で実績がある方を選んだ。
