# dsm232

D-Link DSM-232 (Celestial CNC1800L) に Linux 7.2 + Alpine Linux を載せる作業リポジトリ。

## USB から起動して HDMI にコンソールを出す
```bash
./build-usb.sh
```
`out/dsm232-usb.img` を USB メモリに書き、UART で 1 回だけ起動設定をする。詳細と注意: [docs/USB_BOOT_ALPINE.md](docs/USB_BOOT_ALPINE.md)(実機未検証)
