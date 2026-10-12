# SPI / NAND フラッシュ対応(Linux 7.2 / U-Boot 2026.07)

純正 BSP のドライバを解析し、現行の標準 API に合わせて再実装した。**ビルド確認のみ。実機未検証。**

## 1. ハードウェア(BSP から確認)
### NAND コントローラ(EMIF/DaVinci 系)
| 項目 | 内容 |
|---|---|
| データ窓 | `0xA4000000`(32MB)。データ=窓先頭、コマンド=+0x04(CLE)、アドレス=+0x08(ALE)。CS 毎に +`BIT(26)` |
| レジスタ | `0x80100000`(0x48 byte): CEn_CFG_0 = n×0x0C(bit9 = CE 強制 Low)、STATUS 0x30(bit0=ready)、MODE 0x38、ECC_CODE 0x40、ECC_CNT 0x44、ECC_ADDR 0x48 |
| ECC | HW 1-bit Hamming / 512 byte / 3 byte。ECC_ADDR にデータ窓アドレスを設定すると、その窓へのアクセスを監視して符号を生成 |
| BBT | フラッシュ上 BBT、最終ブロック側(`NAND_BBT_LASTBLOCK`) |
| パーティション(DSM-232) | `3m(Kernel),504m(fs),3m(kernel_update),2m(bad_blks_table)`(純正 bootargs) → NAND 512MB |
ミニローダーも同じコントローラの HW ECC 形式で NAND を読む(ミニローダー内 NANDC アクセスを確認)。

### SPI コントローラ
Synopsys **DesignWare SSI**(`0x80150000`, IRQ11, AHB2_SPI_TCLK = 94.5MHz)。純正ドライバは**レジスタを 16bit でアクセス**(`iowrite16`/`ioread16`)。DMA は DW DMAC(+0x4000)。SPI NOR は標準 JEDEC コマンド(0x9F, 0x03/0x0B, 0x02, 0x20/0xD8, 0x06 …)。
→ Linux は `spi-dw-mmio` + `spi-nor`、U-Boot は `designware_spi` + `spi_flash` で標準化できる(独自 MTD ドライバ `spidev_cnc18xx.c` 2105 行は不要)。

## 2. ECC の「古い」方式と「新しい」方式
| | 旧(レガシー) | 新(標準) |
|---|---|---|
| ECC | SoC HW 1-bit Hamming、512B/3B | 汎用ソフトウェア ECC(Linux/U-Boot の MTD 標準)。例: BCH-4 / 512B |
| フラッシュ形式 | 純正と同じ。**既存 NAND の内容・ミニローダー・純正 U-Boot/Linux と互換** | 純正と**非互換**(全面フォーマット必要) |
| DT 指定 | 何も書かない(既定) | `nand-ecc-mode = "soft"; nand-ecc-algo = "bch"; nand-ecc-strength = <4>; nand-ecc-step-size = <512>;` |
| Linux DTS | `cnc1800l-dsm232.dts` | `cnc1800l-dsm232-newecc.dts` |
| U-Boot | `dsm232_defconfig` / `cnc1800l-dsm232.dts` | `dsm232_newecc_defconfig` / `cnc1800l-dsm232-newecc.dts` |

DT のプロパティは Linux と U-Boot で**同一**(U-Boot の rawnand コアも `nand-ecc-*` を解釈する)。ドライバは両方式を同一バイナリで持ち、DT で切り替わる。

### 「標準 Hamming に置き換えれば済む」とはならない(計算で確認)
純正 HW ECC のデコーダ(`correct()`)で、Linux 標準ソフト Hamming(512B)の符号の単一ビット誤りを位置特定できるか全数検査:
`tools/ecc_compat/run.sh <linux-tree>` → **sm_order 0/1 とも 0/4096**。HW の符号配置は Linux 標準と異なる。よって:
- **ミニローダーが読む領域(U-Boot を NAND に置くならその領域)は旧方式が必須**。
- カーネル/rootfs(Linux だけが読む領域)は新方式にできるが、**1 チップで ECC 方式は 1 つ**しか選べない(パーティション毎の切替は不可)。両立させたい場合は、U-Boot が読む領域を別方式で扱うか、ブートは SPI に残す、といった設計が必要。
- 新方式にする場合、NAND 内容は全消去・再書込が前提。旧方式から段階的に移すなら、まず旧方式で動作確認する。

## 3. 実装
| 対象 | 追加物 |
|---|---|
| Linux 7.2 (`linux-7.2/patches/0002-*`) | `drivers/mtd/nand/raw/cnc1800l_nand.c`(`exec_op` 方式、旧=HW Hamming / 新=core の soft ECC)、DT バインディング `celestial,cnc1800l-nand`、`spi0`(`snps,dw-apb-ssi`, `reg-io-width=<2>`)+ `jedec,spi-nor`、NAND パーティション、`cnc1800l_defconfig` に MTD/NAND/SPI/BCH/UBI |
| U-Boot 2026.07 (`uboot-2026.07/patches/0002-*`) | `drivers/mtd/nand/raw/cnc1800l_nand.c`(DM・旧API の `cmd_ctrl` 方式)、`designware_spi` に `reg-io-width` 対応(16bit)、DT(spi/nand/clock)、`dsm232_defconfig` と `dsm232_newecc_defconfig`(`sf`/`nand`/`mtd` コマンド有効) |
| 検証用 | `tools/ecc_compat/` |

U-Boot バイナリは旧/新とも約 347KB(`0x5FF00` = 389,888 の上限内。余裕は約 40KB)。

## 4. 未検証・要確認
- NAND の CE 制御は `CEn_CFG_0` bit9 を操作(Linux は常時アサート、U-Boot は純正と同様に操作ごと)。タイミングレジスタ(CEn_CFG_1/2)は設定していない(ミニローダー/ブート済み設定を前提)。
- 実機の NAND 型番・ページサイズ・ID が標準 ID テーブルで認識されるか(純正は `nand_ids.c` を追加改変)。認識されない場合は ID 追加が必要。
- 16bit 版 DW SSI で DR(FIFO)も 16bit アクセスが正しいか、`dw_apb_ssi` の RX FIFO 深さ検出が通るか。
- SPI-NAND ではなく並列 NAND 前提。
