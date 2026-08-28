# Low-Level Serial Protocol

This is the serial protocol between "software" and "machine". The machine starts at 19200 baud, but the software will instruct it to move to 57600 baud. All serial communication is N,8,1 with no Handshake, so CTS/DTS does not play a factor. The protocol is generally ASCII based except when binary data is sent.

## Bernina CPU

- The Bernina Artista uses a Hitachi H8 CPU. CPU part number is H8/3003, HD6413003F16.
- Programming Manual: https://www.renesas.com/en/document/gde/h8300-programming-manual
- The CPU manual is at: https://www.renesas.com/en/document/mah/h83003-hardware-manual
- CPU emulator: http://bitsavers.informatik.uni-stuttgart.de/test_equipment/hp/64700/64784-97011_H8_3003_Softkey.PDF
- Documents and tools: https://www.renesas.com/en/products/h8-3003?tab=documentation
- GCC compiler support: https://h8300-hms.sourceforge.net/
- Memory map: 0FFD10 - 0FFF0F, page 501 of the manual.
- The DMA controller regs are 0xFFFF20 - 0xFFFF5F.

## General Concepts

- The software sends commands to the machine one character at a time and waits for the same character to be echoed back before sending the next character.
- The software does not echo back traffic from the machine, only the machine echoes software.
- If the machine does not understand a character from the software, it will send back the letter "Q", "?" or "!", otherwise it will echo back the character that the machine sent.
- If there is a problem, the software must send "RF?" and the machine will echo back "RF?", you are then ready to send the next command. If the software starts sending a command and gets a "Q", "?" or "!" echo back, you have to stop and send a "RF?" waiting for each character to be echoed before resuming. "RF?" can also be used as an command to detect that the machine is listening on the serial bus before sending other commands.
- The software seems to sometimes generate invalid Read commands, they are R commands followed by bytes that are not valid for a HEX value. In this case, the machine returns error response and the software seems to try again with a valid read value.
- When the machine first starts, it will be at 19200 bauds and send out "BOSN" (In HEX: 42 4F 53 4E)
- When the machine turned off, I see a single 0x00
- The sewing machine and embroidery modules have there own CPU and you can select to which one to communicate with on the serial port using the Embroidery Session Start/Stop commands.

## Baud Rate Detection and Change

The machine starts at 19200 bauds but can be instructed to change to 57600 baud. When the software first starts, it had to figure out what baud rate the machine is at. The software will send data in 4 groups at different baud rates.

```
52 52 52 52 52                 - at 19200 bauds (RRRRR)
52 52 52 02 66 03 6B 52 52 52  - at 57600 bauds
52 52 52 02 66 03 6B 52 52 52  - at 115200 bauds
52 52 52 52 52                 - at 4800 bauds
```

The software is trying 4 different baud rates to see if the machine will answer on one of them. It's trying to send the "RF?" command. If the software gets back a "RF?" echo, it will start talking to the machine. Once the machine is detected we can change to 57600 baud using the "TrMEJ05" command like this:

TrMEJ05   - Echoed back causes baudrate change to 57600 bauds.
-- Baudrate change occurs, the machine will send "BOS" (42 4F 53) at 57600 bauds.
EBYQ      - Echoed back + "O", which is the confirmation that we moved over to the new speed.

After the machine sends "BOS" at 57600 bauds you have very little time to send the "EBYQ" confirmation or the machine will revert to sending "BOS" at 19200 bauds periodically (around every second). So, you may need to be quick to change baudrates and send "EBYQ" to the machine to keep it at the new speed. If the machine goes back to 19200 baud and sends "BOS" periodically, the machine is no longer is a resoverable state, even the original Windows XP software will not be able to talk to it anymore and so, you have to turn off/on the machine to have it reset to 19200 baud.

Once you are in 57600 baud speed, it's possible to go back to 19200 baud using the "TrMEJ04" with the same process as above. It looks like this speed commands are:

```
"TrMEJ04" = 19200 bauds.
"TrMEJ05" = 57600 bauds.
```

So you can switch to and from each baud rates. It's important to note that when switching baud rate you may also start a emdroidey module session at the same time. So, once you switch baud rates, you may want to do a "R57FF80" command to see what mode you are in. See "Emboidery Module Session Start" below.

## The Protocol Reset Command

The "RF?" command causes the machine to reset it's protocol state. If you send a command and get "Q", "?" or "!" as an echo back, something is not quite right and you may be stuck until the protocol reset command is sent, only then can you start sending more commands. This command can also be used to initially find the machine on the serial bus.

## The Read Command (R)

A "Read" command will cause the machine with return 32 bytes of data starting at the address specified by the command. This is fixed, all "Read" commands return this ammount of data back. The read command starts with a capital R followed by 6 characters that are the address to the read. Here are two value examples:

```
"R200100"  (52 32 30 30 31 30 30)
"RFFFED9"
```

- When receiving a "Read" command, the machine will respond with 65 characters. The data block is HEX encoded followed by the character "O". For example:

```
"R200100" will return:
"53524D5630332E30312000467269747A204765676175662041470D004F637420O"

"RFFFED9" will return:
"8300330000000000000000000000000200000100000000000000000000000000O"
```

## The Large Read Command (N)

In addition to the read command, there is a "Large Read" command that worked the same way as "Read", but return 256 bytes of binary encoded data instead of 32 bytes of HEX encoded data. The command in "N" on the serial protocol followed by 6 HEX characters for the address. Here are two examples:

```
"N0240F5" will return:
"LisaV45Rev8.....................BlackBoardv45Rev61..............SwissBlock v45 rev6a............Zurichv45rev6a..................ALICE v6m Rev5 Firmware v3......BAMBOO v6m Rev8 Firmware v3.....Lg5060..........................Cs021...........................O"

"N0241F5" will return:
"Fl081...........................Nv772...........................Nv722...........................Nv799...........................Bd130...........................Bd115v2.........................Cr070...........................Cr060...........................O"
```

Like the "Read" command, the "Large Read" command also completes the block with a capital "O". So, 256 characters of data are returned along with the ending capital "O".

When downloading a lot of data, the software will use the Large Read (N) command a lot, but if the last block that needs to be downloaded is 32 bytes of less, it will switch to used the Read (R) command to complete the download.

## The Write Command (W)

It's also possible to write using the W command. Just like the read command, it's a W followed by 6 HEX characters for the address followed by the data to write in HEX and "?" to complete the command. Here are two examples of write commands:

```
"W0201E101?"
"WFFFED00061?"
```

The first command will write 0x01 to address 0x0201E1, the second command will write 0x0061 to address 0xFFFED0. There is no confirmation given that the write operation was a success, so often times the software with perform a read (R) operation after a set of writes to make sure the operation was a success.

## The Upload Command (PS)

In order to upload a lot of data from the software to the machine, the PS command is used. The command is "PS" followed by 4 HEX characters, there are the 4 starting HEX characters of the destination address, with 00 being added to complete the address. So, "PS028F" will upload 256 bytes of binary data at address 0x028F00. The sequence on the serial port is like this:

- Software sends command "PS028F".
- Machine replays with "OE".
- Software sends 256 bytes of data.
- Machines replays with "O".

If a problem occurs, the machine sends "Q" back, software sends a series of "RF?" until it works and then tries again. Note that this command can compliment the Write (W) command that can be used to write at exact location. We will see the software use the Write command a few times until it gets to the next 256 byte memory boundary and then will use the Upload (PS) command.

## The Sum Command (L)

This command will return the sum of all memory bytes stating at a given address for a given length. The L command is followed by 12 characters in HEX format, the 6 first at the address and the next 6 are the length. The machine will reply with 8 HEX characters followed by "O" when competed. For example:

```
"L0240D5000360" will reply "00004CC9O"
```

This command tells the machine to start at position 0x0240D5 and sum the next 0x000360 bytes. In this case, the result is 0x4CC9. You can easily verify this by issuing a read command at for example 0x200100, you get this:

```
R200100 --> 4E4D4D5630332E303100456E676C6973682020202020004265726E696E612045
```

Then issue a Sum command for 0x200100, Length 1 like this: L200100000001. The response will be 0xAE since you sum only one byte. You can then issue the same Sum command with a lenght of 2, 3, 4... and confirm it's correct. This command is used as a checksum when downloading data.

## Emboidery Module Session Start

There is really two processors, the sewing machine and the enbroidery module. Both have their own CPU, RAM, software and more. When you send commands over the serial port, these commands may be directed at the sewing machine or the embroidery module. So, you have to be careful in what mode you are in. From the outside, when entering a embroidery session, the display will turn while and return to normal when you exit the session. So, you can tell right away what mode you are in.

When irst starting up, you communicate with the sewing machine by default, but if you want to access the embroidery module, you need to open the communication path to the embroidery module first. If you read 0x57FF80 the first bytes will be 0xB4A5 if the emboidery session is not started. In this case, you can't read/write data to the embroidery module.

To start the embroidery module communication, you need to send command "TrMEYQ" and get a "O" in return. If you don't get a "O", the embroidery module is not attached. Once the session started, you can read 0x57FF80 again to check the session state.

```
R57FF80 --> B4A5000020DF002B797D03700FCE0C08535332FF0370FFFFFFFFFFFFFFFFFFFF  (Session Closed)
TrMEYQ  --> Replay with "O"
R57FF80 --> 00CE800400CF80010000800403378004033704370704000A00F6F9FC07040010  (Session Open)
```

If the embroidery module session is started, you now read 0x00CE. Once the session is started, you can't start it again, so sending "TrMEYQ" again will not work (it will not return "O") also, once the session is open, you can't change the baudrate, that too will not return "O".

Do not send the "TrMEYQ" again if the session is already opened. If you do that, you will not get a "O" confirmation and the communication will be in an invalid state. You will not be able to close the session anymore and will need to turn off/on the machine to reset it into a good state.

When first starting up, the embroidery software will issue a R57FF80 to see if a session is already started or not. If it's not started, it will start it. Opening the embroidery module session is required to download/upload/view/delete embroidery files.

Also note that when changing baud rates, you may also be switching modes at the same time. For example, when you switch from 19200 bauds to 57600 bauds you may also at the same time be opening a embroidery module session. So, you should call "R57FF80" to make sure what mode you are in.

If you move into embroidery mode and read all 0xFF, the embroidery module was not initialized?
```
R57FF80 --> FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF  (Session Open, No initialized)
```

## Embroidery Module Session End

To close the session, send the "TrME" command. You can see how R57FF80 looks before and after the command: 

```
R57FF80 --> 00CE800400CF80010000800403378004033704370704000A00F6F9FC07040010  (Session Open)
Send "TrME" to close the session.
R57FF80 --> B4A5000020DF002B797D03700FCE0C08535332FF0370FFFFFFFFFFFFFFFFFFFF  (Session Closed)
```

You notice that once "TrME" is send, the session closes and the 0x57FF80 memory location reverts to 0xB4A5. The embroidery software has a tendency to close the embroidery module connection each time it's done with some operation probably in order to keep the default state being to communicate with the sewing machine. So, if you disconnect the serial cable at normal times, the serial port will be ready for sewing software.

## Invoke Machine Function Call

You can invoke code to run on the machine by placing argument 1 in 0x0201E1 and argument 2 in 0x0201DC and then writing the function call number into 0xFFFED0. For example:

```
W0201DC01? --> Write 01 to 0201DC         // Set argument 2
W0201E100? --> Write 00 to 0201E1         // Set argument 1
WFFFED00031? --> Write 0031 to FFFED0     // Invoke function 0x0031
```

When a function is called, the software always reads 0xFFFED0, this is likely to read the 2 first bytes that may indicate is the invocation completed and if so, what is the return value.

```
RFFFED0 -->
   ASCII: .....@.....3................@...
   HEX: 00 02 00 00 00 40 00 00 00 83 00 33 00 00 00 00 00 00 00 00 00 00 00 00 04 00 00 01 40 00 00 00
```

Note that most of this data past the two first bytes is likely of no use and only requested because the read command always pulls 32 bytes.

A guess is that this read is made to make sure the first two bytes are not equal to the number of the calling function. So, you write 0x0031 to FFFED0 and read it back to make sure it's changed confirming the call completed. Most of the time the read value will be 0x0002, however method call 0x0101 will return a value of 0x0000.

This method invocation system allows the software to tell the machine to do all sorts of things. Figuring out what function call do what is the real magic.

## Machine Name, Language & Version

Reading memory at 0x200100 will give you the machine firmware version. You also see the firmware language and manufacturer after this. It's a set of fixed length null terminated strings.

```
N200100 --> "NMMV03.01·English     ·Bernina Electronic  AG  ·July 98"
```

The software uses the R200100 command to read firmware version.

## Detecting the PC Card

The embroidery module has a PC card slot. Then a embroidery session is enabled, You can check if the PC card is inserted or not by reading the memory at location 0xFFFED9. The fist byte will be 0x82 = No PC Card oe 0x83 = Yes, card present. Here are sample memory dumps:

```
RFFFED9 --> 8300330000000000000000000000000200000100000000000000000000000000  <- PC Card Present
            8200000000000000000000000000000200000100000000000000000000000000  <- No PC Card
```

It's possible the the least significant bit of the first byte indicates a PC card in inserted. Obviously, if the session is currently open to the sewing machine, other data will be present there that is not relevent.

## Inserting and Removing a PC Card

If inserting or disconnecting a PC card while a embroidery session is enabled, the embroidery module will start sending this HEX string rapidly in a loop:

HEX: 70 00 40 00 00 00 A3 00 33 00 00 00 00 86

This does not seem to be recoverable. Your going to have to turn off/on the machine to get into a good state. This said, the software will close the embroidery session quickly so, as long as the PC card is removed or inserted without an active embroidery session going on, it should be ok.

Sending "F" during this message loop may stop it, but more investigation needs to be done. The normal software does not seem to handle this case.