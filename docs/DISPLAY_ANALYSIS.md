# 表示系(DF / HDMI)解析メモ

**結果(実機確認済み)**: AVI InfoFrame を正しい値(VIC 16、BT.709、16:9、YCbCr444、アンダースキャン、IT コンテンツ)に書き換えた `boot.cmd` で、1080p60 のうっすらしたチラつきが**消えた**。原因は仮説 A(テレビが 1080p60 を「640×480 の映像」と申告され、映像処理を誤っていた)。HDCP(仮説 C)・TMDS(仮説 B)の切り分けは不要になった。VIC・IT コンテンツ・アンダースキャンのどれが効いたかは個別には確認していない。

**解析の経緯**: 純正 U-Boot の `logo` と、その末尾で実行される `hdmi.bin` を CPU エミュレータで実行し、表示まわりのレジスタアクセスをすべて記録した。1080p(mode 14/15/16)では **`hdmi.bin` が誤った AVI InfoFrame を送っている**(1080p60 なのに「640×480・BT.601・アスペクト比なし」と申告)ことが分かった。`alpine/boot.cmd` で `logo` の直後に正しい InfoFrame へ書き換える。チラつきが直るかは**実機未確認**(下の「検証」)。

## 1. 方法
- 対象: `dump/nand.bin` の 0x20000 にある純正 U-Boot 2011.06(0x02000000 にリンク)と、その後ろに連結された `dvu.bin` / `hdmi.bin`(ARM の位置独立コード、U-Boot の jump table `gd->jt` = `gd+0x64` 経由で printf / simple_strtoul / memset(45) / `clock_hdmi_reset`(46) を呼ぶ。46 は以前「TVE 書込」と誤認していた。GPL の U-Boot パッチ `include/_exports.h` で `memset` の直後に追加されているのが `clock_hdmi_reset` で、引数も 0→1 のリセットパルスの形)。
- `tools/display_emu/run.sh`: Unicorn で `logo <mode> 2 ...` を実行し、MMIO の読み書きを全て記録。周辺の模擬は最小限: SiI `SYS_STAT`=0x07(HPD+RSEN+P_STABLE)、DDC で一般的な 1080p テレビの EDID(CEA 拡張 + HDMI VSDB、`edid.py`)を返す。
- 名前付けの裏付け: エミュレート中に純正のデバッグ出力(`Reg->df_gfx_control_reg.bits.iGfxEna = 1`、`Display configurate complete!`、`DDC Time Out!` 等)がそのまま出る=実際の経路を通っている。

## 2. 分かったハードウェア
| ブロック | アドレス | 内容 |
|---|---|---|
| DF(Display Feeder) | 0xB1800000 | +0x00 更新ロック(1→設定→0)。GFX レイヤ0: +0x40 制御(0x49)、+0x44 色形式(2=RGB565)、+0x48 α(0x3FF)、+0x58 先頭アドレス、+0x5C pitch、+0x60 X 範囲(終端含む)、+0x64 Y 範囲。出力タイミング: +0x340 制御(bit5=インターレース)、+0x344 水平 有効/総数、+0x348 垂直 有効/総数、+0x34C/+0x350 同期・ポーチ |
| 画素クロック | 0xB2100148 | 0x4442 = 74.25MHz(720p/1080i/1080p30)、0x2242 = 148.5MHz(1080p50/60)。他に 0xB2100108=0x9502、0xB2100140/0x20C/0x200 を操作 |
| HDMI TX | 0x80400000 | **Silicon Image 系コア**(TI OMAP4 の HDMI core と同じレジスタ配置: `drivers/gpu/drm/omapdrm/dss/hdmi4_core.h` がそのまま読める)。I2C 風アドレス 0x39(=0x72 ページ)→ +reg×4、AV ページ → 0x80400400 + reg×4。0x09 SYS_STAT、0x70 INTR_STATE、0xEC–0xF5 DDC マスタ、AV 0x2F HDMI_CTRL、0x3E/0x3F パケット有効化、0x40–0x50 AVI InfoFrame |
| TVE0/TVE1 | 間接アクセス | アナログ出力。HDMI 経路には関係しない |

### `logo` の mode と実際の出力
| mode | DF 出力 | 画素クロック | `hdmi.bin` の AVI InfoFrame |
|---|---|---|---|
| 5 | 1280×720p60 | 74.25MHz | VIC 4、BT.709、16:9 ✅ |
| 7(純正「1080P」) | 1920×1080i60 | 74.25MHz | VIC 5、BT.709 ✅ |
| 14 | 1920×1080p30 | 74.25MHz | **VIC 4(720p)** ❌ |
| 15 | 1920×1080p50 | 148.5MHz | **VIC 3(480p)、BT.601** ❌ |
| 16 | 1920×1080p60 | 148.5MHz | **VIC 1(640×480)、BT.601、アスペクトなし** ❌ |

`hdmi.bin` は mode 番号を自前の表(14→20、15→21、16→22)に写すが、その表は 1080i までしか正しくない。純正製品は 1080i までしか使っていなかったと考えられる。

## 3. 対策(`alpine/boot.cmd`)
`logo` の直後に、`hdmi.bin` と同じ手順(AVI 無効化 → 書込 → 有効化)で AVI InfoFrame を書き直す:
- DB1=0x52: YCbCr 4:4:4(DF の出力形式どおり)、アクティブ領域あり、**アンダースキャン**(テレビ側の拡大縮小を止めるよう要求)
- DB2=0xA8: BT.709、16:9
- DB3=0x80: **IT コンテンツ**(PC 画面として扱い、ノイズ除去・動き補間などの映像処理を止めるよう要求)
- DB4: 実際の VIC(16 / 31 / 34)、DB5=0: グラフィックス、画素繰り返しなし

チェックサムは `tools/display_emu/avi_check.py` が検証し、`alpine/build.sh` から毎回実行される。

### スクリプトの検証(純正 U-Boot のシェルで実行)
純正 U-Boot 2011.06 の hush は、`$` を含む行を**変数展開後に空白で連結して再解析**する(`common/hush.c` の `child->sp` 処理)。そのため空の変数は引数ごと消え、`test -z "${x}"` は `test -z`(引数不足で偽)、`test "${x}" = 16` は `test = 16`(真)になる。最初の版の `boot.cmd` はこれで `hdmimode` が設定されず、`logo` の引数がずれて HDMI が起動しなかった(実機ログ `mode = 2, picture_color_mode = 101711872`)。比較は `x${var} = xVALUE` の形で書く。

`tools/display_emu/run_script.py` は `boot.cmd` を**純正 U-Boot 自身の hush と test/setenv/run/mw**で実行する(イメージの `.rel.dyn` を適用、`set_default_env` で環境を初期化、`usb`/`fatload`/`bootm`/`logo`/`md` はスタブ)。旧版の失敗を実機と同じ形で再現し、現版はプリセット(なし / `hdmimode=14` / `hdmimode=7` / `hdcpoff=1` / 組合せ)で期待どおりのコマンドとレジスタ書込になることを確認した:
```
tools/display_emu/run.sh 16                       # out/display_emu/uboot.bin を作る
python3 -I tools/display_emu/run_script.py out/display_emu/uboot.bin alpine/boot.cmd hdmimode=14
```
VID_CTRL(0x72:0x48)への書込は削除した(最終状態で CSC 無効なので効果がなく、意味も未確認)。

## 4. チラつきとの関係(仮説と検証)
- 仮説 A(今回の対策): テレビは 1080p60 の信号を「640×480 の映像」と申告されており、拡大縮小・映像処理の判断を誤っている。静止した文字にうっすら揺れが出る典型原因は、テレビ側のノイズ除去・動き処理・オーバースキャン拡大で、IT コンテンツ + アンダースキャンの申告で止まることが多い。
- 仮説 B: 148.5MHz での TMDS の余裕不足。純正は 74.25MHz までしか使っておらず、TMDS 設定(0x72:0x82=0x25, 0x83/0x84)は全 mode で同じ。**mode 14(1080p30)は DF 設定が mode 16 と同一でクロックだけ半分**なので、14 でチラつきが消えるならこちら。
- 否定済み: メモリ帯域(dd 負荷で変化なし)、カーソル点滅(停止で変化なし)、インターレース(mode 16 はプログレッシブ)。

### 実機での確認結果
- `logo 16` 直後の `md.l 0x80400500 9` が `82 02 0d d5 51 48 00 01 00` で、**エミュレーションと完全に一致**(VIC=1 の不具合は実機でも発生)。
- 実機ではテレビとの **HDCP 認証**が成立する(`{DownStreamAuthState}: Authenticated`)。エミュレーションは HDCP 受信機(DDC 0x74)を模擬していないのでこの経路は未解析。Linux 起動後は HDCP のリンク監視を誰もしないため、仮説 C として `setenv hdcpoff 1` で暗号化を止めて比較できるようにした(HDCP_CTRL 0x72:0x0F = 0x8040003C に 0、`hdmi.bin` 自身が非 HDCP 経路で書く値)。

### 検証手順(UART)
1. 純正の値が実機でもエミュレーションどおりか(自動起動を止めて):
   ```
   mw.w 0x6100000 0 1
   logo 16 2 0x6100000 1 1 0 0
   md.l 0x80400500 9
   ```
   期待: `82 02 0d d5 51 48 00 01 00`(VIC=1)。違えば以降の前提を見直す。
2. 新しい `boot.scr` で起動後のチラつきを確認。改善しなければ 1 つずつ変えて比較:
   - `setenv hdcpoff 1; run bootcmd`(仮説 C: HDCP)
   - `setenv hdcpoff; setenv hdmimode 14; run bootcmd`(仮説 B: 148.5MHz の TMDS)
3. テレビの入力情報で「1080p / 60Hz」、テレビによっては「PC」「ゲーム」扱いになっているかを確認。
