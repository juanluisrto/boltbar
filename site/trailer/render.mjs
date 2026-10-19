#!/usr/bin/env node
// Render the Boltbar trailer (site/trailer) frame by frame in headless Chrome
// and encode it with ffmpeg. Serves site/ itself, so nothing else must run.
//
//   node site/trailer/render.mjs                      # site/boltbar/assets/trailer.mp4
//   node site/trailer/render.mjs --stills 5,8.5,21    # PNG stills only
//   node site/trailer/render.mjs --workers 4          # split into parallel segments
//   options: --out <file.mp4>  --dir <stills dir>  --fps 60  --from 0  --to 36
import { spawn } from "node:child_process";
import { createReadStream, existsSync, mkdtempSync, mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, a, i, all) => (a.startsWith("--") ? [...pairs, [a.slice(2), all[i + 1]]] : pairs), []),
);
const site = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = args.out ?? join(site, "boltbar/assets/trailer.mp4");

// Capturing a frame takes most of a second, so long renders split the timeline
// across processes, each with its own Chrome, and join the segments losslessly.
const workers = Number(args.workers ?? 1);
if (workers > 1 && !args.stills) {
  const from = Number(args.from ?? 0), to = Number(args.to ?? 36), fps = Number(args.fps ?? 60);
  const frames = Math.round((to - from) * fps);
  const work = mkdtempSync(join(tmpdir(), "trailer-segments-"));
  const segments = Array.from({ length: workers }, (_, k) => {
    const a = Math.round((frames * k) / workers), b = Math.round((frames * (k + 1)) / workers);
    return { from: from + a / fps, to: from + b / fps, out: join(work, `segment-${k}.mp4`) };
  });
  const self = fileURLToPath(import.meta.url);
  await Promise.all(segments.map((seg, k) => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [self, "--from", String(seg.from), "--to", String(seg.to), "--fps", String(fps), "--out", seg.out], { stdio: ["ignore", "pipe", "inherit"] });
    child.stdout.on("data", (d) => process.stdout.write(`[${k}] ${String(d).trim().split("\r").pop()}\n`));
    child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`segment ${k} failed`))));
  })));
  writeFileSync(join(work, "list.txt"), segments.map((seg) => `file '${seg.out}'`).join("\n"));
  mkdirSync(dirname(out), { recursive: true });
  await new Promise((resolve, reject) => {
    const ffmpeg = spawn("ffmpeg", ["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", join(work, "list.txt"), "-c", "copy", "-movflags", "+faststart", out], { stdio: "inherit" });
    ffmpeg.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}`))));
  });
  rmSync(work, { recursive: true, force: true });
  console.log(`wrote ${out}`);
  process.exit(0);
}
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".mp4": "video/mp4" };
const server = createServer((req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^(\.\.[/\\])+/, "");
  let file = join(site, path);
  if (existsSync(file) && statSync(file).isDirectory()) file = join(file, "index.html");
  if (!file.startsWith(site) || !existsSync(file)) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": TYPES[extname(file)] ?? "application/octet-stream" });
  createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const CHROME = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const profile = mkdtempSync(join(tmpdir(), "trailer-chrome-"));
const chrome = spawn(CHROME, [
  "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--window-size=1920,1080",
  "--hide-scrollbars", "--force-device-scale-factor=1", "--no-first-run", "--no-default-browser-check", "about:blank",
]);
const endpoint = await new Promise((resolve, reject) => {
  let log = "";
  chrome.stderr.on("data", (d) => {
    log += d;
    const m = log.match(/DevTools listening on (ws:\/\/\S+)/);
    if (m) resolve(m[1]);
  });
  chrome.on("exit", () => reject(new Error("Chrome exited:\n" + log)));
});

const ws = new WebSocket(endpoint);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let nextId = 1;
const pending = new Map();
ws.addEventListener("message", (e) => {
  const msg = JSON.parse(e.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
  }
});
const send = (method, params = {}, sessionId) =>
  new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params, sessionId }));
  });

const { targetId } = await send("Target.createTarget", { url: "about:blank" });
const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
const page = (method, params) => send(method, params, sessionId);
await page("Emulation.setDeviceMetricsOverride", { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
await page("Page.navigate", { url: `${base}/trailer/?render` });
const evaluate = async (expression) =>
  (await page("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result.value;
for (let i = 0; !(await evaluate("window.__trailerReady === true")); i++) {
  if (i > 600) throw new Error("The trailer page never became ready");
  await new Promise((r) => setTimeout(r, 100));
}
const { duration, fps: pageFps } = await evaluate("({ duration: window.__trailer.duration, fps: window.__trailer.fps })");
const fps = Number(args.fps ?? pageFps);
const frame = async (t) => {
  await evaluate(`window.__trailer.render(${t})`);
  const { data } = await page("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width: 1920, height: 1080, scale: 1 } });
  return Buffer.from(data, "base64");
};

try {
  if (args.stills) {
    const dir = args.dir ?? "trailer-stills";
    mkdirSync(dir, { recursive: true });
    for (const t of args.stills.split(",").map(Number)) {
      writeFileSync(join(dir, `t${t.toFixed(2)}.png`), await frame(t));
      console.log(`still ${t}s`);
    }
  } else {
    mkdirSync(dirname(out), { recursive: true });
    const from = Number(args.from ?? 0);
    const to = Number(args.to ?? duration);
    const ffmpeg = spawn(
      "ffmpeg",
      ["-y", "-loglevel", "error", "-f", "image2pipe", "-framerate", String(fps), "-i", "-",
        "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out],
      { stdio: ["pipe", "inherit", "inherit"] },
    );
    const total = Math.round((to - from) * fps);
    const started = Date.now();
    for (let i = 0; i < total; i++) {
      const png = await frame(from + i / fps);
      if (!ffmpeg.stdin.write(png)) await new Promise((r) => ffmpeg.stdin.once("drain", r));
      if (i % fps === 0) process.stdout.write(`\r${(i / fps).toFixed(0)}s / ${(total / fps).toFixed(0)}s  (${((Date.now() - started) / 1000).toFixed(0)}s elapsed)`);
    }
    ffmpeg.stdin.end();
    await new Promise((r, j) => ffmpeg.on("exit", (code) => (code === 0 ? r() : j(new Error(`ffmpeg exited ${code}`)))));
    console.log(`\nwrote ${out}`);
  }
} finally {
  ws.close();
  server.close();
  const exited = new Promise((r) => (chrome.exitCode === null ? chrome.once("exit", r) : r()));
  chrome.kill();
  await exited;
  rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
