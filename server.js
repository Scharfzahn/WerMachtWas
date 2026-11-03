// Einfaches Listen-Tool (z. B. Klassenfrühstück) – reines Node.js, keine Abhängigkeiten.
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = process.env.PORT || 3000;
const PASSWORD = process.env.PASSWORD || 'Klasse8T';
const SECRET = process.env.SECRET || crypto.createHash('sha256').update('secret:' + PASSWORD).digest('hex');
const DATA_FILE = process.env.DATA_FILE || path.join(__dirname, 'data.json');
const PUBLIC_DIR = path.join(__dirname, 'public');

// ---------- Daten ----------
function loadData() {
  try {
    return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  } catch {
    return { lists: [] };
  }
}
let data = loadData();
function saveData() {
  const tmp = DATA_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
  fs.renameSync(tmp, DATA_FILE);
}
const id = () => crypto.randomBytes(6).toString('hex');
const clean = (v, max = 200) => String(v ?? '').trim().slice(0, max);

// ---------- Login (signiertes Cookie) ----------
function sign(value) {
  return crypto.createHmac('sha256', SECRET).update(value).digest('hex');
}
function makeToken() {
  const exp = Date.now() + 1000 * 60 * 60 * 24 * 30; // 30 Tage
  return `${exp}.${sign(String(exp))}`;
}
function validToken(token) {
  if (!token) return false;
  const [exp, sig] = token.split('.');
  if (!exp || !sig || Number(exp) < Date.now()) return false;
  const expected = sign(exp);
  return sig.length === expected.length &&
    crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected));
}
function getCookie(req, name) {
  const header = req.headers.cookie || '';
  for (const part of header.split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k === name) return decodeURIComponent(v.join('='));
  }
  return null;
}
function passwordOk(input) {
  const a = crypto.createHash('sha256').update(String(input)).digest();
  const b = crypto.createHash('sha256').update(PASSWORD).digest();
  return crypto.timingSafeEqual(a, b);
}

// ---------- Helpers ----------
function send(res, status, body, headers = {}) {
  const isJson = typeof body !== 'string' && !Buffer.isBuffer(body);
  res.writeHead(status, {
    'Content-Type': isJson ? 'application/json; charset=utf-8' : 'text/plain; charset=utf-8',
    ...headers,
  });
  res.end(isJson ? JSON.stringify(body) : body);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (c) => {
      raw += c;
      if (raw.length > 1e5) { reject(new Error('too large')); req.destroy(); }
    });
    req.on('end', () => {
      try { resolve(raw ? JSON.parse(raw) : {}); } catch { resolve({}); }
    });
  });
}
const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript' };
function serveStatic(req, res) {
  const urlPath = req.url.split('?')[0];
  const file = path.normalize(path.join(PUBLIC_DIR, urlPath === '/' ? 'index.html' : urlPath));
  if (!file.startsWith(PUBLIC_DIR)) return send(res, 403, 'Forbidden');
  fs.readFile(file, (err, content) => {
    if (err) return send(res, 404, 'Nicht gefunden');
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
    res.end(content);
  });
}

// ---------- API ----------
async function api(req, res, parts) {
  const method = req.method;

  if (parts[0] === 'login' && method === 'POST') {
    const body = await readBody(req);
    if (!passwordOk(body.password || '')) return send(res, 401, { error: 'Falsches Passwort' });
    return send(res, 200, { ok: true }, {
      'Set-Cookie': `auth=${makeToken()}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${60 * 60 * 24 * 30}`,
    });
  }
  if (parts[0] === 'logout' && method === 'POST') {
    return send(res, 200, { ok: true }, { 'Set-Cookie': 'auth=; HttpOnly; Path=/; Max-Age=0' });
  }

  if (!validToken(getCookie(req, 'auth'))) return send(res, 401, { error: 'Nicht eingeloggt' });

  // GET /api/lists
  if (parts[0] === 'lists' && parts.length === 1) {
    if (method === 'GET') return send(res, 200, data.lists);
    if (method === 'POST') {
      const body = await readBody(req);
      const title = clean(body.title, 100);
      if (!title) return send(res, 400, { error: 'Titel fehlt' });
      const list = { id: id(), title, date: clean(body.date, 20), note: clean(body.note, 500), items: [], created: Date.now() };
      data.lists.unshift(list);
      saveData();
      return send(res, 201, list);
    }
  }

  const list = data.lists.find((l) => l.id === parts[1]);
  if (parts[0] === 'lists' && parts[1] && !list) return send(res, 404, { error: 'Liste nicht gefunden' });

  // /api/lists/:id
  if (parts[0] === 'lists' && parts.length === 2) {
    if (method === 'DELETE') {
      data.lists = data.lists.filter((l) => l !== list);
      saveData();
      return send(res, 200, { ok: true });
    }
    if (method === 'PATCH') {
      const body = await readBody(req);
      if (body.title !== undefined) list.title = clean(body.title, 100) || list.title;
      if (body.date !== undefined) list.date = clean(body.date, 20);
      if (body.note !== undefined) list.note = clean(body.note, 500);
      saveData();
      return send(res, 200, list);
    }
  }

  // /api/lists/:id/items
  if (parts[0] === 'lists' && parts[2] === 'items' && parts.length === 3 && method === 'POST') {
    const body = await readBody(req);
    const what = clean(body.what, 150);
    if (!what) return send(res, 400, { error: 'Eintrag fehlt' });
    const item = { id: id(), what, who: clean(body.who, 60), done: false };
    list.items.push(item);
    saveData();
    return send(res, 201, item);
  }

  // /api/lists/:id/items/:itemId
  if (parts[0] === 'lists' && parts[2] === 'items' && parts.length === 4) {
    const item = list.items.find((i) => i.id === parts[3]);
    if (!item) return send(res, 404, { error: 'Eintrag nicht gefunden' });
    if (method === 'DELETE') {
      list.items = list.items.filter((i) => i !== item);
      saveData();
      return send(res, 200, { ok: true });
    }
    if (method === 'PATCH') {
      const body = await readBody(req);
      if (body.what !== undefined) item.what = clean(body.what, 150) || item.what;
      if (body.who !== undefined) item.who = clean(body.who, 60);
      if (body.done !== undefined) item.done = !!body.done;
      saveData();
      return send(res, 200, item);
    }
  }

  return send(res, 404, { error: 'Unbekannte Anfrage' });
}

http.createServer(async (req, res) => {
  try {
    const urlPath = req.url.split('?')[0];
    if (urlPath.startsWith('/api/')) {
      const parts = urlPath.slice(5).split('/').filter(Boolean);
      return await api(req, res, parts);
    }
    serveStatic(req, res);
  } catch (e) {
    console.error(e);
    send(res, 500, { error: 'Serverfehler' });
  }
}).listen(PORT, () => console.log(`Listen-Tool läuft auf http://localhost:${PORT}`));
