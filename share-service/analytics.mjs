import { mkdir, readdir, readFile, rename, rm, stat } from 'node:fs/promises';
import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import path from 'node:path';

export const fail = (status,message) => { throw Object.assign(new Error(message),{ status }); };
export const newID = () => randomBytes(24).toString('base64url');
export const validID = value => typeof value === 'string' && /^[A-Za-z0-9_-]{32}$/.test(value);
const hash = value => createHash('sha256').update(value).digest('hex');
const stamp = time => new Date(time).toISOString();
export function mergeRanges(ranges,duration) {
  if (!Array.isArray(ranges) || ranges.length > 256) fail(400,'Ungültige Wiedergabebereiche.');
  const sorted = ranges.map(r => {
    if (!Array.isArray(r) || r.length !== 2 || !r.every(Number.isFinite) || r[0] < 0 || r[1] <= r[0] || r[1] > duration+0.05) fail(400,'Ungültiger Wiedergabebereich.');
    return [r[0],Math.min(duration,r[1])];
  }).sort((a,b) => a[0]-b[0]);
  const result = [];
  for (const r of sorted) { const last = result.at(-1); if (last && r[0] <= last[1]) last[1] = Math.max(last[1],r[1]); else result.push(r); }
  return result;
}
export const covered = ranges => ranges.reduce((sum,[a,b]) => sum+b-a,0);
export function pageOf(values,after = '',limit = 50) {
  if (typeof after !== 'string' || after.length > 512) fail(400,'Ungültiger Cursor.');
  const sorted = values.sort((a,b) => a.cursor < b.cursor ? -1 : a.cursor > b.cursor ? 1 : 0).filter(v => v.cursor > after);
  const page = sorted.slice(0,limit);
  return { entries:page,nextCursor:page.at(-1)?.cursor ?? after,hasMore:sorted.length > limit };
}
// All callers hold the offer store's mutation queue. The same queue protects quotas, revoke and reset.
export async function createAnalytics({ directory,write,now = Date.now,retentionDays = 90,maxSessions = 10000,maxBytes = 64*1024**2 }) {
  if (![retentionDays,maxSessions,maxBytes].every(n => Number.isSafeInteger(n) && n > 0) || retentionDays > 90 || maxSessions > 10000 || maxBytes > 64*1024**2) throw Error('Analytics limits must be positive integers within the documented maximums.');
  await mkdir(directory,{ recursive:true,mode:0o700 });
  const records = new Map(), sizes = new Map(), damaged = new Set(), limited = new Set();
  const retention = retentionDays*86400000;
  const quarantine = path.join(directory,'quarantine');
  await mkdir(quarantine,{ recursive:true,mode:0o700 });
  for (const name of await readdir(quarantine)) if (/^[A-Za-z0-9_-]{32}\.json$/.test(name)) damaged.add(name.slice(0,-5));
  for (const file of await readdir(directory)) {
    if (!/^[A-Za-z0-9_-]{32}\.json$/.test(file)) continue;
    const id = file.slice(0,-5);
    try {
      const source = await readFile(path.join(directory,file),'utf8'), r = JSON.parse(source);
      if (r.version !== 1 || !validID(r.generation) || !Array.isArray(r.sessions) || r.sessions.length > maxSessions || typeof r.firstEmitted !== 'boolean') throw Error('schema');
      for (const s of r.sessions) {
        if (!validID(s.id) || !/^[a-f0-9]{64}$/.test(s.keyHash) || !Number.isFinite(Date.parse(s.openedAt)) || !Number.isFinite(Date.parse(s.lastActivityAt)) || !validID(s.trackingRevision) || s.consentVersion !== 'playback-v1' || !Number.isSafeInteger(s.lastSequence) || s.lastSequence < 0 || !Number.isSafeInteger(s.ctaClickCount) || s.ctaClickCount < 0 || s.ctaClickCount > 10000 || !Number.isFinite(s.lastPosition) || s.lastPosition < 0 || !Array.isArray(s.playedRanges) || s.playedRanges.length > 256 || !s.playedRanges.every(x => Array.isArray(x) && x.length === 2 && x.every(Number.isFinite) && x[0] >= 0 && x[1] > x[0])) throw Error('session');
      }
      if (r.firstEvent && (r.firstEvent.offerId !== id || !validID(r.firstEvent.sessionId) || r.firstEvent.id !== `${r.generation}.${id}` || !Number.isFinite(Date.parse(r.firstEvent.openedAt)) || typeof r.firstEvent.notifyEligible !== 'boolean')) throw Error('activity');
      records.set(id,r); sizes.set(id,Buffer.byteLength(source)); damaged.delete(id);
    } catch {
      damaged.add(id);
      // No link/session/payload in logs. Quarantine remains private and does not disable video playback.
      await mkdir(path.join(directory,'quarantine'),{ recursive:true,mode:0o700 });
      await rename(path.join(directory,file),path.join(directory,'quarantine',file)).catch(() => {});
      console.error('Rekord share: damaged analytics quarantined; reset statistics to resume.');
    }
  }
  let lastOpening = Math.max(0,...[...records.values()].flatMap(r => r.sessions.map(s => Date.parse(s.openedAt))));
  const fresh = () => ({ version:1,generation:newID(),firstEmitted:false,firstEvent:null,sessions:[] });
  const current = id => { if (damaged.has(id)) fail(503,'Statistik beschädigt. Bitte in Rekord zurücksetzen.'); return records.get(id) ?? fresh(); };
  async function save(id,r) {
    const data = JSON.stringify(r), bytes = Buffer.byteLength(data), before = records.get(id);
    const totalBytes = [...sizes.values()].reduce((a,b) => a+b,0)-(sizes.get(id) ?? 0)+bytes;
    const totalSessions = [...records.values()].reduce((a,b) => a+b.sessions.length,0)-(before?.sessions.length ?? 0)+r.sessions.length;
    if ((totalBytes > maxBytes && bytes > (sizes.get(id) ?? 0)) || (totalSessions > maxSessions && r.sessions.length > (before?.sessions.length ?? 0))) { limited.add(id); fail(503,'Messlimit erreicht. Wiedergabe bleibt verfügbar.'); }
    await write(path.join(directory,`${id}.json`),r); records.set(id,r); sizes.set(id,bytes); limited.delete(id);
  }
  function session(r,id,key,allowExpired = false) {
    const s = r.sessions.find(s => s.id === id);
    if (!s || typeof key !== 'string' || key.length !== 32 || !timingSafeEqual(Buffer.from(s.keyHash,'hex'),Buffer.from(hash(key),'hex'))) fail(403,'Mess-Session ungültig.');
    if (!allowExpired && now()-Date.parse(s.lastActivityAt) > 30*60000) fail(410,'Mess-Session abgelaufen.');
    return s;
  }
  const publicSession = (s,duration) => ({ id:s.id,openedAt:s.openedAt,lastActivityAt:s.lastActivityAt,playedRanges:s.playedRanges,playedSeconds:covered(s.playedRanges),percent:Math.min(100,100*covered(s.playedRanges)/duration),lastPosition:s.lastPosition,ctaClickCount:s.ctaClickCount,lastSequence:s.lastSequence });
  return {
    async start(offer,body) {
      let r = structuredClone(current(offer.id));
      if (body.consent !== 'playback-v1' || body.preview) fail(400,'Statistik braucht eine aktive Zustimmung.');
      if (body.sessionId || body.sessionKey) {
        const s = session(r,body.sessionId,body.sessionKey);
        if (s.trackingRevision !== offer.trackingRevision) fail(410,'Messung wurde zurückgesetzt.');
        return { ...publicSession(s,offer.durationSeconds),sessionKey:body.sessionKey };
      }
      const key = newID(), time = stamp(lastOpening = Math.max(now(),lastOpening+1));
      const s = { trackingRevision:offer.trackingRevision,id:newID(),keyHash:hash(key),openedAt:time,lastActivityAt:time,consentVersion:'playback-v1',lastSequence:0,playedRanges:[],lastPosition:0,ctaClickCount:0 };
      r.sessions.push(s);
      if (!r.firstEmitted) { r.firstEmitted = true; r.firstEvent = { id:`${r.generation}.${offer.id}`,offerId:offer.id,sessionId:s.id,openedAt:time,notifyEligible:offer.notifyOnFirstOpen }; }
      await save(offer.id,r);
      return { ...publicSession(s,offer.durationSeconds),sessionKey:key };
    },
    async event(offer,body) {
      const r = structuredClone(current(offer.id)), s = session(r,body.sessionId,body.sessionKey);
      if (s.trackingRevision !== offer.trackingRevision) fail(410,'Messung wurde zurückgesetzt.');
      if (!Number.isSafeInteger(body.sequence) || body.sequence < 1) fail(400,'Ungültige Sequenz.');
      if (body.sequence <= s.lastSequence) return;
      const ranges = mergeRanges(body.playedRanges,offer.durationSeconds);
      if (!Number.isSafeInteger(body.ctaClickCount) || body.ctaClickCount < s.ctaClickCount || body.ctaClickCount > 10000 || !Number.isFinite(body.lastPosition) || body.lastPosition < 0 || body.lastPosition > offer.durationSeconds+0.05) fail(400,'Ungültiger Messwert.');
      const all = mergeRanges([...s.playedRanges,...ranges].sort((a,b) => a[0]-b[0]).reduce((out,r) => { const last = out.at(-1); if (last && r[0] <= last[1]) last[1] = Math.max(last[1],r[1]); else out.push([...r]); return out; },[]),offer.durationSeconds);
      if (covered(all) > Math.max(0,(now()-Date.parse(s.openedAt))/1000)*16+2) fail(400,'Unplausible Wiedergabedauer.');
      Object.assign(s,{ playedRanges:all,lastPosition:Math.min(offer.durationSeconds,body.lastPosition),ctaClickCount:body.ctaClickCount,lastSequence:body.sequence,lastActivityAt:stamp(now()) });
      await save(offer.id,r);
    },
    async withdraw(id,sid,key) {
      const r = structuredClone(current(id)); session(r,sid,key,true);
      r.sessions = r.sessions.filter(s => s.id !== sid);
      if (r.firstEvent?.sessionId === sid) r.firstEvent = null;
      await save(id,r);
    },
    async reset(id) { await save(id,fresh()); damaged.delete(id); await rm(path.join(quarantine,`${id}.json`),{ force:true }); },
    async remove(id) { await rm(path.join(directory,`${id}.json`),{ force:true }); records.delete(id); sizes.delete(id); limited.delete(id); damaged.delete(id); await rm(path.join(directory,'quarantine',`${id}.json`),{ force:true }); },
    async sweep() {
      const cutoff = now()-retention;
      for (const name of await readdir(quarantine)) {
        const file = path.join(quarantine,name);
        if ((await stat(file)).mtimeMs <= cutoff) { await rm(file,{ force:true }); damaged.delete(name.slice(0,-5)); }
      }
      for (const [id,old] of records) {
        const r = structuredClone(old); r.sessions = r.sessions.filter(s => Date.parse(s.lastActivityAt) > cutoff);
        if (r.firstEvent && Date.parse(r.firstEvent.openedAt) <= cutoff) r.firstEvent = null;
        if (r.sessions.length !== old.sessions.length || (!r.firstEvent && old.firstEvent)) await save(id,r);
      }
    },
    summary(id,duration) {
      const sessions = records.get(id)?.sessions ?? [];
      const latest = [...sessions].sort((a,b) => b.lastActivityAt.localeCompare(a.lastActivityAt))[0];
      return { openings:sessions.length,started:sessions.filter(s => covered(s.playedRanges) > 0).length,bestPercent:Math.max(0,...sessions.map(s => 100*covered(s.playedRanges)/duration)),bestPlayedSeconds:Math.max(0,...sessions.map(s => covered(s.playedRanges))),ctaClickCount:sessions.reduce((n,s) => n+s.ctaClickCount,0),lastActivityAt:latest?.lastActivityAt ?? null,state:damaged.has(id) ? 'damaged' : limited.has(id) ? 'limited' : 'ready',retentionDays };
    },
    detail(id,duration,after) { return { summary:this.summary(id,duration),...pageOf((records.get(id)?.sessions ?? []).map(s => ({ ...publicSession(s,duration),cursor:`${s.openedAt}|${s.id}` })),after) }; },
    activities(offers,after) {
      const entries = [];
      for (const offer of offers) { const e = records.get(offer.id)?.firstEvent; if (e) entries.push({ ...e,title:offer.title,recipientLabel:offer.recipientLabel,notifyEligible:e.notifyEligible && offer.notifyOnFirstOpen,cursor:`${e.openedAt}|${e.id}` }); }
      return pageOf(entries,after);
    },
    health() { return { sessions:[...records.values()].reduce((n,r) => n+r.sessions.length,0),bytes:[...sizes.values()].reduce((a,b) => a+b,0),damaged:damaged.size,limited:limited.size }; }
  };
}
