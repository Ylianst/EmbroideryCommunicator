#!/usr/bin/env node
// Framebuffer finder / renderer for raw memory dumps.
// Renders regions of a binary dump as grayscale PNGs at various bit depths and
// widths so a display framebuffer can be spotted visually. No dependencies
// beyond Node's built-in zlib.

'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) {
        args[key] = true;
      } else {
        args[key] = next;
        i++;
      }
    }
  }
  return args;
}

function toInt(v, def) {
  if (v === undefined) return def;
  if (typeof v === 'number') return v;
  const s = String(v).trim();
  if (s.toLowerCase().startsWith('0x')) return parseInt(s, 16);
  // allow bare hex when it contains hex letters
  if (/^[0-9a-fA-F]+$/.test(s) && /[a-fA-F]/.test(s)) return parseInt(s, 16);
  return parseInt(s, 10);
}

// ---- Minimal grayscale PNG encoder (8-bit gray) ----
function crc32(buf) {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xEDB88320 & -(c & 1));
  }
  return ~c >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const body = Buffer.concat([typeBuf, data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}

// pixels: Uint8Array length = width*height, gray 0..255
function encodePng(width, height, pixels) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 0;  // color type: grayscale
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter
  ihdr[12] = 0; // interlace

  // raw scanlines with filter byte 0
  const raw = Buffer.alloc((width + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (width + 1)] = 0;
    pixels.copy
      ? pixels.copy(raw, y * (width + 1) + 1, y * width, y * width + width)
      : raw.set(pixels.subarray(y * width, y * width + width), y * (width + 1) + 1);
  }
  const idat = zlib.deflateSync(raw, { level: 6 });
  return Buffer.concat([
    sig,
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// Expand region bytes into grayscale pixels at given bit depth.
// bpp: 1,2,4,8. msbFirst: pixel packing order within a byte. invert: flip gray.
function renderRegion(buf, offset, length, bpp, width, msbFirst, invert) {
  const totalPixels = Math.floor((length * 8) / bpp);
  const height = Math.floor(totalPixels / width);
  const pixels = Buffer.alloc(width * height);
  const maxVal = (1 << bpp) - 1;
  let p = 0;
  const end = offset + length;
  outer:
  for (let i = offset; i < end; i++) {
    const byte = buf[i];
    if (bpp === 8) {
      if (p >= pixels.length) break;
      let v = byte;
      pixels[p++] = invert ? 255 - v : v;
    } else {
      const perByte = 8 / bpp;
      for (let s = 0; s < perByte; s++) {
        if (p >= pixels.length) break outer;
        const shift = msbFirst ? (8 - bpp * (s + 1)) : (bpp * s);
        let v = (byte >> shift) & maxVal;
        v = Math.round((v / maxVal) * 255);
        pixels[p++] = invert ? 255 - v : v;
      }
    }
  }
  return { width, height, pixels };
}

// Column-major "page" format (1bpp): common on monochrome LCD controllers.
// Each byte holds 8 vertically-stacked pixels. Byte index = page*width + x,
// where page = floor(y/8). topFirst=true means bit0 (LSB) is the TOP pixel.
function renderVertical(buf, offset, width, height, topFirst, invert) {
  const pixels = Buffer.alloc(width * height);
  const pages = Math.ceil(height / 8);
  for (let x = 0; x < width; x++) {
    for (let page = 0; page < pages; page++) {
      const byte = buf[offset + page * width + x];
      for (let b = 0; b < 8; b++) {
        const y = page * 8 + b;
        if (y >= height) break;
        const bit = topFirst ? b : 7 - b;
        const on = (byte >> bit) & 1;
        let v = on ? 255 : 0;
        pixels[y * width + x] = invert ? 255 - v : v;
      }
    }
  }
  return { width, height, pixels };
}

function cmdRender(args) {
  const inFile = args.in;
  const buf = fs.readFileSync(inFile);
  const offset = toInt(args.offset, 0);
  const bpp = toInt(args.bpp, 1);
  const width = toInt(args.width, 320);
  const height = toInt(args.height, 240);
  const msbFirst = args.lsb ? false : true;
  const invert = !!args.invert;
  let result;
  if (args.vert) {
    result = renderVertical(buf, offset, width, height, !args.topmsb, invert);
  } else {
    const bytesPerImage = Math.ceil((width * height * bpp) / 8);
    const length = toInt(args.length, bytesPerImage);
    result = renderRegion(buf, offset, length, bpp, width, msbFirst, invert);
  }
  const { width: w, height: h, pixels } = result;
  const out = args.out || `render_0x${offset.toString(16)}_${bpp}bpp_w${width}.png`;
  fs.writeFileSync(out, encodePng(w, h, pixels));
  console.log(`Wrote ${out}  (${w}x${h}, ${bpp}bpp, offset 0x${offset.toString(16)})`);
}

// Overview: render the WHOLE file, one gray pixel per byte, tiled into pages.
function cmdOverview(args) {
  const inFile = args.in;
  const buf = fs.readFileSync(inFile);
  const width = toInt(args.width, 1024);
  const pageRows = toInt(args.rows, 2048); // rows per page image
  const outDir = args.outdir || 'overview';
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  const totalRows = Math.ceil(buf.length / width);
  const pages = Math.ceil(totalRows / pageRows);
  console.log(`File ${buf.length} bytes -> ${totalRows} rows @ width ${width}, ${pages} pages`);
  for (let pg = 0; pg < pages; pg++) {
    const startByte = pg * pageRows * width;
    const rows = Math.min(pageRows, totalRows - pg * pageRows);
    const pixels = Buffer.alloc(width * rows);
    for (let i = 0; i < width * rows; i++) {
      const idx = startByte + i;
      pixels[i] = idx < buf.length ? buf[idx] : 0;
    }
    const startAddr = startByte;
    const endAddr = Math.min(buf.length, startByte + width * rows);
    const name = path.join(outDir, `page_${String(pg).padStart(2, '0')}_0x${startAddr.toString(16)}-0x${endAddr.toString(16)}.png`);
    fs.writeFileSync(name, encodePng(width, rows, pixels));
    console.log(`  ${name}  rows ${rows}  addr 0x${startAddr.toString(16)}..0x${endAddr.toString(16)}`);
  }
}

// Scan: report blocks that are "interesting" (non-zero, non-0xFF, structured).
function cmdScan(args) {
  const inFile = args.in;
  const buf = fs.readFileSync(inFile);
  const block = toInt(args.block, 4096);
  const results = [];
  for (let off = 0; off < buf.length; off += block) {
    const end = Math.min(off + block, buf.length);
    let zero = 0, ff = 0;
    const hist = new Array(256).fill(0);
    for (let i = off; i < end; i++) {
      const b = buf[i];
      if (b === 0) zero++;
      else if (b === 0xff) ff++;
      hist[b]++;
    }
    const n = end - off;
    // Shannon entropy
    let ent = 0;
    for (let v = 0; v < 256; v++) {
      if (hist[v]) {
        const p = hist[v] / n;
        ent -= p * Math.log2(p);
      }
    }
    const zeroFrac = zero / n;
    const ffFrac = ff / n;
    // Framebuffer-ish heuristic: mix of extremes (0x00/0xFF) with low-moderate
    // entropy, OR moderate entropy with significant 0x00/0xFF presence.
    const extremes = zeroFrac + ffFrac;
    const interesting = zeroFrac < 0.98 && ffFrac < 0.98 &&
      ((extremes > 0.2 && ent < 4.5) || (ent > 0.3 && ent < 6.5 && extremes > 0.1));
    results.push({ off, ent, zeroFrac, ffFrac, extremes, interesting });
  }
  // Merge consecutive interesting blocks into ranges.
  const ranges = [];
  let cur = null;
  for (const r of results) {
    if (r.interesting) {
      if (!cur) cur = { start: r.off, end: r.off + block, ent: [r.ent] };
      else { cur.end = r.off + block; cur.ent.push(r.ent); }
    } else if (cur) { ranges.push(cur); cur = null; }
  }
  if (cur) ranges.push(cur);
  ranges.sort((a, b) => (b.end - b.start) - (a.end - a.start));
  console.log(`Interesting ranges (largest first), block=${block}:`);
  for (const r of ranges.slice(0, 40)) {
    const size = r.end - r.start;
    const avgEnt = (r.ent.reduce((a, b) => a + b, 0) / r.ent.length).toFixed(2);
    console.log(`  0x${r.start.toString(16).padStart(6, '0')}..0x${r.end.toString(16).padStart(6, '0')}  size ${size} (${(size / 1024).toFixed(1)}KB)  avgEnt ${avgEnt}`);
  }
}

function main() {
  const args = parseArgs(process.argv);
  const cmd = args.cmd || (args.overview ? 'overview' : args.scan ? 'scan' : 'render');
  if (!args.in) {
    console.error('Usage: node fbfind.js --in <dump.bin> --cmd <overview|scan|render> [options]');
    console.error('  overview: --width 1024 --rows 2048 --outdir overview');
    console.error('  scan:     --block 4096');
    console.error('  render:   --offset 0x1000 --bpp 1|2|4|8 --width 320 --height 240 [--lsb] [--invert] [--length N] [--out file.png]');
    process.exit(1);
  }
  if (cmd === 'overview') cmdOverview(args);
  else if (cmd === 'scan') cmdScan(args);
  else cmdRender(args);
}

main();
