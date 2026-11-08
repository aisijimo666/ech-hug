const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 5000;
const HOST = '0.0.0.0';

const MIME_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js':   'application/javascript; charset=utf-8',
    '.css':  'text/css; charset=utf-8',
    '.json': 'application/json',
    '.png':  'image/png',
    '.jpg':  'image/jpeg',
    '.svg':  'image/svg+xml',
    '.ico':  'image/x-icon',
};

const LOADING_PAGE = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>隧道启动中...</title>
<style>
  body { background:#020617; color:#e5e7eb; display:flex; align-items:center;
         justify-content:center; height:100vh; margin:0;
         font-family:system-ui,sans-serif; }
  .box { text-align:center; }
  h1 { font-size:2rem; margin-bottom:12px; }
  p  { color:#9ca3af; margin-bottom:24px; }
  .dot { display:inline-block; width:10px; height:10px; border-radius:50%;
         background:#6366f1; margin:0 4px;
         animation: bounce 1.2s infinite ease-in-out; }
  .dot:nth-child(2){ animation-delay:.2s; }
  .dot:nth-child(3){ animation-delay:.4s; }
  @keyframes bounce { 0%,80%,100%{transform:scale(0)} 40%{transform:scale(1)} }
</style>
<meta http-equiv="refresh" content="5">
</head>
<body>
<div class="box">
  <h1>⏳ 隧道启动中</h1>
  <p>正在建立 Cloudflare 隧道，请稍候...</p>
  <span class="dot"></span>
  <span class="dot"></span>
  <span class="dot"></span>
  <p style="margin-top:20px;font-size:13px;color:#6b7280">页面将每 5 秒自动刷新</p>
</div>
</body>
</html>`;

const server = http.createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');

    let urlPath = req.url.split('?')[0];

    if (urlPath === '/' || urlPath === '/index.html') {
        const tunnelPage = path.join(__dirname, 'tunnel_index.html');
        if (fs.existsSync(tunnelPage)) {
            serveFile(res, tunnelPage);
        } else {
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end(LOADING_PAGE);
        }
        return;
    }

    const filePath = path.join(__dirname, urlPath);
    if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
        serveFile(res, filePath);
        return;
    }

    const tunnelPage = path.join(__dirname, 'tunnel_index.html');
    if (fs.existsSync(tunnelPage)) {
        serveFile(res, tunnelPage);
    } else {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(LOADING_PAGE);
    }
});

function serveFile(res, filePath) {
    fs.readFile(filePath, (err, data) => {
        if (err) {
            res.writeHead(404, { 'Content-Type': 'text/plain' });
            res.end('Not Found');
            return;
        }
        const ext = path.extname(filePath);
        const contentType = MIME_TYPES[ext] || 'application/octet-stream';
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(data);
    });
}

server.listen(PORT, HOST, () => {
    console.log(`Server running at http://${HOST}:${PORT}/`);
});
