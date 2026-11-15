// Serves the web export on localhost to try it before hosting it:
//   node tools/serve_web.js [folder] [port]      (defaults: build/web, 8060)
// Plain headers only, like a basic static host. Then open http://127.0.0.1:8060/
const http = require("http");
const fs = require("fs");
const path = require("path");
const root = path.resolve(process.argv[2] || "build/web");
const port = Number(process.argv[3] || 8060);
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".pck": "application/octet-stream", ".png": "image/png", ".json": "application/json" };
http.createServer((req, res) => {
  let p = decodeURIComponent(req.url.split("?")[0]);
  if (p === "/") p = "/index.html";
  const f = path.join(root, p);
  if (!f.startsWith(root) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end("not found"); return; }
  res.writeHead(200, { "Content-Type": types[path.extname(f)] || "application/octet-stream", "Content-Length": fs.statSync(f).size, "Cache-Control": "no-store" });
  fs.createReadStream(f).pipe(res);
}).listen(port, "127.0.0.1", () => console.log("serving " + root + " on http://127.0.0.1:" + port + "/"));
