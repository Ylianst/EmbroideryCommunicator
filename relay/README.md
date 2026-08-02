# Embroidery Relay - Setup Guide

![Embroidery Relay](https://raw.githubusercontent.com/Ylianst/EmbroideryCommunicator/refs/heads/main/docs/images/EmbroideryRelay.png)

A simple server that provides network access to your embroidery machine via serial port. Perfect for running on a Raspberry Pi.

## What is Relay.js?

Relay.js is a program that lets you communicate with your Bernina Artista 180 embroidery machine over your network. It creates a bridge between your machine's serial port and your network, so you can send commands from any computer on your local network. You typically run Embroidery Commander and use it to connect to this relay to upload/download patterns to your machine.

## What You'll Need

- **Raspberry Pi**
- **USB to Serial Cable** (to connect Pi to embroidery machine)
- **Embroidery Machine** (tested with Bernina Artista)
- **Network Connection** (WiFi or Ethernet)
- **Basic command line knowledge** (we'll guide you through each step!)

## Step-by-Step Setup Guide

### Step 1: Prepare Your Raspberry Pi

Make sure your Raspberry Pi is:
- Running Raspberry Pi OS (formerly Raspbian)
- Connected to your network
- Up to date with latest software

Update your system:
```bash
sudo apt-get update
sudo apt-get upgrade
```

### Step 2: Install Node.js

Relay.js requires Node.js to run. Install it with:

```bash
# Install Node.js (version 14 or newer)
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Verify installation
node --version
npm --version
```

### Step 3: Copy Files to Your Raspberry Pi

Create a folder for EmbroideryStack and copy all the files:

```bash
# Create a directory for the project
mkdir -p ~/EmbroideryStack
cd ~/EmbroideryStack

# Copy all your files here (using scp, USB drive, or git clone)
```

If you're copying from another computer using `scp`:
```bash
# On your other computer, run:
scp -r /path/to/EmbroideryStack/* pi@raspberrypi.local:~/EmbroideryStack/
```

### Step 4: Install Required Packages

Navigate to the project folder and install the serialport module:

```bash
cd ~/EmbroideryStack

# Install serialport and other dependencies
npm install
```

**Note:** The first time you run `npm install`, it may take several minutes to compile the serialport module. This is normal!

If you encounter build errors, install the build tools:
```bash
sudo apt-get install build-essential
```

### Step 5: Connect Your Embroidery Machine

1. **Power on** your embroidery machine
2. **Connect** the USB to Serial cable between your Raspberry Pi and the machine
3. **Find the serial port** - it's usually `/dev/ttyUSB0`

To verify the connection:
```bash
# List available serial ports
ls /dev/ttyUSB*
```

You should see something like `/dev/ttyUSB0`. This is your serial port!

### Step 6: Configure Relay.js (Optional)

By default, Relay.js uses:
- **Serial Port:** `/dev/ttyUSB0`
- **TCP Port:** `8888`
- **Host:** `0.0.0.0` (all network interfaces)

If your machine is on a different port, edit `config.ini`:

```bash
nano config.ini
```

Change the serial port if needed:
```ini
[serial]
port = /dev/ttyUSB0    # Change this if your port is different
```

Press `Ctrl+X`, then `Y`, then `Enter` to save.

### Step 7: Test Relay.js

Before installing as a background service, test that everything works:

```bash
# Run Relay.js in the foreground
node Relay.js --run
```

You should see:
```
Loaded configuration:
  TCP: 0.0.0.0:8888
  Serial: /dev/ttyUSB0 (baud rate auto-detected)
Relay.js TCP server listening on 0.0.0.0:8888
Accepting only one connection at a time
Press Ctrl+C to stop
```

If you see this, it's working! Press `Ctrl+C` to stop.

**If you get an error** about serialport not being installed, run:
```bash
npm install
```

## Running Relay.js

You have two options for running Relay.js:

### Option 1: Run in Foreground (Testing/Development)

This keeps Relay.js running in your terminal window:

```bash
node Relay.js --run
```

**Pros:** Easy to see what's happening, good for testing
**Cons:** Stops when you close the terminal or log out

To stop: Press `Ctrl+C`

### Option 2: Install as Background Service (Recommended)

This makes Relay.js start automatically when your Raspberry Pi boots:

```bash
# Install and start the service (requires sudo)
sudo node Relay.js --install
```

You should see:
```
✓ Service installed and started successfully!

Useful commands:
  sudo systemctl status relay   # Check service status
  sudo journalctl -u relay -f   # View live logs
  node Relay.js --stop          # Stop the service
  node Relay.js --uninstall     # Uninstall the service
```

**Pros:** Runs automatically, restarts on crashes, starts at boot
**Cons:** Harder to see real-time output (must check logs)

## Managing the Background Service

Once installed as a service, use these commands:

```bash
# Check if service is running
sudo systemctl status relay

# View live logs (see what's happening)
sudo journalctl -u relay -f

# Stop the service
sudo node Relay.js --stop

# Start the service
sudo node Relay.js --start

# Restart the service
sudo systemctl restart relay

# Uninstall the service completely
sudo node Relay.js --uninstall
```

## Connecting to Relay.js

Once Relay.js is running, use Embroidery Commander to connect to this relay.

## Help and Commands

To see all available commands:

```bash
node Relay.js --help
```

Available commands:
- `node Relay.js` - Show help
- `node Relay.js --help` - Show help
- `node Relay.js --run` - Run in foreground
- `sudo node Relay.js --install` - Install as background service
- `sudo node Relay.js --uninstall` - Remove background service
- `sudo node Relay.js --start` - Start the service
- `sudo node Relay.js --stop` - Stop the service

## Troubleshooting

### Problem: "serialport module is not installed"

**Solution:**
```bash
cd ~/EmbroideryStack
npm install
```

### Problem: "Cannot find module"

**Solution:** Make sure you're in the correct directory:
```bash
cd ~/EmbroideryStack
ls -la
# You should see Relay.js, SerialStack.js, etc.
```

### Problem: "Port /dev/ttyUSB0 not found"

**Solution:** 
1. Check if device is connected: `ls /dev/ttyUSB*`
2. If you see `/dev/ttyUSB1` or different, edit `config.ini`
3. Make sure your machine is powered on

### Problem: "Permission denied" accessing serial port

**Solution:** Add your user to the dialout group:
```bash
sudo usermod -a -G dialout $USER
# Log out and log back in for changes to take effect
```

### Problem: Service won't start at boot

**Solution:** 
```bash
# Check service status
sudo systemctl status relay

# Enable service
sudo systemctl enable relay

# View error logs
sudo journalctl -u relay -n 50
```
