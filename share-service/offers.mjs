import { mkdir, readdir, readFile, writeFile, rename, rm, stat } from 'node:fs/promises';
import { createHmac, timingSafeEqual } from 'node:crypto';
import path from 'node:path';
import { createAnalytics,fail,newID,validID,pageOf } from './analytics.mjs';

const html = value => String(value).replace(/[&<>"']/g,c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
const bounded = (value,max,name) => { if (typeof value !== 'string' || value.length > max || /[\u0000-\u0008\u000b-\u001f\u007f]/.test(value)) fail(400,`${name} ist ungültig.`); return value.trim(); };
const flag = (value,fallback) => { if (value === undefined) return fallback; if (typeof value !== 'boolean') fail(400,'Ungültiger Schalter.'); return value; };
export function bookingURL(value) {
  const raw = bounded(value,2048,'Buchungslink'); let url;
  try { url = new URL(raw); } catch { fail(400,'Bitte einen vollständigen HTTPS-Buchungslink eingeben.'); }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password) fail(400,'Buchungslink muss HTTPS ohne Zugangsdaten verwenden.');
  return url.href;
}
function trackingMode(value) {
  if (!['automatic','consent'].includes(value)) fail(400,'Ungültiger Statistik-Modus.');
  return value;
}
function landingPage(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(k => !['sender','buttonTitle','accent'].includes(k))) fail(400,'Ungültige Landingpage.');
  const sender = bounded(value.sender ?? '',100,'Absender'), buttonTitle = bounded(value.buttonTitle ?? 'Termin buchen',60,'Button-Text'), accent = value.accent ?? 'red';
  if (!buttonTitle || !['red','blue','violet','green'].includes(accent)) fail(400,'Ungültiger Button-Text oder Farbe.');
  return { sender,buttonTitle,accent };
}
async function atomicWrite(file,value) {
  const temp = `${file}.${newID()}.tmp`;
  try { await writeFile(temp,JSON.stringify(value),{ mode:0o600,flag:'wx' }); await rename(temp,file); }
  finally { await rm(temp,{ force:true }); }
}
async function readBody(req) {
  if (req.headers['content-type']?.split(';')[0] !== 'application/json') fail(415,'JSON erforderlich.');
  if (Number(req.headers['content-length']) > 16384) fail(413,'Anfrage zu groß.');
  const chunks = []; let bytes = 0;
  const timeout = setTimeout(() => req.destroy(),5000); timeout.unref();
  try { for await (const c of req) { bytes += c.length; if (bytes > 16384) fail(413,'Anfrage zu groß.'); chunks.push(c); } }
  finally { clearTimeout(timeout); }
  let body; try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { fail(400,'Ungültiges JSON.'); }
  if (!body || Array.isArray(body) || typeof body !== 'object') fail(400,'Ungültige Anfrage.');
  return body;
}
export function offerPage(offer,prefix,{ preview = false,enabled = true,privacyURL = '',operatorName = '' } = {}) {
  const tracking = enabled && offer.trackingEnabled && !preview;
  const automatic = offer.trackingMode === 'automatic', page = landingPage(offer.landingPage ?? {});
  const choice = tracking ? `<section class="tracking" aria-label="Wiedergabe-Statistik"><p><strong>${automatic ? 'Wiedergabe-Statistik' : 'Wiedergabe-Statistik teilen?'}</strong><br>${automatic ? 'Der Absender erhält automatisch Öffnungen, abgespielte Bereiche und Klicks auf den Terminbutton. Ohne Cookies oder Wiedererkennung über andere Seiten. Du kannst die Messung ausschalten.' : 'Der Absender sieht, wann dieser Link geöffnet und welche Teile abgespielt werden. Du kannst das Video auch ohne Statistik ansehen.'}</p>${automatic ? '' : '<div id="tracking-choice"><button id="allow-tracking">Statistik erlauben</button> <button id="deny-tracking">Ohne Statistik ansehen</button></div>'}<button id="withdraw-tracking"${automatic ? '' : ' hidden'}>${automatic ? 'Statistik ausschalten' : 'Statistik widerrufen'}</button><p id="tracking-status" role="status"></p><noscript>JavaScript ist aus. Es wird keine Wiedergabe-Statistik erfasst.</noscript></section>` : '';
  return `<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${html(offer.title)} · ${html(page.sender || 'Rekord')}</title><link rel="stylesheet" href="${prefix}/assets/player.css"><script defer src="${prefix}/assets/player.js"></script>${tracking ? `<script type="module" src="${prefix}/assets/tracking.js"></script>` : ''}</head><body class="offer-page accent-${page.accent}"><header><span class="brand">${html(page.sender || 'Rekord')}</span><span class="private">Nur über diesen Link erreichbar</span></header><main${tracking ? ` data-offer-api="${prefix}/api/offers/${offer.id}" data-tracking-mode="${automatic ? 'automatic' : 'consent'}"` : ''}><div class="eyebrow">${preview ? 'VORSCHAU · OHNE STATISTIK' : 'DEIN VIDEO-ANGEBOT'}</div><h1>${html(offer.title)}</h1>${offer.message ? `<p class="offer-message">${html(offer.message)}</p>` : ''}<div class="player"><video controls playsinline preload="metadata" src="${prefix}/om/${offer.id}"></video></div><a class="booking" id="book" href="${html(offer.bookingURL)}" target="_blank" rel="noopener noreferrer">${html(page.buttonTitle)} <span aria-hidden="true">↗</span></a>${choice}<p id="feedback" role="status"></p></main><footer>${operatorName ? `${html(operatorName)} · ` : ''}Aufgenommen mit Rekord${privacyURL ? ` · <a href="${html(privacyURL)}" target="_blank" rel="noopener noreferrer">Datenschutz</a>` : ''}</footer></body></html>`;
}
export async function createOfferStore({ storageDirectory,uploadToken,getVideo,origin,prefix,authorize,json,headers,now = Date.now,enabled = true,privacyURL = '',operatorName = '',analyticsOptions = {} }) {
  if (privacyURL) privacyURL = bookingURL(privacyURL);
  operatorName = bounded(operatorName,180,'Betreiber');
  const directory = path.join(storageDirectory,'offers'); await mkdir(directory,{ recursive:true,mode:0o700 });
  const offers = new Map(); let problems = 0;
  for (const name of await readdir(directory)) {
    if (!/^[A-Za-z0-9_-]{32}\.json$/.test(name)) continue;
    try {
      const o = JSON.parse(await readFile(path.join(directory,name),'utf8'));
      if (o.version !== 1 || o.id !== name.slice(0,-5) || !validID(o.videoId) || !validID(o.trackingRevision) || !Number.isFinite(o.durationSeconds) || o.durationSeconds <= 0 || !Number.isFinite(Date.parse(o.createdAt))) throw Error('schema');
      bounded(o.title,180,'Titel'); bounded(o.message,1000,'Nachricht'); bounded(o.recipientLabel,120,'Empfänger'); bookingURL(o.bookingURL);
      if (o.trackingMode !== undefined) trackingMode(o.trackingMode);
      if (o.landingPage !== undefined) landingPage(o.landingPage);
      offers.set(o.id,o);
    } catch { problems++; await mkdir(path.join(directory,'quarantine'),{ recursive:true,mode:0o700 }); await rename(path.join(directory,name),path.join(directory,'quarantine',name)); }
  }
  const analytics = await createAnalytics({ directory:path.join(storageDirectory,'analytics'),write:atomicWrite,now,...analyticsOptions });
  let tail = Promise.resolve(), pending = 0;
  // A single bounded writer also makes global quota checks atomic across different offer IDs.
  async function serial(fn) {
    if (pending >= 100) fail(429,'Statistik beschäftigt. Bitte später erneut versuchen.');
    pending++;
    const next = tail.then(fn); tail = next.catch(() => {});
    try { return await next; } finally { pending--; }
  }
  const file = id => path.join(directory,`${id}.json`);
  const save = async o => { await atomicWrite(file(o.id),o); offers.set(o.id,o); return o; };
  async function deactivate(o) {
    if (!o.revokedAt) await save({ ...o,revokedAt:new Date(now()).toISOString() });
    await analytics.remove(o.id);
  }
  async function active(id,cleanup = true) {
    const o = offers.get(id);
    if (!o || o.revokedAt) fail(404,'Angebot nicht verfügbar.');
    if (o.expiresAt && Date.parse(o.expiresAt) <= now()) { if (cleanup) await deactivate(o); fail(410,'Dieser Angebotslink ist abgelaufen.'); }
    let v;
    try { v = await getVideo(o.videoId); }
    catch (e) { if (cleanup && [404,410].includes(e.status)) await deactivate(o); throw e; }
    // Offers never inherit the guide exception to a parent's configured expiry.
    if (v.expiresAt && Date.parse(v.expiresAt) <= now()) { if (cleanup) await deactivate(o); fail(410,'Dieser Angebotslink ist abgelaufen.'); }
    return { ...o,expiresAt:earliest(o.expiresAt,v.expiresAt),durationSeconds:v.durationSeconds };
  }
  function earliest(a,b) { return a && b ? (Date.parse(a) < Date.parse(b) ? a : b) : a || b || null; }
  function expiry(value,parent) {
    if (value !== null && (typeof value !== 'string' || !Number.isFinite(Date.parse(value)) || Date.parse(value) <= now())) fail(400,'Ungültiges Ablaufdatum.');
    if (parent && (value === null || Date.parse(value) > Date.parse(parent))) fail(400,'Zuerst die Laufzeit des Videos verlängern.');
    return value === null ? null : new Date(Date.parse(value)).toISOString();
  }
  const result = o => ({ ...o,url:`${origin()}/o/${o.id}`,summary:{ ...analytics.summary(o.id,o.durationSeconds),...(!enabled || !o.trackingEnabled ? { state:'disabled' } : {}) } });
  const sign = value => createHmac('sha256',uploadToken).update(`rekord-offer-preview:${value}`).digest('base64url');
  function previewToken(id) { const payload = `${id}.${now()+15*60000}`; return `${payload}.${sign(payload)}`; }
  function checkPreview(id,token) {
    const parts = token.split('.'), payload = parts.slice(0,2).join('.');
    if (parts.length !== 3 || parts[0] !== id || !Number.isFinite(Number(parts[1])) || Number(parts[1]) < now() || parts[2].length !== 43 || !timingSafeEqual(Buffer.from(parts[2]),Buffer.from(sign(payload)))) fail(403,'Vorschau abgelaufen. Bitte in Rekord erneut öffnen.');
  }
  const rate = new Map();
  function throttle(key,limit) {
    const time = now();
    for (const [k,v] of rate) if (v.until <= time) rate.delete(k);
    let v = rate.get(key); if (!v) { if (rate.size >= 20000) fail(429,'Zu viele Messanfragen.'); v = { until:time+60000,count:0 }; rate.set(key,v); }
    if (++v.count > limit) fail(429,'Zu viele Messanfragen.');
  }
  function sameOrigin(req) {
    if (req.headers.origin !== new URL(origin()).origin || req.headers['sec-fetch-site'] && req.headers['sec-fetch-site'] !== 'same-origin') fail(403,'Messung nur von der Angebotsseite erlaubt.');
  }
  async function living() {
    const list = [];
    for (const id of offers.keys()) { try { list.push(await active(id)); } catch (e) { if (![404,410].includes(e.status)) throw e; } }
    return list;
  }
  async function sweep() {
    await living(); await analytics.sweep();
    const quarantine = path.join(directory,'quarantine');
    for (const name of await readdir(quarantine).catch(() => [])) {
      const file = path.join(quarantine,name);
      if ((await stat(file)).mtimeMs <= now()-90*86400000) { await rm(file,{ force:true }); await analytics.remove(name.slice(0,-5)); }
    }
    for (const o of offers.values()) if (o.revokedAt && Date.parse(o.revokedAt) <= now()-90*86400000) { await rm(file(o.id),{ force:true }); offers.delete(o.id); }
  }
  await serial(sweep);
  return {
    health:() => ({ ...analytics.health(),problems }),
    features:() => enabled ? ['video-offers-v1','video-analytics-v1','video-offer-templates-v1','video-analytics-automatic-v1'] : [],
    async sweep() { return serial(sweep); },
    async revokeVideo(videoId) { return serial(async () => { for (const o of offers.values()) if (o.videoId === videoId) await deactivate(o); }); },
    async media(id) { return active(id,false); },
    async route(req,res,url) {
      const page = /^\/o\/([A-Za-z0-9_-]{32})$/.exec(url.pathname);
      if (page && ['GET','HEAD'].includes(req.method)) {
        let o;
        try { o = await active(page[1],false); }
        catch (error) {
          if (![404,410].includes(error.status)) throw error;
          const text = error.status === 410 ? 'Dieser Angebotslink ist abgelaufen.' : 'Dieses Video-Angebot ist nicht mehr verfügbar.';
          const body = Buffer.from(`<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${text} · Rekord</title><link rel="stylesheet" href="${prefix}/assets/player.css"></head><body><main class="gone"><p class="brand">rekord</p><h1>${text}</h1><p>Bitte frag nach einem neuen Link.</p></main></body></html>`);
          res.writeHead(error.status,{ ...headers,'Content-Type':'text/html; charset=utf-8','Content-Length':body.length }); res.end(req.method === 'HEAD' ? undefined : body); return true;
        }
        const preview = url.searchParams.has('preview'); if (preview) checkPreview(o.id,url.searchParams.get('preview'));
        const body = Buffer.from(offerPage(o,prefix,{ preview,enabled,privacyURL,operatorName }));
        res.writeHead(200,{ ...headers,'Content-Type':'text/html; charset=utf-8','Content-Length':body.length }); res.end(req.method === 'HEAD' ? undefined : body); return true;
      }
      const match = /^\/api\/offers(?:\/([A-Za-z0-9_-]{32})(?:\/(analytics|preview|sessions|events)(?:\/([A-Za-z0-9_-]{32}))?)?)?$/.exec(url.pathname);
      const activity = url.pathname === '/api/offer-activity';
      if (!match && !activity) return false;
      const [,id,action,sid] = match ?? [];
      const publicWrite = action === 'sessions' || action === 'events';
      if (publicWrite) { sameOrigin(req); throttle(`client:${req.socket.remoteAddress}`,600); }
      else authorize(req);
      const body = ['POST','PATCH','DELETE'].includes(req.method) && (publicWrite || req.method !== 'DELETE' && action !== 'preview') ? await readBody(req) : null;
      await serial(async () => {
        await analytics.sweep();
        if (activity && req.method === 'GET') return json(res,200,analytics.activities(await living(),url.searchParams.get('after') ?? ''));
        if (!id && req.method === 'GET') {
          const listing = pageOf((await living()).map(o => ({ ...result(o),cursor:`${o.createdAt}|${o.id}` })),url.searchParams.get('after') ?? '');
          return json(res,200,{ offers:listing.entries,nextCursor:listing.nextCursor,hasMore:listing.hasMore });
        }
        if (!id && req.method === 'POST') {
          if (!enabled) fail(503,'Video-Angebote sind vorübergehend deaktiviert.');
          if (!validID(body.videoId) || typeof body.creationRequestId !== 'string' || !/^[A-Za-z0-9_-]{16,80}$/.test(body.creationRequestId)) fail(400,'Ungültige Angebotsanfrage.');
          const v = await getVideo(body.videoId);
          if (v.expiresAt && Date.parse(v.expiresAt) <= now()) fail(410,'Video abgelaufen.');
          const input = { videoId:v.id,creationRequestId:body.creationRequestId,recipientLabel:bounded(body.recipientLabel ?? '',120,'Empfänger'),title:bounded(body.title ?? v.title,180,'Titel'),message:bounded(body.message ?? '',1000,'Nachricht'),bookingURL:bookingURL(body.bookingURL),trackingEnabled:flag(body.trackingEnabled,true),notifyOnFirstOpen:flag(body.notifyOnFirstOpen,true),expiresAt:expiry(body.expiresAt === undefined ? v.expiresAt ?? null : body.expiresAt,v.expiresAt) };
          if (body.trackingMode !== undefined) input.trackingMode = trackingMode(body.trackingMode);
          if (body.landingPage !== undefined) input.landingPage = landingPage(body.landingPage);
          if (!input.title) fail(400,'Titel fehlt.');
          const fingerprint = JSON.stringify(input);
          const previous = [...offers.values()].find(o => o.creationRequestId === input.creationRequestId);
          if (previous) { if (previous.creationFingerprint !== fingerprint) fail(409,'Anfrage-ID wurde bereits anders verwendet.'); return json(res,201,result(await active(previous.id))); }
          if (offers.size >= 10000) fail(507,'Angebotslimit erreicht.');
          const o = await save({ ...input,version:1,id:newID(),trackingRevision:newID(),creationFingerprint:fingerprint,durationSeconds:v.durationSeconds,createdAt:new Date(now()).toISOString(),revokedAt:null });
          return json(res,201,result(o));
        }
        const o = await active(id);
        if (!action && req.method === 'DELETE') { await deactivate(o); res.writeHead(204,headers); return res.end(); }
        if (!action && req.method === 'PATCH') {
          const next = { ...offers.get(id) };
          const allowed = ['recipientLabel','title','message','bookingURL','trackingEnabled','notifyOnFirstOpen','expiresAt','trackingMode','landingPage'];
          if (Object.keys(body).some(k => !allowed.includes(k))) fail(400,'Unbekanntes Angebotsfeld.');
          for (const [key,max] of [['recipientLabel',120],['title',180],['message',1000]]) if (key in body) next[key] = bounded(body[key],max,key);
          if (!next.title) fail(400,'Titel fehlt.');
          if ('trackingMode' in body) next.trackingMode = trackingMode(body.trackingMode);
          if ('landingPage' in body) next.landingPage = landingPage(body.landingPage);
          if ('bookingURL' in body) next.bookingURL = bookingURL(body.bookingURL);
          if ('expiresAt' in body) next.expiresAt = expiry(body.expiresAt,(await getVideo(o.videoId)).expiresAt);
          next.trackingEnabled = flag(body.trackingEnabled,next.trackingEnabled); next.notifyOnFirstOpen = flag(body.notifyOnFirstOpen,next.notifyOnFirstOpen);
          if (next.trackingEnabled !== o.trackingEnabled || next.trackingMode !== o.trackingMode) next.trackingRevision = newID();
          await save(next); return json(res,200,result(await active(id)));
        }
        if (action === 'preview' && req.method === 'POST') return json(res,200,{ url:`${origin()}/o/${id}?preview=${previewToken(id)}` });
        if (action === 'analytics' && req.method === 'GET') return json(res,200,{ ...analytics.detail(id,o.durationSeconds,url.searchParams.get('after') ?? ''),durationSeconds:o.durationSeconds });
        if (action === 'analytics' && req.method === 'DELETE') { await analytics.reset(id); res.writeHead(204,headers); return res.end(); }
        // Withdrawal remains possible after tracking is disabled, and even for idle sessions.
        if (action === 'sessions' && sid && req.method === 'DELETE') { await analytics.withdraw(id,sid,body.sessionKey); res.writeHead(204,headers); return res.end(); }
        if (publicWrite && (!enabled || !o.trackingEnabled)) fail(403,'Statistik ist ausgeschaltet.');
        if (action === 'sessions' && !sid && req.method === 'POST') { throttle(`offer:${id}`,30); return json(res,201,await analytics.start(o,body)); }
        if (action === 'events' && req.method === 'POST') { throttle(`session:${id}:${bounded(body.sessionId,32,'Session')}`,12); await analytics.event(o,body); res.writeHead(204,headers); return res.end(); }
        fail(404,'Nicht gefunden.');
      });
      return true;
    }
  };
}
