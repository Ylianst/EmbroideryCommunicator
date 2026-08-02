# Background History

It all started when I got a great deal for my Bernina Artista 180 at an estate sale. The machine was in excellent condition. Knowing that is had a serial port for embroidery was very interesting, I saw it as a different type of 3D printer I could use for all sorts of projects. I quickly learned after the purchase that the software was not great. I also noticed a lot of people asking the same question about software availability for this machine. I searched the Internet quite a bit and found very little information.

I am sure many people had the idea that maybe the serial communication protocol could be reverse engineered. I decided to take on the challenge. I started by connecting my development computer between the Bernina and a very old Windows XP machine.

![image](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/images/setup01.jpg)

Here, I use two Serial-to-USB adapters and a null modem connector. So, I have the Bernina on one side and the Windows XP machine on the other side. I run a serial port sniffer that I built on my development computer to captures all communication between the Bernina and the Windows XP software. The first test where not a success however. The Windows XP machine will try various baud rates and then tell the sewing machine to switch from 19200 baud to 57600 baud. This was very puzzling and messed up my serial port sniffer. I did end up figuring it out and starting to decode the protocol.

![image](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/images/serial-setup.png)

I started decoding the lower-level protocol by analyzing the captured serial data. This involved identifying the various commands and responses exchanged between the Bernina and the Windows XP software. I ended up writing up this [protocol documentation](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/SerialProtocol.md). At the same time, one of my friends had fixed a few of these machines and had knowledge of the motherboard and the type of CPU used in the machine (H8 CPU). A lot of the data on that CPU is public, so, I could used that if needed.

The next problem was discovering that in reality, there are two computers here. The sewing machine and the embroidery module both run a full H8 CPU with their own RAM and all. I had to discover and start controlling the serial session as it could be redirected to one or the other of the CPU's. It's also interesting that the serial port is really a debug port for the machine. Developers must have used it to patch firmware and do all sorts of development. You can read/write to the entire memory. I also starting inserting a PC Card and taking a look at how it works.

At first, it all looks like a big mess of HEX numbers, but after a while it all looks very familiar. You can read/write and make function calls. I did not know that the function name was, but started having an idea what each call probably did. I then wrote the [higher level protocol document](https://github.com/Ylianst/EmbroideryCommunicator/blob/main/docs/HighLevel.md). That is when I was pretty sure coding my own software was possible.

So, I started coding Embroidery Communicator. It's mostly coded using AI with Visual Studio, Cline and Claude Sonnet 4.5. So, that did speed up things a lot. Most of the manual work was UI related, but everything else is AI. Another lucky break was that the Bernina internally uses the .EXP embroidery format, which is a public format. Lots of tools support it. Great! I could build my own viewing tool to validate the pattern is correct before uploading.

There is still some work to do. I don't have a read/write PC card and so, this is something others may need to software to support. Getting and displaying the amount of remaining free space would be nice, etc. Please feel free to open issues on GitHub if you have any information, questions or if you just find this software useful.
