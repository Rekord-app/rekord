import http from 'node:http';
import { createOfferStore } from './offers.mjs';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, readFile, rename, rm, stat, readdir, open, writeFile } from 'node:fs/promises';
import { randomBytes, timingSafeEqual, createHash } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const assets = fileURLToPath(new URL('./public/', import.meta.url));
const validSource = /^[A-Za-z0-9_-]{1,128}$/;
const validID = /^[A-Za-z0-9_-]{32}$/;
const html = value => String(value).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
const headers = {
  'X-Content-Type-Options':'nosniff', 'Referrer-Policy':'no-referrer',
  'X-Robots-Tag':'noindex, nofollow, noarchive', 'Cache-Control':'no-store',
  'Content-Security-Policy':"default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; media-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'",
};
// Minimal, bounded MP4 inspection: top-level boxes must start with ftyp and contain media data plus a movie
// header with a positive duration and at least one video track. Reads only box headers and the moov box (≤ 64 MiB).
function mp4Children(buffer) {
  const boxes = []; let offset = 0;
  while (offset+8 <= buffer.length) {
    let size = buffer.readUInt32BE(offset), header = 8; const type = buffer.toString('latin1',offset+4,offset+8);
    if (size === 1) { if (offset+16 > buffer.length) break; const big = buffer.readBigUInt64BE(offset+8); if (big > BigInt(buffer.length)) break; size = Number(big); header = 16; }
    else if (size === 0) size = buffer.length-offset;
    if (size < header || offset+size > buffer.length) break;
    boxes.push({ type,data:buffer.subarray(offset+header,offset+size) }); offset += size;
  }
  return boxes;
}
function moovDuration(moov) {
  const boxes = mp4Children(moov), mvhd = boxes.find(box => box.type === 'mvhd');
  if (!mvhd || mvhd.data.length < 20) return false;
  let timescale, duration;
  if (mvhd.data[0] === 1) { if (mvhd.data.length < 32) return false; timescale = mvhd.data.readUInt32BE(20); duration = Number(mvhd.data.readBigUInt64BE(24)); }
  else { timescale = mvhd.data.readUInt32BE(12); duration = mvhd.data.readUInt32BE(16); }
  if (!timescale || !duration) return false;
  const hasVideo = boxes.filter(box => box.type === 'trak').some(trak => {
    const mdia = mp4Children(trak.data).find(box => box.type === 'mdia');
    const hdlr = mdia && mp4Children(mdia.data).find(box => box.type === 'hdlr');
    return Boolean(hdlr && hdlr.data.length >= 12 && hdlr.data.toString('latin1',8,12) === 'vide');
  });
  return hasVideo && Number.isFinite(duration/timescale) ? duration/timescale : 0;
}
export async function inspectMP4(file,size) {
  const handle = await open(file,'r');
  try {
    const head = Buffer.alloc(16); let offset = 0, first = true, moov = null, media = false;
    while (offset+8 <= size) {
      await handle.read(head,0,16,offset);
      let boxSize = head.readUInt32BE(0), header = 8; const type = head.toString('latin1',4,8);
      if (boxSize === 1) { const big = head.readBigUInt64BE(8); if (big > BigInt(size)) return false; boxSize = Number(big); header = 16; }
      else if (boxSize === 0) boxSize = size-offset;
      if (boxSize < header || offset+boxSize > size) return false;
      if (first && type !== 'ftyp') return false; first = false;
      if (type === 'moov') { if (boxSize > 64*1024**2) return false; moov = Buffer.alloc(boxSize-header); await handle.read(moov,0,moov.length,offset+header); }
      if (type === 'mdat' && boxSize > header) media = true;
      offset += boxSize;
    }
    return moov && media ? moovDuration(moov) : 0;
  } finally { await handle.close(); }
}
export async function isPlayableMP4(file,size) { return Boolean(await inspectMP4(file,size)); }
// Optional link under shared guides ("Diesen Ablauf automatisieren lassen"); none unless CTA_URL is set.
const defaultCTA = '';
const automatable = { ja:'automatisierbar', teilweise:'teilweise', nein:'bleibt manuell' };
const methods = { api:'Offizielle API', n8n:'n8n-Workflow', triggerdev:'Trigger.dev-Task', claudeCode:'Claude-Code-Skript', browserAgent:'Browser-Agent', human:'Mensch' };
const text = (value, max, field) => { if (value === undefined || value === null || value === '') return ''; if (typeof value !== 'string' || value.length > max) throw new RequestError(400,`Ungültiges Feld: ${field}.`); return value.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g,''); };
// Validates an uploaded guide. Only these fields are stored; images must be JPEG.
function parseGuide(body) {
  let input; try { input = JSON.parse(body.toString('utf8')); } catch { throw new RequestError(400,'Anleitung ist kein gültiges JSON.'); }
  if (!input || typeof input !== 'object' || !Array.isArray(input.steps) || input.steps.length < 1 || input.steps.length > 200) throw new RequestError(400,'Anleitung braucht 1 bis 200 Schritte.');
  const steps = input.steps.map((step,i) => {
    if (!step || typeof step !== 'object') throw new RequestError(400,'Ungültiger Schritt.');
    let image = null;
    if (step.image !== undefined && step.image !== null) {
      if (typeof step.image !== 'string' || step.image.length > 6*1024*1024) throw new RequestError(413,'Schritt-Bild ist zu groß.');
      image = Buffer.from(step.image,'base64');
      if (image.length < 4 || image[0] !== 0xff || image[1] !== 0xd8 || image[2] !== 0xff) throw new RequestError(415,'Schritt-Bilder müssen JPEG sein.');
    }
    return { text:text(step.text,600,'text') || `Schritt ${i+1}`, note:text(step.note,600,'note'), warning:text(step.warning,600,'warning'), image };
  });
  let brief = null;
  if (input.brief && typeof input.brief === 'object') {
    const groups = Array.isArray(input.brief.groups) ? input.brief.groups.slice(0,50).map(group => ({
      title:text(group?.title,200,'brief.title'), automatable:automatable[group?.automatable] ? group.automatable : 'nein', method:methods[group?.method] ? group.method : 'human',
      steps:Array.isArray(group?.steps) ? group.steps.filter(n => Number.isInteger(n) && n > 0 && n <= steps.length).slice(0,200) : [] })) : [];
    brief = { summary:text(input.brief.summary,1500,'brief.summary'), saving:text(input.brief.saving,300,'brief.saving'), groups };
  }
  const apps = Array.isArray(input.apps) ? input.apps.filter(a => typeof a === 'string').slice(0,10).map(a => a.slice(0,60)) : [];
  if (input.videoId != null) throw new RequestError(409,'Bitte die App aktualisieren: Anleitungen dürfen kein Rohvideo enthalten.');
  if (input.sourceGuideId != null && (typeof input.sourceGuideId !== 'string' || !validSource.test(input.sourceGuideId))) throw new RequestError(400,'Ungültige Anleitungs-ID.');
  return { title:text(input.title,180,'title') || 'Anleitung', summary:text(input.summary,1000,'summary'), apps, steps, brief, cta:input.cta !== false, sourceGuideId:input.sourceGuideId || null, videoId:null };
}
function guidePage(item, prefix, ctaURL) {
  const date = new Date(item.createdAt).toLocaleDateString('de-DE',{ day:'numeric',month:'long',year:'numeric' });
  const meta = [item.apps.join(', '),`${item.steps.length} Schritte`,date].filter(Boolean).map(html).join(' · ');
  const steps = item.steps.map((step,i) => `<li class="step" id="schritt-${i+1}"><div class="head"><span class="num">${i+1}</span><p>${html(step.text)}</p></div>${step.note ? `<p class="note"><b>Tipp:</b> ${html(step.note)}</p>` : ''}${step.warning ? `<p class="warn"><b>Achtung:</b> ${html(step.warning)}</p>` : ''}${step.image ? `<a class="shot" href="${prefix}/gi/${item.id}/${i+1}.jpg"><img src="${prefix}/gi/${item.id}/${i+1}.jpg" alt="Bildschirm zu Schritt ${i+1}" loading="lazy" width="1600"></a>` : ''}</li>`).join('');
  const brief = item.brief ? `<section class="brief"><h2>Was sich davon automatisieren lässt</h2>${item.brief.summary ? `<p>${html(item.brief.summary)}</p>` : ''}${item.brief.saving ? `<p class="saving">${html(item.brief.saving)}</p>` : ''}<ul>${item.brief.groups.map(g => `<li><span class="badge ${html(g.automatable)}">${html(automatable[g.automatable])}</span><b>${html(g.title)}</b><small>${html(methods[g.method])}${g.steps.length ? ` · Schritt ${g.steps.join(', ')}` : ''}</small></li>`).join('')}</ul></section>` : '';
  const cta = item.cta && ctaURL ? `<a class="cta" href="${html(ctaURL)}" rel="noopener">Diesen Ablauf automatisieren lassen →</a>` : '';
  const video = item.videoId ? `<details class="video"><summary>Video des ganzen Ablaufs ansehen</summary><video controls playsinline preload="none" src="${prefix}/media/${item.videoId}"></video></details>` : '';
  return `<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${html(item.title)} · Anleitung</title><link rel="stylesheet" href="${prefix}/assets/guide.css"></head><body><header><span class="brand" aria-label="Rekord">Rekord</span><span class="private">Nur über diesen Link erreichbar</span></header><main><div class="eyebrow">ANLEITUNG</div><h1>${html(item.title)}</h1><p class="meta">${meta}</p>${item.summary ? `<p class="summary">${html(item.summary)}</p>` : ''}${video}<ol class="steps">${steps}</ol>${brief}${cta}</main><footer>Erstellt mit Rekord</footer></body></html>`;
}
class RequestError extends Error { constructor(status, message) { super(message); this.status = status; } }
function rangeFor(value, size) {
  if (!value) return { start:0, end:size-1, partial:false };
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!match || (!match[1] && !match[2])) throw new RequestError(416,'Ungültiger Videobereich.');
  let start, end;
  if (!match[1]) { const suffix = Number(match[2]); if (suffix <= 0) throw new RequestError(416,'Ungültiger Videobereich.'); start = Math.max(0,size-suffix); end = size-1; }
  else { start = Number(match[1]); end = match[2] ? Math.min(size-1,Number(match[2])) : size-1; }
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || end < start) throw new RequestError(416,'Ungültiger Videobereich.');
  return { start, end, partial:true };
}
export async function createShareServer({ storageDirectory, uploadToken, publicBaseURL = null, maxUploadBytes = 2*1024**3, maxStorageBytes = 20*1024**3, maxConcurrentUploads = 2, maxGuideBytes = 64*1024**2, ctaURL = defaultCTA,offersEnabled = true,privacyURL = '',operatorName = '',offerOptions = {} } = {}) {
  if (!storageDirectory || typeof uploadToken !== 'string' || uploadToken.length < 32) throw new Error('Storage directory and an upload token of at least 32 characters are required.');
  let baseURL = null, publicPath = "";
  if (publicBaseURL) {
    const url = new URL(publicBaseURL);
    if (url.username || url.password || url.search || url.hash || !/^([/][A-Za-z0-9_-]+)*[/]?$/.test(url.pathname) || (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost','127.0.0.1','[::1]'].includes(url.hostname)))) throw new Error('PUBLIC_BASE_URL must be an HTTPS base URL with an optional simple path (HTTP allowed only on loopback).');
    publicPath = url.pathname.replace(/\/$/,'');
    baseURL = url.origin+publicPath;
  }
  const root = path.resolve(storageDirectory), meta = path.join(root,'metadata'), trash = path.join(root,'revoked');
  await mkdir(meta,{ recursive:true, mode:0o700 }); await mkdir(trash,{ recursive:true, mode:0o700 });
  // A restart may leave interrupted uploads. They never have metadata and are never served.
  for (const file of await readdir(root)) if (/^[A-Za-z0-9_-]{32}\.part$/.test(file)) await rm(path.join(root,file),{ force:true });
  let used = 0; const byHash = new Map(), items = new Map();
  // Count actual media, including an unlisted file left by a crash between renames.
  // Such files remain private and recoverable, but cannot escape the storage quota.
  for (const file of await readdir(root)) if (/^[A-Za-z0-9_-]{32}\.mp4$/.test(file)) used += (await stat(path.join(root,file))).size;
  // Each entry is loaded on its own: a damaged or inconsistent metadata file is moved to private quarantine and
  // reported, while every other link keeps working. Metadata never decides storage paths beyond a valid ID.
  const quarantine = path.join(root,'quarantine'); let problems = 0;
  for (const file of await readdir(meta)) {
    const match = /^([A-Za-z0-9_-]{32})\.json$/.exec(file);
    if (!match) continue;
    try {
      const item = JSON.parse(await readFile(path.join(meta,file),'utf8'));
      const valid = item && item.id === match[1] && typeof item.title === 'string' && Number.isSafeInteger(item.bytes) && item.bytes > 0 &&
        /^[a-f0-9]{64}$/.test(item.sha256) && typeof item.createdAt === 'string' && (item.expiresAt === undefined || item.expiresAt === null || !Number.isNaN(Date.parse(item.expiresAt))) &&
        (await stat(path.join(root,`${item.id}.mp4`))).size === item.bytes;
      if (!valid) throw new Error('inconsistent');
      byHash.set(item.sha256,item); items.set(item.id,item);
    } catch {
      problems += 1;
      await mkdir(quarantine,{ recursive:true,mode:0o700 });
      await rename(path.join(meta,file),path.join(quarantine,file)).catch(() => {});
      console.error(`Rekord share: damaged metadata ${file} moved to quarantine/`);
    }
  }
  // Content quota includes all retained guide files (including metadata, orphans and quarantine).
  // Video quota remains its media size for compatibility with existing clients.
  const diskBytes = async directory => {
    let bytes = 0;
    for (const entry of await readdir(directory,{ withFileTypes:true }).catch(() => [])) {
      const file = path.join(directory,entry.name);
      if (entry.isDirectory()) bytes += await diskBytes(file);
      else if (entry.isFile()) bytes += (await stat(file)).size;
    }
    return bytes;
  };
  for (const file of await readdir(trash)) if (file.endsWith('.mp4')) used += (await stat(path.join(trash,file))).size;
  const guideRoot = path.join(root,'guides'), guideTrash = path.join(trash,'guides'), guides = new Map();
  const journals = path.join(trash,'operations'), revokedVideos = new Set(), revokedGuides = new Set();
  await mkdir(guideRoot,{ recursive:true, mode:0o700 }); await mkdir(guideTrash,{ recursive:true, mode:0o700 });
  await mkdir(journals,{ recursive:true,mode:0o700 });
  const move = async (from,to) => { try { await rename(from,to); } catch (error) { if (['ENOTEMPTY','EEXIST'].includes(error.code)) await rename(from,`${to}-recovered-${randomBytes(6).toString('hex')}`); else if (error.code !== 'ENOENT') throw error; } };
  const finishRevoke = async operation => {
    for (const id of operation.guides) {
      await move(path.join(guideRoot,`${id}.json`),path.join(guideTrash,`${id}.json`));
      await move(path.join(guideRoot,id),path.join(guideTrash,id));
    }
    for (const id of operation.videos) {
      await move(path.join(meta,`${id}.json`),path.join(trash,`${id}.json`));
      await move(path.join(root,`${id}.mp4`),path.join(trash,`${id}.mp4`));
    }
  };
  // A durable deny-list is the commit point. On restart it wins over every metadata file.
  // Invalid journals stop startup rather than accidentally restoring a revoked capability.
  for (const name of await readdir(journals)) if (name.endsWith('.json')) {
    const operation = JSON.parse(await readFile(path.join(journals,name),'utf8'));
    if (!Array.isArray(operation.guides) || !Array.isArray(operation.videos) || ![...operation.guides,...operation.videos].every(id => validID.test(id))) throw new Error('Invalid revocation journal');
    for (const id of operation.guides) revokedGuides.add(id);
    for (const id of operation.videos) { revokedVideos.add(id); const item = items.get(id); items.delete(id); if (item && byHash.get(item.sha256)?.id === id) byHash.delete(item.sha256); }
    await finishRevoke(operation);
  }
  for (const file of await readdir(guideRoot)) {
    const match = /^([A-Za-z0-9_-]{32})\.json$/.exec(file);
    if (!match || revokedGuides.has(match[1])) continue;
    try {
      const item = JSON.parse(await readFile(path.join(guideRoot,file),'utf8'));
      if (!item || item.id !== match[1] || typeof item.title !== 'string' || !Number.isFinite(Date.parse(item.createdAt)) ||
          !Array.isArray(item.apps) || !item.apps.every(app => typeof app === 'string') || !Array.isArray(item.steps) || !item.steps.length || item.steps.length > 200 ||
          !item.steps.every(step => step && typeof step.text === 'string' && typeof step.image === 'boolean') ||
          (item.sourceGuideId != null && (typeof item.sourceGuideId !== 'string' || !validSource.test(item.sourceGuideId))) || (item.videoId != null && (!validID.test(item.videoId) || !items.has(item.videoId))) ||
          (item.brief != null && (!Array.isArray(item.brief.groups) || !item.brief.groups.every(group => group && Array.isArray(group.steps))))) throw new Error('inconsistent guide');
      for (const [i,step] of item.steps.entries()) if (step.image) {
        const image = await readFile(path.join(guideRoot,item.id,`${i+1}.jpg`));
        if (image.length < 4 || image[0] !== 255 || image[1] !== 216 || image[2] !== 255) throw new Error('missing image');
      }
      item.bytes = (await stat(path.join(guideRoot,file))).size + await diskBytes(path.join(guideRoot,item.id));
      guides.set(item.id,item);
    } catch {
      problems += 1;
      const target = path.join(quarantine,'guides'); await mkdir(target,{ recursive:true,mode:0o700 });
      await move(path.join(guideRoot,file),path.join(target,file));
      await move(path.join(guideRoot,match[1]),path.join(target,match[1]));
      console.error(`Rekord share: damaged guide ${file} quarantined`);
    }
  }
  used += await diskBytes(guideRoot) + await diskBytes(guideTrash) + await diskBytes(path.join(quarantine,'guides'));
  let reserved = 0, active = 0, mutations = Promise.resolve(), revocationGeneration = 0;
  const revokedSourceGeneration = new Map();
  const mutate = action => { const result = mutations.then(action); mutations = result.catch(() => {}); return result; };
  const affected = (kind,id) => {
    const videoIDs = new Set(kind === 'video' ? [id] : []), guideIDs = new Set(kind === 'guide' ? [id] : []), sources = new Set();
    let changed = true;
    while (changed) {
      changed = false;
      for (const guide of guides.values()) {
        if (guideIDs.has(guide.id) || (guide.videoId && videoIDs.has(guide.videoId)) || (guide.sourceGuideId && sources.has(guide.sourceGuideId))) {
          if (!guideIDs.has(guide.id)) { guideIDs.add(guide.id); changed = true; }
          if (guide.videoId && !videoIDs.has(guide.videoId)) { videoIDs.add(guide.videoId); changed = true; }
          if (guide.sourceGuideId && !sources.has(guide.sourceGuideId)) { sources.add(guide.sourceGuideId); changed = true; }
        }
      }
    }
    return { guides:[...guideIDs],videos:[...videoIDs] };
  };
  const revoke = (kind,id) => mutate(async () => {
    const known = kind === 'guide' ? guides.has(id) || revokedGuides.has(id) : items.has(id) || revokedVideos.has(id);
    if (!known) throw new RequestError(404,'Freigabe nicht verfügbar.');
    const operation = affected(kind,id), name = randomBytes(24).toString('base64url');
    const temporary = path.join(journals,`${name}.tmp`), destination = path.join(journals,`${name}.json`);
    const handle = await open(temporary,'wx',0o600);
    try { await handle.writeFile(JSON.stringify(operation)); await handle.sync(); } finally { await handle.close(); }
    await rename(temporary,destination);
    const journalDirectory = await open(journals,'r');
    try { await journalDirectory.sync(); } finally { await journalDirectory.close(); }
    revocationGeneration += 1;
    for (const guideID of operation.guides) {
      const source = guides.get(guideID)?.sourceGuideId;
      if (source) revokedSourceGeneration.set(source,revocationGeneration);
      revokedGuides.add(guideID); guides.delete(guideID);
    }
    for (const videoID of operation.videos) { revokedVideos.add(videoID); const item = items.get(videoID); items.delete(videoID); if (item && byHash.get(item.sha256)?.id === videoID) byHash.delete(item.sha256); }
    await finishRevoke(operation);
    return operation;
  });
  const guideReceipt = (item,origin) => ({ id:item.id,title:item.title,bytes:item.bytes,createdAt:item.createdAt,sourceGuideId:item.sourceGuideId || null,videoId:item.videoId || null,url:`${origin}/g/${item.id}` });
  const expected = Buffer.from(`Bearer ${uploadToken}`);
  const authorize = req => { const received = Buffer.from(req.headers.authorization || ''); if (received.length !== expected.length || !timingSafeEqual(received,expected)) throw new RequestError(401,'Upload-Zugang fehlt oder ist ungültig.'); };
  const json = (res,status,value) => { const bytes = Buffer.from(JSON.stringify(value)); res.writeHead(status,{ ...headers,'Content-Type':'application/json; charset=utf-8','Content-Length':bytes.length }); res.end(bytes); };
  // Expiring links: an expired video is gone for viewers at once and its storage is freed (deleted for good, unlike
  // a revoke, which keeps the media privately). Videos used by a shared guide never expire while the guide exists.
  const expired = item => Boolean(item.expiresAt) && Date.parse(item.expiresAt) <= Date.now() && ![...guides.values()].some(guide => guide.videoId === item.id);
  const removeExpired = async item => {
    if (!items.has(item.id)) return;
    items.delete(item.id); if (byHash.get(item.sha256)?.id === item.id) byHash.delete(item.sha256);
    await rm(path.join(meta,`${item.id}.json`),{ force:true }); await rm(path.join(root,`${item.id}.mp4`),{ force:true });
    used = Math.max(0,used-item.bytes);
  };
  const sweep = async () => { let freed = 0; for (const item of [...items.values()]) if (expired(item)) { freed += item.bytes; await removeExpired(item); } if (freed) console.log(`Rekord share: expired links removed, ${Math.round(freed/1024/1024)} MiB freed`); };
  await sweep();
  const sweeper = setInterval(() => { sweep().catch(error => console.error('Rekord share: sweep failed',error)); },60*60*1000); sweeper.unref();
  const metadata = async id => {
    if (!validID.test(id) || !items.has(id)) throw new RequestError(404,'Video nicht verfügbar.');
    const item = items.get(id);
    if (expired(item)) { await removeExpired(item); throw new RequestError(410,'Dieser Link ist abgelaufen.'); }
    return item;
  };
  const offers = await createOfferStore({ storageDirectory:root,uploadToken,prefix:publicPath,authorize,json,headers,
    origin:() => baseURL || `http://127.0.0.1:${server.address().port}`,enabled:offersEnabled,privacyURL,operatorName,...offerOptions,
    getVideo:async id => {
      const existing = await metadata(id);
      if (Number.isFinite(existing.durationSeconds) && existing.durationSeconds > 0) return existing;
      return mutate(async () => {
      let item = await metadata(id);
      if (!Number.isFinite(item.durationSeconds) || item.durationSeconds <= 0) {
        const durationSeconds = await inspectMP4(path.join(root,`${id}.mp4`),item.bytes);
        if (!durationSeconds) throw new RequestError(422,'Videodauer konnte nicht gelesen werden.');
        item = { ...await metadata(id),durationSeconds };
        const temp = path.join(meta,`${id}.${randomBytes(8).toString('hex')}.tmp`);
        await writeFile(temp,JSON.stringify(item),{ mode:0o600 }); await rename(temp,path.join(meta,`${id}.json`));
        items.set(id,item); byHash.set(item.sha256,item);
      }
      return item;
      });
    }
  });
  const offerSweeper = setInterval(() => { offers.sweep().catch(() => console.error('Rekord share: offer cleanup failed')); },60000); offerSweeper.unref();
  const server = http.createServer(async (req,res) => {
    try {
      const url = new URL(req.url,'http://localhost');
      if (publicPath) {
        if (!url.pathname.startsWith(publicPath+'/')) throw new RequestError(404,'Nicht gefunden.');
        url.pathname = url.pathname.slice(publicPath.length);
      }
      if (req.method === 'GET' && url.pathname === '/api/status') { authorize(req); return json(res,200,{ service:'focus-recorder-share',version:1,features:['expiry','guide-lifecycle-v2',...offers.features()],offerAnalytics:offers.health(),maxUploadBytes,availableBytes:Math.max(0,maxStorageBytes-used-reserved),problems }); }
      if (await offers.route(req,res,url)) return;
      if (req.method === 'GET' && url.pathname === '/api/videos') {
        authorize(req); const origin = baseURL || `http://127.0.0.1:${server.address().port}`;
        return json(res,200,{ videos:[...items.values()].sort((a,b) => b.createdAt.localeCompare(a.createdAt)).map(item => ({ ...item,url:`${origin}/v/${item.id}` })) });
      }
      if (req.method === 'POST' && url.pathname === '/api/videos') {
        authorize(req);
        if (req.headers['content-type']?.split(';')[0] !== 'video/mp4') throw new RequestError(415,'Nur MP4-Aufnahmen werden unterstützt.');
        const bytes = Number(req.headers['content-length']);
        if (!Number.isSafeInteger(bytes) || bytes <= 0) throw new RequestError(411,'Dateigröße fehlt.');
        if (bytes > maxUploadBytes) throw new RequestError(413,'Aufnahme überschreitet das Upload-Limit.');
        const expectedHash = req.headers['x-focus-sha256'];
        let expiresAt = null;
        if (req.headers['x-focus-expires-days'] !== undefined) {
          const days = Number(req.headers['x-focus-expires-days']);
          if (!Number.isSafeInteger(days) || days < 1 || days > 3650) throw new RequestError(400,'Ablaufzeit muss 1–3650 Tage sein.');
          expiresAt = new Date(Date.now()+days*86400000).toISOString();
        }
        if (expectedHash !== undefined && !/^[a-f0-9]{64}$/.test(expectedHash)) throw new RequestError(400,'Ungültige Datei-Prüfsumme.');
        const existing = expectedHash && byHash.get(expectedHash);
        if (existing && existing.bytes === bytes) {
          req.resume(); const origin = baseURL || `http://127.0.0.1:${server.address().port}`;
          return json(res,201,{ ...existing,url:`${origin}/v/${existing.id}` });
        }
        if (active >= maxConcurrentUploads) throw new RequestError(429,'Zu viele gleichzeitige Uploads. Bitte erneut versuchen.');
        if (used+reserved+bytes > maxStorageBytes) throw new RequestError(507,'Videospeicher ist voll.');
        const id = randomBytes(24).toString('base64url'), temp = path.join(root,`${id}.part`), destination = path.join(root,`${id}.mp4`);
        reserved += bytes; active += 1;
        let committed = false;
        try {
          let received = 0; const hash = createHash('sha256');
          const meter = new Transform({ transform(chunk,encoding,callback) { received += chunk.length; if (received > bytes) return callback(new RequestError(413,'Dateigröße stimmt nicht überein.')); hash.update(chunk); callback(null,chunk); } });
          await pipeline(req,meter,createWriteStream(temp,{ flags:'wx',mode:0o600 }));
          if (received !== bytes) throw new RequestError(400,'Upload ist unvollständig.');
          const file = await open(temp,'r'); const signature = Buffer.alloc(12);
          try { await file.read(signature,0,12,0); } finally { await file.close(); }
          if (signature.toString('ascii',4,8) !== 'ftyp') throw new RequestError(415,'Datei ist kein MP4-Container.');
          const durationSeconds = await inspectMP4(temp,bytes);
          if (!durationSeconds) throw new RequestError(415,'Datei ist kein abspielbares Video (keine Videospur oder Dauer).');
          let title = 'Bildschirmaufnahme';
          if (typeof req.headers['x-focus-title'] === 'string') title = Buffer.from(req.headers['x-focus-title'],'base64url').toString('utf8').replace(/[\u0000-\u001f\u007f]/g,'').slice(0,180) || title;
          const sha256 = hash.digest('hex');
          if (expectedHash && sha256 !== expectedHash) throw new RequestError(400,'Die Datei-Prüfsumme stimmt nicht überein.');
          const item = { id,title,bytes,sha256,durationSeconds,createdAt:new Date().toISOString(),...(expiresAt ? { expiresAt } : {}) };
          await rename(temp,destination);
          const metadataTemp = path.join(meta,`${id}.tmp`);
          await writeFile(metadataTemp,JSON.stringify(item),{ mode:0o600 });
          await rename(metadataTemp,path.join(meta,`${id}.json`));
          committed = true; used += bytes; byHash.set(item.sha256,item); items.set(item.id,item);
          const origin = baseURL || `http://127.0.0.1:${server.address().port}`;
          return json(res,201,{ ...item,url:`${origin}/v/${id}` });
        } finally {
          try { await rm(temp,{ force:true }); if (!committed) { await rm(destination,{ force:true }); await rm(path.join(meta,`${id}.tmp`),{ force:true }); } }
          finally { reserved -= bytes; active -= 1; }
        }
      }
      const deletion = /^\/api\/videos\/([A-Za-z0-9_-]{32})$/.exec(url.pathname);
      // Change a link's expiry: {"expiresAt": null} keeps it forever, an ISO date in the future sets a new end.
      if (req.method === 'PATCH' && deletion) {
        authorize(req);
        let body = '';
        for await (const chunk of req) { body += chunk; if (body.length > 1024) throw new RequestError(413,'Anfrage zu groß.'); }
        let value;
        try { value = JSON.parse(body).expiresAt; } catch { throw new RequestError(400,'Ungültige Anfrage.'); }
        if (value !== null && (typeof value !== 'string' || Number.isNaN(Date.parse(value)) || Date.parse(value) <= Date.now())) throw new RequestError(400,'expiresAt muss null oder ein Datum in der Zukunft sein.');
        return await mutate(async () => {
          const item = await metadata(deletion[1]);
          const next = { ...item }; if (value === null) delete next.expiresAt; else next.expiresAt = new Date(Date.parse(value)).toISOString();
          if (revokedVideos.has(item.id)) throw new RequestError(404,'Freigabe nicht verfügbar.');
          const metadataTemp = path.join(meta,`${item.id}.tmp`);
          await writeFile(metadataTemp,JSON.stringify(next),{ mode:0o600 }); await rename(metadataTemp,path.join(meta,`${item.id}.json`));
          items.set(item.id,next); byHash.set(next.sha256,next);
          const origin = baseURL || `http://127.0.0.1:${server.address().port}`;
          return json(res,200,{ ...next,url:`${origin}/v/${item.id}` });
        });
      }
      if (req.method === 'DELETE' && deletion) {
        authorize(req); const operation = await revoke('video',deletion[1]);
        for (const id of operation.videos) await offers.revokeVideo(id);
        res.writeHead(204,headers); return res.end();
      }
      if (req.method === 'GET' && url.pathname === '/api/guides') {
        authorize(req); const origin = baseURL || `http://127.0.0.1:${server.address().port}`;
        return json(res,200,{ guides:[...guides.values()].sort((a,b) => b.createdAt.localeCompare(a.createdAt)).map(item => guideReceipt(item,origin)) });
      }
      if (req.method === 'POST' && url.pathname === '/api/guides') {
        authorize(req);
        if (req.headers['content-type']?.split(';')[0] !== 'application/json') throw new RequestError(415,'Anleitungen werden als JSON hochgeladen.');
        const declared = Number(req.headers['content-length']);
        if (!Number.isSafeInteger(declared) || declared <= 0) throw new RequestError(411,'Dateigröße fehlt.');
        if (declared > maxGuideBytes) throw new RequestError(413,'Anleitung überschreitet das Upload-Limit.');
        if (active >= maxConcurrentUploads) throw new RequestError(429,'Zu viele gleichzeitige Uploads. Bitte erneut versuchen.');
        if (used+reserved+declared > maxStorageBytes) throw new RequestError(507,'Speicher ist voll.');
        const requestGeneration = revocationGeneration;
        reserved += declared; active += 1;
        try {
          const chunks = []; let received = 0;
          for await (const chunk of req) { received += chunk.length; if (received > declared) throw new RequestError(413,'Dateigröße stimmt nicht überein.'); chunks.push(chunk); }
          if (received !== declared) throw new RequestError(400,'Upload ist unvollständig.');
          const body = Buffer.concat(chunks), guide = parseGuide(body), fingerprint = createHash('sha256').update(body).digest('hex');
          const item = await mutate(async () => {
            if (guide.sourceGuideId && (revokedSourceGeneration.get(guide.sourceGuideId) ?? 0) > requestGeneration) throw new RequestError(409,'Die Anleitung wurde während des Uploads widerrufen. Bewusst erneut teilen, um einen neuen Link zu erstellen.');
            const existing = guide.sourceGuideId && [...guides.values()].find(item => item.sourceGuideId === guide.sourceGuideId && item.fingerprint === fingerprint);
            if (existing) return existing;
            const id = randomBytes(24).toString('base64url'), folder = path.join(guideRoot,id), temporary = path.join(guideRoot,`${id}.tmp`);
            const steps = guide.steps.map(step => ({ ...step,image:!!step.image }));
            const item = { ...guide,id,steps,fingerprint,bytes:0,createdAt:new Date().toISOString() };
            const imagesBytes = guide.steps.reduce((sum,step) => sum+(step.image?.length || 0),0);
            // bytes includes metadata; stabilize the decimal length of the bytes field itself.
            for (let i = 0; i < 4; i++) item.bytes = imagesBytes+Buffer.byteLength(JSON.stringify(item));
            if (used+reserved-declared+item.bytes > maxStorageBytes) throw new RequestError(507,'Speicher ist voll.');
            let committed = false;
            try {
              await mkdir(folder,{ mode:0o700 });
              for (const [i,step] of guide.steps.entries()) if (step.image) await writeFile(path.join(folder,`${i+1}.jpg`),step.image,{ mode:0o600 });
              await writeFile(temporary,JSON.stringify(item),{ mode:0o600 }); await rename(temporary,path.join(guideRoot,`${id}.json`));
              guides.set(id,item); used += item.bytes; committed = true; return item;
            } finally {
              if (!committed) { await rm(folder,{ recursive:true,force:true }); await rm(temporary,{ force:true }); }
            }
          });
          const origin = baseURL || `http://127.0.0.1:${server.address().port}`;
          return json(res,201,guideReceipt(item,origin));
        } finally { reserved -= declared; active -= 1; }
      }
      const guideDeletion = /^\/api\/guides\/([A-Za-z0-9_-]{32})$/.exec(url.pathname);
      if (req.method === 'DELETE' && guideDeletion) {
        authorize(req); const operation = await revoke('guide',guideDeletion[1]);
        for (const id of operation.videos) await offers.revokeVideo(id);
        res.writeHead(204,headers); return res.end();
      }
      const guideView = /^\/g\/([A-Za-z0-9_-]{32})$/.exec(url.pathname);
      if ((req.method === 'GET' || req.method === 'HEAD') && guideView) {
        const item = guides.get(guideView[1]);
        if (!item) throw new RequestError(404,'Anleitung nicht verfügbar.');
        const body = Buffer.from(guidePage(item,publicPath,ctaURL));
        res.writeHead(200,{ ...headers,'Content-Type':'text/html; charset=utf-8','Content-Length':body.length }); return res.end(req.method === 'HEAD' ? undefined : body);
      }
      const guideImage = /^\/gi\/([A-Za-z0-9_-]{32})\/(\d{1,3})\.jpg$/.exec(url.pathname);
      if ((req.method === 'GET' || req.method === 'HEAD') && guideImage) {
        const item = guides.get(guideImage[1]), n = Number(guideImage[2]);
        if (!item || !item.steps[n-1]?.image) throw new RequestError(404,'Bild nicht verfügbar.');
        const file = await readFile(path.join(guideRoot,item.id,`${n}.jpg`));
        res.writeHead(200,{ ...headers,'Content-Type':'image/jpeg','Content-Length':file.length }); return res.end(req.method === 'HEAD' ? undefined : file);
      }
      const page = /^\/v\/([A-Za-z0-9_-]{32})$/.exec(url.pathname);
      if ((req.method === 'GET' || req.method === 'HEAD') && page) {
        let item;
        try { item = await metadata(page[1]); }
        catch (error) {
          if (![404,410].includes(error.status)) throw error;
          const text = error.status === 410 ? 'Dieser Link ist abgelaufen.' : 'Dieses Video ist nicht (mehr) verfügbar.';
          const body = Buffer.from(`<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${text} · Rekord</title><link rel="stylesheet" href="${publicPath}/assets/player.css"></head><body><main class="gone"><p class="brand">rekord</p><h1>${text}</h1><p>Bitte frag nach einem neuen Link.</p></main></body></html>`);
          res.writeHead(error.status,{ ...headers,'Content-Type':'text/html; charset=utf-8','Content-Length':body.length }); return res.end(req.method === 'HEAD' ? undefined : body);
        }
        const body = Buffer.from(`<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${html(item.title)} · Rekord</title><link rel="stylesheet" href="${publicPath}/assets/player.css"><script defer src="${publicPath}/assets/player.js"></script></head><body><header><a class="brand" href="#" aria-label="Rekord"><span>Rekord</span></a><span class="private">Nur über diesen Link erreichbar</span></header><main><div class="eyebrow">GETEILTE AUFNAHME</div><h1>${html(item.title)}</h1><div class="player"><video controls playsinline preload="metadata" src="${publicPath}/media/${item.id}"></video></div><div class="details"><span>${html(new Date(item.createdAt).toLocaleDateString('de-DE',{day:'numeric',month:'long',year:'numeric'}))} · ${(item.bytes/1024**2).toFixed(1)} MB</span><button id="copy">Link kopieren</button></div><p id="feedback" role="status"></p></main><footer>Aufgenommen mit Rekord</footer></body></html>`);
        res.writeHead(200,{ ...headers,'Content-Type':'text/html; charset=utf-8','Content-Length':body.length }); return res.end(req.method === 'HEAD' ? undefined : body);
      }
      const media = /^\/(media|om)\/([A-Za-z0-9_-]{32})$/.exec(url.pathname);
      if ((req.method === 'GET' || req.method === 'HEAD') && media) {
        const id = media[1] === 'om' ? (await offers.media(media[2])).videoId : media[2];
        const item = await metadata(id); const file = path.join(root,`${item.id}.mp4`);
        let range;
        try { range = rangeFor(req.headers.range,item.bytes); } catch (error) { res.setHeader('Content-Range',`bytes */${item.bytes}`); throw error; }
        res.writeHead(range.partial ? 206 : 200,{ ...headers,'Content-Type':'video/mp4','Accept-Ranges':'bytes','Content-Length':range.end-range.start+1,...(range.partial ? { 'Content-Range':`bytes ${range.start}-${range.end}/${item.bytes}` } : {}) });
        if (req.method === 'HEAD') return res.end();
        await pipeline(createReadStream(file,{ start:range.start,end:range.end }),res); return;
      }
      if (req.method === 'GET' && ['/assets/player.css','/assets/player.js','/assets/tracking.js','/assets/guide.css'].includes(url.pathname)) {
        const file = await readFile(path.join(assets,path.basename(url.pathname)));
        res.writeHead(200,{ ...headers,'Content-Type':url.pathname.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/javascript; charset=utf-8','Content-Length':file.length }); return res.end(file);
      }
      throw new RequestError(404,'Nicht gefunden.');
    } catch (error) {
      req.resume();
      if (res.headersSent || res.destroyed) { res.destroy(); return; }
      json(res,error.status || 500,{ error:error.status ? error.message : 'Der Share-Dienst konnte die Anfrage nicht abschließen.' });
    }
  });
  server.requestTimeout = 30*60*1000; server.headersTimeout = 15000; server.keepAliveTimeout = 5000;
  server.once('close',() => { clearInterval(sweeper); clearInterval(offerSweeper); });
  return server;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const server = await createShareServer({ storageDirectory:process.env.STORAGE_DIR || './storage',uploadToken:process.env.UPLOAD_TOKEN,publicBaseURL:process.env.PUBLIC_BASE_URL,maxUploadBytes:Number(process.env.MAX_UPLOAD_BYTES) || undefined,maxStorageBytes:Number(process.env.MAX_STORAGE_BYTES) || undefined,ctaURL:process.env.CTA_URL || undefined,offersEnabled:process.env.OFFERS_ENABLED !== 'false',privacyURL:process.env.PRIVACY_URL || '',operatorName:process.env.OPERATOR_NAME || '',offerOptions:{ analyticsOptions:{ maxSessions:Number(process.env.MAX_ANALYTICS_SESSIONS) || 10000,maxBytes:Number(process.env.MAX_ANALYTICS_BYTES) || 64*1024**2,retentionDays:Number(process.env.ANALYTICS_RETENTION_DAYS) || 90 } } });
  server.listen(Number(process.env.PORT) || 7341,process.env.HOST || '127.0.0.1',() => console.log(`Rekord share service listening on port ${server.address().port}`));
  for (const signal of ['SIGTERM','SIGINT']) process.on(signal,() => server.close(() => process.exit(0)));
}
