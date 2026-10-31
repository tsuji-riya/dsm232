# dsm232

D-Link DSM-232 (Celestial CNC1800L) に Linux 7.2 + Alpine Linux を載せる作業リポジトリ。

## USB から起動して HDMI にコンソールを出す
```bash
./build-usb.sh
```
`out/dsm232-usb.img` を USB メモリに書き、UART で 1 回だけ起動設定をする。詳細と注意: [docs/USB_BOOT_ALPINE.md](docs/USB_BOOT_ALPINE.md)

reboot・USB・Wi-Fi・Linux 側での HDMI 初期化: [docs/LINUX_PERIPHERALS.md](docs/LINUX_PERIPHERALS.md)(実機未検証)
