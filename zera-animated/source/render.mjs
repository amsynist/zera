// Usage:
//   node render.mjs stills out_dir t1 t2 ...        -> PNG stills at given times
//   node render.mjs video out.mp4 [fps]             -> full scene encoded with ffmpeg
// Optional env: TL='{"l1s":0.25,...}'  ENV=path/to/mouth_env.json  SS=1.5 (supersample)
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)('playwright');

const ROOT = path.dirname(new URL(import.meta.url).pathname);
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.woff2': 'font/woff2', '.json': 'application/json', '.png': 'image/png' };
const server = http.createServer((req, res) => {
  const p = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]));
  if (!p.startsWith(ROOT) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

const [mode, out, ...rest] = process.argv.slice(2);
const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const page = await browser.newPage({ viewport: { width: 720, height: 1280 }, deviceScaleFactor: 1 });
page.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') console.log('[page]', m.text()); });
page.on('pageerror', e => console.log('[pageerror]', e.message));
const ss = process.env.SS || '1';
await page.goto(`http://127.0.0.1:${port}/scene.html?ss=${ss}`);
await page.waitForFunction(() => window.READY === true, null, { timeout: 120000 });
if (process.env.TL) await page.evaluate(tl => window.setTimeline(tl), JSON.parse(process.env.TL));
if (process.env.ENV) await page.evaluate(e => window.setMouthEnv(e), JSON.parse(fs.readFileSync(process.env.ENV, 'utf8')));
const DUR = await page.evaluate(() => window.getDuration());
const clip = { x: 0, y: 0, width: 720, height: 1280 };

if (mode === 'stills') {
  fs.mkdirSync(out, { recursive: true });
  for (const ts of rest) {
    const t = parseFloat(ts);
    const t0 = Date.now();
    await page.evaluate(t => window.renderAt(t), t);
    await page.screenshot({ path: path.join(out, `t${t.toFixed(2)}.png`), clip });
    console.log('still', t, (Date.now() - t0) + 'ms');
  }
} else {
  const fps = parseInt(rest[0] || '30', 10);
  const n = Math.round(DUR * fps);
  const tmp = out.replace(/\.mp4$/, '.part.mp4');
  const ff = spawn('ffmpeg', ['-y', '-v', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
    '-c:v', 'libx264', '-crf', '16', '-preset', 'medium', '-pix_fmt', 'yuv420p', '-r', String(fps), '-video_track_timescale', '15360', tmp], { stdio: ['pipe', 'inherit', 'inherit'] });
  const done = new Promise((res, rej) => ff.on('exit', c => c === 0 ? res() : rej(new Error('ffmpeg ' + c))));
  const t0 = Date.now();
  for (let i = 0; i < n; i++) {
    await page.evaluate(t => window.renderAt(t), i / fps);
    const buf = await page.screenshot({ type: 'jpeg', quality: 93, clip });
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % 30 === 0) console.log(`frame ${i}/${n}  ${((Date.now() - t0) / 1000).toFixed(0)}s`);
  }
  ff.stdin.end();
  await done;
  fs.renameSync(tmp, out);
  console.log('wrote', out, n, 'frames');
}
await browser.close();
server.close();
