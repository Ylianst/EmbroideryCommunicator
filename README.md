> [!NOTE]
> Official web site at: [https://ylianst.github.io/EmbroideryCommunicator/](https://ylianst.github.io/EmbroideryCommunicator/).

# Embroidery Communicator

![image](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/images/EmbroideryCommunicator.png)

In the late 90's Bernina released the Artista 180 embroidery machine. At the time it costs 3000 to 4000 US dollars and is still available today second hand for 800$ and up. This robust machines can be connected to a PC via a serial port (RS232) and Bernina provided at the time Windows application to upload embroidery patterns. Sadly, the software of the time only works with Windows XP and so this open source tool was created to fill the gap. If your curious how I built this software, [read the history](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/History.md).

## Download

**Run it now in your browser: [Launch the Web App](https://ylianst.github.io/EmbroideryCommunicator/app/)** (requires a Web Serial–capable browser such as Chrome or Edge).

- [Windows (x64) (.zip)](https://github.com/Ylianst/EmbroideryCommunicator/releases/latest/download/EmbroideryCommunicator-windows-x64.zip). Runs on 64-bit Windows 10 and 11.
- [macOS (.dmg)](https://github.com/Ylianst/EmbroideryCommunicator/releases/latest/download/EmbroideryCommunicator-macos.dmg). Universal binary.
- [Linux x64 (.tar.gz)](https://github.com/Ylianst/EmbroideryCommunicator/releases/latest/download/EmbroideryCommunicator-linux-x64.tar.gz) | [.deb](https://github.com/Ylianst/EmbroideryCommunicator/releases/latest/download/EmbroideryCommunicator-linux-x64.deb) | [.AppImage](https://github.com/Ylianst/EmbroideryCommunicator/releases/latest/download/EmbroideryCommunicator-linux-x64.AppImage).
- [Linux ARM64 (.tar.gz)](https://github.com/Ylianst/EmbroideryCommunicator/releases/latest/download/EmbroideryCommunicator-linux-arm64.tar.gz) | [.deb](https://github.com/Ylianst/EmbroideryCommunicator/releases/latest/download/EmbroideryCommunicator-linux-arm64.deb) | [.AppImage](https://github.com/Ylianst/EmbroideryCommunicator/releases/latest/download/EmbroideryCommunicator-linux-arm64.AppImage).
- [Web Version](https://ylianst.github.io/EmbroideryCommunicator/app/). Browsers with Web Serial support (Chrome & Edge).

## Features

- Auto-detect new serial ports when USB-to-Serial adapters are connected.
- View machine information, including firmware version.
- List embroidery patterns stored in the embroidery module and PC card.
- Upload embroidery patterns in .EXP format to the embroidery module.
- Download embroidery patterns from the embroidery module and PC card in .EXP format.
- Delete embroidery patterns from the embroidery module and PC card.

## Tested Machines

So far, this software has only been tested on my own machine:

- **Bernina Artista 180 with firmware 3.01** on both sewing machine and embroidery module. Uploads tested to the memory in the embroidery module. Read-only PC cards have been tested.
- Other machines may work as well, but have not been tested.

## Getting Started

- Get yourself a USB-to-Serial DB9 adapter, they cost 9 to 15$ US online.
- Download the software for your platform from the [latest release](https://github.com/Ylianst/EmbroideryCommunicator/releases/latest), extract and run.
- If you connect the USB-to-Serial cable while the software is running, it will auto-detect the new serial port.
- Hit "Connect" to connect to the embroidery machine.
- You should see the machine information appear and existing patterns in the embroidery module and PC card.
- I suggest using [InkScape](https://inkscape.org/) with the [Ink/Stitch](https://inkstitch.org/) extension to create or edit embroidery patterns. Work in Ink/Stitch using the .SVG format, and when ready export to .EXP format to upload to the machine.

## Extras

For advanced users, you can help contribute and access your embroidery machine over the network.

- [Memory Dump](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/MemoryDump.md) - Copy the entire memory content of the sewing machine and embroidery module to a file.
- [Live Debug](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/Debug.md) - See all of the serial traffic and commands sent and received on the serial port.
- [Serial Capture](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/SerialCapture.md) - Capture traffic between original software and the machine.
- [Embroidery Relay](https://github.com/Ylianst/EmbroideryCommunicator/tree/main/relay) - For advanced users, this allows you to talk to your older Bernina machine over the network.

## More Information

If you have any technical information on this machine, have test results or any question, [please open an issue in GitHub](https://github.com/Ylianst/EmbroideryCommunicator/issues). The binary files in the zip file are code-signed. This tool is based on [protocol work done here](https://github.com/Ylianst/EMB-Serial).
