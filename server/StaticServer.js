/**
 * StaticServer.js
 *
 * Serves the built Flutter web app over HTTP. For index.html it rewrites the
 * baked-in <base href> to the mount path and injects a small config script so
 * the Flutter app knows it is running in server-hosted mode and where to open
 * its WebSocket relay.
 */

const fs = require('fs');
const path = require('path');

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.bin': 'application/octet-stream',
  '.symbols': 'text/plain; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.map': 'application/json; charset=utf-8',
};

function contentTypeFor(filePath) {
  return MIME_TYPES[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
}

/**
 * Rewrites <base href="..."> and injects the hosted-mode config script into the
 * Flutter index.html.
 */
function transformIndexHtml(html, { basePath, wsPath }) {
  let out = html.replace(
    /<base href="[^"]*">/i,
    `<base href="${basePath}">`,
  );

  const config = JSON.stringify({ hosted: true, wsPath });
  const script = `  <script>window.embroideryServerConfig = ${config};</script>\n`;

  if (/<\/head>/i.test(out)) {
    out = out.replace(/<\/head>/i, `${script}</head>`);
  } else {
    out = script + out;
  }
  return out;
}

/**
 * Creates a Node HTTP request handler bound to a web root.
 *
 * @param {object} options
 * @param {string} options.webRoot   Absolute path to the built web app.
 * @param {string} [options.basePath] Mount path written into <base href>.
 * @param {string} [options.wsPath]   WebSocket path advertised to the app.
 * @param {Console} [options.logger]
 */
function createStaticHandler({ webRoot, basePath = '/', wsPath = '/ws', logger = console }) {
  const root = path.resolve(webRoot);

  return function handle(req, res) {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { 'Content-Type': 'text/plain' });
      res.end('Method Not Allowed');
      return;
    }

    // Strip query string and decode, then resolve within the web root.
    let urlPath;
    try {
      urlPath = decodeURIComponent(req.url.split('?')[0]);
    } catch {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('Bad Request');
      return;
    }

    if (urlPath === '/' || urlPath === '') {
      urlPath = '/index.html';
    }

    const resolved = path.normalize(path.join(root, urlPath));

    // Prevent path traversal outside the web root.
    if (resolved !== root && !resolved.startsWith(root + path.sep)) {
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      res.end('Forbidden');
      return;
    }

    fs.stat(resolved, (err, stats) => {
      let filePath = resolved;
      if (!err && stats.isDirectory()) {
        filePath = path.join(resolved, 'index.html');
      }

      const isIndex = path.basename(filePath).toLowerCase() === 'index.html';

      if (isIndex) {
        fs.readFile(filePath, 'utf8', (readErr, html) => {
          if (readErr) {
            sendNotFound(res, req);
            return;
          }
          const body = transformIndexHtml(html, { basePath, wsPath });
          res.writeHead(200, {
            'Content-Type': 'text/html; charset=utf-8',
            'Content-Length': Buffer.byteLength(body),
            'Cache-Control': 'no-cache',
          });
          res.end(req.method === 'HEAD' ? undefined : body);
        });
        return;
      }

      fs.stat(filePath, (statErr, fileStats) => {
        if (statErr || !fileStats.isFile()) {
          sendNotFound(res, req);
          return;
        }
        res.writeHead(200, {
          'Content-Type': contentTypeFor(filePath),
          'Content-Length': fileStats.size,
        });
        if (req.method === 'HEAD') {
          res.end();
          return;
        }
        const stream = fs.createReadStream(filePath);
        stream.on('error', () => {
          if (!res.headersSent) sendNotFound(res, req);
          else res.destroy();
        });
        stream.pipe(res);
      });
    });
  };

  function sendNotFound(res, req) {
    logger.log(`404 ${req.url}`);
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found');
  }
}

module.exports = { createStaticHandler, transformIndexHtml };
