# EXP Embroidery File Format

From: https://www.appropedia.org/EXP_Embroidery_File_Format

I made this page to document the .exp file format. With this, I hope it will be easier for others to work with .exp files and write their own as needed.

## Basic info

.exp files are embroidery files designed for use with Melco or Bravo systems.

These files are written in binary code. The code is written in sets of 8 bits. A bit is the binary number 0 or 1. These sets of 8 bits are called bytes. These bytes contain the information for each stitch operation. There are 256 possible combinations of bits to make a byte. These bytes represent numbers ranging from 0 to 255. Each of these numbers signifies a command to the embroidery machine.

Bytes are written to the file in pairs of 2. These pairs are usually the commands for a movement in the x (left/right) and y (up/down) directions. The first byte is the movement command for x and the second byte is for y.

The minimum resolution of a stitch movement in the .exp file format is 0.1mm. As the movements are all based upon this resolution, it is most convenient to consider 0.1mm as the base unit of measurement when working with data to be written to embroidery.

The maximum movement in one stitch command is 12.7mm. Any desired movement larger than this length between stitches must be created with one or more "jump" movements, explained below.
Movement and stitch Commands

A movement of 0 in x or y is represented by the byte value 0.

A positive movement in x or y in mm*10^-1 is represented by the same byte value. For example, a movement of +0.3mm is represented by the byte value 3, a movement of +7.1mm is represented by the byte value of 71, etc.

A negative movement in x or y in mm*10^-1 is represented by the movement's absolute value subtracted from 256. For example, a movement of -0.3mm is represented by the byte value 253, a movement of -7.1mm is represented by the byte value of 185, etc.

Special operations are also given as a set of 2 bytes. These special operations include "change color / stop", "jump", and "end / cut thread". These special operations always start with 128 as the first byte, and the second byte signifies which of the special operations to take.

    "Change color / stop" tells the machine to pause so that the operator can change colors of the embroidery thread or adjust machine settings as desired midway through a print.
        Byte representation - (128,1)* *followed by movement command (0,0) if no jump is desired with the command. Followed with another command of (0,0) to signify to create a stitch at this point to start the next commands from.
    "Jump" signifies that the following set of x and y movement commands should not receive a stitch. This lets the machine put larger spacing between stitches or allows separate objects to be made without stitching the fabric between.
        Byte representation - (128,4)* *followed by the (x,y) coordinate command for the intended jump. String together the jump and jump coordinate commands in succession to travel a further distance. Upon completion of the jump or series of jumps, use coordinate stitch command (0,0) for creating the origin for the next stitch operation.
    "End / cut thread" signifies that the thread should be cut. It can be used when finishing a part of an embroidery process and/or at the end of the file. used It is recommended to always end a file with this command. It gives a clean cut at the end of the embroidery process to avoid having any loose threads.
        Byte representation - (128,128)* *needs to be followed with a (0,0) command.

Refer to the Stitch command table for a more visual explanation of the stitch commands. 