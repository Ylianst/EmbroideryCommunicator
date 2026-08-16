#!/usr/bin/env node
/**
 * DumpMemory.js
 *
 * Command-line tool to dump the entire 16 MB memory of an embroidery machine
 * over a serial port, from either the sewing machine or the embroidery module.
 *
 * Mirrors the Flutter app's memory-dump behavior: it reads 256-byte blocks and
 * retries each block automatically on error (10 attempts, 3s apart) while
 * showing live progress. Output is written incrementally so a partial file is
 * preserved if a block ultimately fails.
 *
 * Usage:
 *   node DumpMemory.js --port <serial> --module <sewing|embroidery> [--output <file>]
 *
 * Uses the bundled SerialStack.js for serial communication.
 */

const fs = require('fs');
const path = require('path');

// Full address space: 0x000000..0xFFFFFF (end is exclusive).
const DEFAULT_START = 0x000000;
const DEFAULT_END = 0x1000000;
const BLOCK_SIZE = 256;
const MAX_RETRIES = 10;
const RETRY_DELAY_MS = 3000;

function showHelp() {
  console.log(`
DumpMemory.js - Dump embroidery machine memory to a file

USAGE:
  node DumpMemory.js --port <serial> --module <sewing|embroidery> [options]

REQUIRED:
  --port, -p <path>      Serial port (e.g. COM3 or /dev/ttyUSB0)
  --module, -m <name>    Which memory to dump:
                           sewing     (sewing machine)
                           embroidery (embroidery module)

OPTIONS:
  --output, -o <file>    Output file. Defaults to
                         MemoryDump-<Module>-<YYYY-MM-DD_HH-MM-SS>.bin
  --start <hex>          Start address (default: 000000)
  --end <hex>            End address, exclusive (default: 1000000)
  --debug, -d [level]    Show serial debug output (level defaults to 1)
  --help, -h             Show this help

EXAMPLES:
  node DumpMemory.js -p COM3 -m sewing
  node DumpMemory.js -p /dev/ttyUSB0 -m embroidery -o backup.bin
  node DumpMemory.js -p COM3 -m sewing --debug
`);
}

function parseArgs(argv) {
  const opts = { start: DEFAULT_START, end: DEFAULT_END, debug: 0 };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const value = argv[++i];
      if (value === undefined) throw new Error(`Missing value for ${arg}`);
      return value;
    };
    switch (arg) {
      case '--help':
      case '-h':
        opts.help = true;
        break;
      case '--debug':
      case '-d': {
        const peek = argv[i + 1];
        if (peek !== undefined && /^\d+$/.test(peek)) {
          opts.debug = parseInt(peek, 10);
          i++;
        } else {
          opts.debug = 1;
        }
        break;
      }
      case '--port':
      case '-p':
        opts.port = next();
        break;
      case '--module':
      case '-m':
        opts.module = next();
        break;
      case '--output':
      case '-o':
        opts.output = next();
        break;
      case '--start':
        opts.start = parseHex(next(), '--start');
        break;
      case '--end':
        opts.end = parseHex(next(), '--end');
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return opts;
}

function parseHex(value, label) {
  const n = parseInt(value, 16);
  if (isNaN(n) || n < 0) throw new Error(`Invalid hex value for ${label}: ${value}`);
  return n;
}

/** Normalizes the module argument to { key, label }. */
function resolveModule(value) {
  const v = (value || '').toLowerCase();
  if (['sewing', 'sewing-machine', 'machine', 's'].includes(v)) {
    return { key: 'sewing', label: 'SewingMachine' };
  }
  if (['embroidery', 'embroidery-module', 'module', 'e'].includes(v)) {
    return { key: 'embroidery', label: 'EmbroideryModule' };
  }
  return null;
}

function defaultFileName(moduleLabel) {
  const now = new Date();
  const p = (n) => String(n).padStart(2, '0');
  const stamp =
    `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}` +
    `_${p(now.getHours())}-${p(now.getMinutes())}-${p(now.getSeconds())}`;
  return `MemoryDump-${moduleLabel}-${stamp}.bin`;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// The tool's own output goes straight to the streams so it is unaffected by the
// console silencing used to hide the serial stack's debug chatter.
const out = (msg = '') => process.stdout.write(`${msg}\n`);
const errOut = (msg = '') => process.stderr.write(`${msg}\n`);

/**
 * Silences the global console (used by SerialStack for debug output) unless a
 * debug level is set. Returns a function that restores the console.
 */
function configureLogging(level) {
  if (level > 0) return () => {};
  const saved = {
    log: console.log,
    info: console.info,
    warn: console.warn,
    error: console.error,
    debug: console.debug,
  };
  const noop = () => {};
  console.log = noop;
  console.info = noop;
  console.warn = noop;
  console.error = noop;
  console.debug = noop;
  return () => Object.assign(console, saved);
}

function addressString(addr) {
  return addr.toString(16).toUpperCase().padStart(6, '0');
}

function formatBytes(n) {
  if (n >= 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(2)} MB`;
  if (n >= 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${n} B`;
}

/** Renders a single-line progress indicator (overwrites in place). */
function renderProgress(done, total, addr, note = '') {
  const pct = total === 0 ? 0 : (done / total) * 100;
  const line =
    `  ${pct.toFixed(1).padStart(5)}%  ` +
    `${formatBytes(done)} / ${formatBytes(total)}  ` +
    `@ 0x${addressString(addr)}` +
    (note ? `  ${note}` : '');
  process.stdout.write('\r' + line.padEnd(78));
}

/**
 * Reads one block, retrying on error like the Flutter app. Returns a Buffer, or
 * null if all retries are exhausted. [done]/[total] are used to keep the
 * progress line accurate while retrying.
 */
async function readBlockWithRetry(serialStack, addr, length, done, total) {
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    try {
      if (length > 32) {
        const data = await serialStack.largeRead(addressString(addr));
        return Buffer.from(data, 'latin1').slice(0, Math.min(BLOCK_SIZE, length));
      }
      const data = await serialStack.read(addressString(addr));
      return Buffer.from(data, 'hex').slice(0, Math.min(32, length));
    } catch (error) {
      if (attempt === MAX_RETRIES) {
        process.stdout.write('\n');
        errOut(
          `Read failed at 0x${addressString(addr)} after ${MAX_RETRIES} retries: ${error.message}`,
        );
        return null;
      }
      renderProgress(done, total, addr, `read error, retrying ${attempt + 1}/${MAX_RETRIES}…`);
      await sleep(RETRY_DELAY_MS);
    }
  }
  return null;
}

async function selectModule(serialStack, moduleKey) {
  if (moduleKey === 'embroidery') {
    out('Selecting embroidery module (starting embroidery session)...');
    await serialStack.StartEmbroiderySession();
  } else {
    out('Selecting sewing machine (ensuring embroidery session is closed)...');
    if (await serialStack.IsEmbroiderySessionOpen()) {
      await serialStack.EndEmbroiderySession();
    }
  }
}

async function run(opts) {
  const module = resolveModule(opts.module);
  if (!opts.port) throw new Error('Missing required --port');
  if (!module) {
    throw new Error("Missing or invalid --module (use 'sewing' or 'embroidery')");
  }
  if (opts.end <= opts.start) throw new Error('End address must be greater than start');

  const outputPath = opts.output || defaultFileName(module.label);

  // Lazily require so --help works without the serialport native module.
  let SerialStack;
  try {
    SerialStack = require('./SerialStack');
  } catch (error) {
    errOut('\n\u274C ERROR: could not load the serial stack.');
    errOut('Install dependencies first:\n\n  cd server && npm install\n');
    process.exit(1);
  }

  const total = opts.end - opts.start;
  out(`Serial port: ${opts.port}`);
  out(`Module:      ${module.label}`);
  out(`Range:       0x${addressString(opts.start)} .. 0x${addressString(opts.end)} (${formatBytes(total)})`);
  out(`Output:      ${path.resolve(outputPath)}`);
  out('');

  const serialStack = new SerialStack(opts.port, 19200);
  const output = fs.createWriteStream(outputPath);

  let cancelled = false;
  const onSigint = () => {
    cancelled = true;
    process.stdout.write('\n');
    out('Cancellation requested; finishing current block...');
  };
  process.on('SIGINT', onSigint);

  // Hide the serial stack's debug chatter unless --debug was requested.
  const restoreConsole = configureLogging(opts.debug);

  let done = 0;
  let complete = false;
  try {
    out('Opening serial port (auto-detecting baud rate)...');
    await serialStack.open();
    out(`Serial port open at ${serialStack.baudRate} baud`);

    if (serialStack.baudRate !== 57600) {
      try {
        await serialStack.upgradeSpeed();
        out(`Upgraded to ${serialStack.baudRate} baud`);
      } catch (error) {
        out(`Staying at ${serialStack.baudRate} baud: ${error.message}`);
      }
    }

    await selectModule(serialStack, module.key);
    out('\nDumping memory:');

    let addr = opts.start;
    while (addr < opts.end && !cancelled) {
      const remaining = opts.end - addr;
      const chunk = remaining >= BLOCK_SIZE ? BLOCK_SIZE : remaining;

      const block = await readBlockWithRetry(serialStack, addr, chunk, done, total);
      if (block === null) break; // Retries exhausted; keep partial file.

      const kept = block.slice(0, chunk);
      await writeChunk(output, kept);
      addr += chunk;
      done += kept.length;
      renderProgress(done, total, addr);
    }

    complete = addr >= opts.end;
  } finally {
    process.removeListener('SIGINT', onSigint);
    await new Promise((resolve) => output.end(resolve));
    try {
      if (module.key === 'embroidery' && serialStack.isOpen) {
        await serialStack.EndEmbroiderySession();
      }
      await serialStack.close();
    } catch (error) {
      errOut(`Error closing serial port: ${error.message}`);
    }
    restoreConsole();
  }

  process.stdout.write('\n');
  if (complete) {
    out(`\u2713 Done. Saved ${formatBytes(done)} to ${outputPath}`);
  } else if (cancelled) {
    out(`Cancelled. Saved ${formatBytes(done)} to ${outputPath}`);
    process.exitCode = 130;
  } else {
    out(`Incomplete. Saved ${formatBytes(done)} to ${outputPath}`);
    process.exitCode = 1;
  }
}

function writeChunk(stream, buffer) {
  return new Promise((resolve, reject) => {
    stream.write(buffer, (err) => (err ? reject(err) : resolve()));
  });
}

function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`Error: ${error.message}`);
    console.log('Run with --help to see usage.');
    process.exit(1);
  }

  if (opts.help || process.argv.length <= 2) {
    showHelp();
    process.exit(0);
  }

  run(opts).catch((error) => {
    process.stdout.write('\n');
    console.error(`Error: ${error.message}`);
    process.exit(1);
  });
}

main();
