// No external services, cookies or device identity. Automatic sessions live only in memory.
export function unionRanges(ranges) {
  const out = [];
  for (const r of ranges.map(r => [...r]).sort((a,b) => a[0]-b[0])) {
    const last = out.at(-1);
    if (last && r[0] <= last[1]+0.001) last[1] = Math.max(last[1],r[1]); else out.push(r);
  }
  return out;
}
export class PlaybackMeter {
  constructor(ranges = []) { this.ranges = ranges; this.previous = null; this.lastPosition = 0; }
  resetPosition() { this.previous = null; }
  observe({ position,wall,playing,seeking,rate = 1,played = [] }) {
    const previous = this.previous;
    if (!seeking && previous) {
      const delta = position-previous.position, elapsed = (wall-previous.wall)/1000;
      // Seek events reset the anchor; this also rejects discontinuities if a browser misses an event.
      if (delta > 0 && delta <= elapsed*Math.max(rate,previous.rate)+0.5) {
        const additions = played.map(([a,b]) => [Math.max(a,previous.position),Math.min(b,position)]).filter(([a,b]) => b > a);
        this.ranges = unionRanges([...this.ranges,...additions]);
        if (additions.length) this.lastPosition = additions.at(-1)[1];
      }
    }
    this.previous = playing && !seeking ? { position,wall,rate } : null;
  }
}
export function attachTracking(doc = document,win = window) {
  const root = doc.querySelector('[data-offer-api]'), video = doc.querySelector('video');
  if (!root || !video) return;
  const automatic = root.dataset.trackingMode === 'automatic';
  const api = root.dataset.offerApi, storageKey = `rekord.offer:${api}`;
  const choice = doc.querySelector('#tracking-choice'), allow = doc.querySelector('#allow-tracking'), deny = doc.querySelector('#deny-tracking'), withdraw = doc.querySelector('#withdraw-tracking'), status = doc.querySelector('#tracking-status');
  let session = null, meter = new PlaybackMeter(), sequence = 0, clicks = 0, busy = false, cancelled = false;
  const readSaved = () => { try { return JSON.parse(win.sessionStorage.getItem(storageKey)); } catch { return null; } };
  const forget = () => { try { win.sessionStorage.removeItem(storageKey); } catch {} };
  const remember = () => { if (session && !automatic) { try { win.sessionStorage.setItem(storageKey,JSON.stringify({ session,sequence,clicks,ranges:meter.ranges,lastPosition:meter.lastPosition })); } catch {} } };
  async function request(path,body,method = 'POST') {
    const response = await win.fetch(api+path,{ method,headers:{ 'Content-Type':'application/json' },body:JSON.stringify(body),credentials:'omit',cache:'no-store',keepalive:true });
    if (!response.ok) { const error = new Error('Statistik konnte nicht synchronisiert werden.'); error.status = response.status; throw error; }
    return response.status === 204 ? null : response.json();
  }
  function sample() {
    if (!session) return;
    const played = [];
    for (let i=0;i<video.played.length;i++) played.push([video.played.start(i),video.played.end(i)]);
    meter.observe({ position:video.currentTime,wall:win.performance.now(),playing:!video.paused && !video.ended,seeking:video.seeking,rate:video.playbackRate,played });
    remember();
  }
  function pauseMeasurement(message) {
    session = null; meter.resetPosition(); forget(); if (choice) choice.hidden = false; withdraw.hidden = true; status.textContent = message;
  }
  async function flush(beacon = false) {
    if (!session) return;
    sample();
    if (meter.ranges.length > 256) { pauseMeasurement('Zu viele einzelne Wiedergabebereiche. Das Video bleibt nutzbar.'); return; }
    const body = { sessionId:session.id,sessionKey:session.sessionKey,sequence:++sequence,playedRanges:meter.ranges,lastPosition:meter.lastPosition,ctaClickCount:clicks };
    remember();
    if (beacon && !automatic && win.navigator.sendBeacon?.(api+'/events',new Blob([JSON.stringify(body)],{ type:'application/json' }))) return;
    try { await request('/events',body); if (session?.id !== body.sessionId || stopped) return; status.textContent = 'Wiedergabe-Statistik ist aktiv. Du kannst sie jederzeit ausschalten.'; }
    catch (error) {
      if (session?.id !== body.sessionId || stopped) return;
      if ([403,404,410].includes(error.status)) pauseMeasurement(automatic ? 'Messung beendet. Video und Terminbutton bleiben nutzbar.' : 'Messung beendet. Du kannst sie bei Bedarf erneut erlauben.');
      else status.textContent = error.status === 503 ? 'Messlimit erreicht. Video und Terminbutton bleiben nutzbar.' : 'Statistik gerade nicht synchronisiert. Video und Terminbutton bleiben nutzbar.';
    }
  }
  async function start(saved = null) {
    if (busy || doc.visibilityState !== 'visible') return;
    busy = true; cancelled = false; stopped = false; if (allow) allow.disabled = true;
    try {
      const answer = await request('/sessions',{ ...(automatic ? { measurementMode:'automatic-v1' } : { consent:'playback-v1' }),...(saved?.session ? { sessionId:saved.session.id,sessionKey:saved.session.sessionKey } : {}) });
      if (cancelled) { session = answer; await stopMeasurement(); return; }
      session = answer;
      meter = new PlaybackMeter(unionRanges([...(answer.playedRanges ?? []),...(saved?.ranges ?? [])]));
      sequence = Math.max(answer.lastSequence,saved?.sequence ?? 0); clicks = Math.max(answer.ctaClickCount,saved?.clicks ?? 0); meter.lastPosition = saved?.lastPosition ?? answer.lastPosition;
      sample(); remember(); if (choice) choice.hidden = true; withdraw.hidden = false; status.textContent = 'Wiedergabe-Statistik ist aktiv. Du kannst sie jederzeit ausschalten.';
    } catch (error) {
      if (!automatic) forget(); status.textContent = 'Statistik gerade nicht verfügbar. Du kannst das Video ohne Statistik ansehen.';
    } finally { busy = false; if (allow) allow.disabled = false; }
  }
  allow?.addEventListener('click',() => start());
  deny?.addEventListener('click',() => { cancelled = true; if (choice) choice.hidden = true; status.textContent = 'Du siehst das Video ohne Wiedergabe-Statistik.'; });
  async function stopMeasurement() {
    cancelled = true; stopped = true;
    // A preference is stored only when the visitor asks to stop, never an automatic session identifier.
    if (automatic) { try { win.sessionStorage.setItem(storageKey,JSON.stringify({ disabled:true })); } catch {} }
    if (!session) { withdraw.hidden = true; status.textContent = 'Statistik ist ausgeschaltet.'; return; }
    const old = session; session = null; meter.resetPosition(); if (!automatic) forget(); withdraw.disabled = true;
    try { await request(`/sessions/${old.id}`,{ sessionKey:old.sessionKey },'DELETE'); withdraw.hidden = true; status.textContent = 'Statistik widerrufen und diese Session gelöscht.'; }
    catch { session = old; status.textContent = 'Löschen noch nicht bestätigt. Bitte erneut widerrufen. Es werden keine weiteren Messwerte gesendet.'; stopped = true; }
    finally { withdraw.disabled = false; }
  }
  withdraw.addEventListener('click',stopMeasurement);
  let stopped = false;
  for (const name of ['playing','timeupdate','ratechange']) video.addEventListener(name,() => { if (!stopped) sample(); });
  video.addEventListener('seeking',() => meter.resetPosition());
  video.addEventListener('seeked',() => { meter.resetPosition(); if (!stopped) sample(); });
  for (const name of ['pause','ended']) video.addEventListener(name,() => { if (!stopped) void flush(); });
  doc.querySelector('#book')?.addEventListener('click',() => { if (session && !stopped) { clicks++; void flush(true); } });
  doc.addEventListener('visibilitychange',() => { if (doc.visibilityState === 'hidden' && !stopped) void flush(true); });
  const timer = win.setInterval(() => { if (session && !stopped) void flush(); },10000);
  win.addEventListener('pagehide',() => { if (!stopped) void flush(true); });
  // Legacy opt-ins can resume within a tab. Automatic mode starts a fresh in-memory session per page load.
  const saved = readSaved();
  const optedOut = automatic && (saved?.disabled || win.navigator.globalPrivacyControl === true || win.navigator.doNotTrack === '1');
  if (optedOut) { stopped = true; withdraw.hidden = true; status.textContent = 'Statistik ist durch deine Datenschutzeinstellung ausgeschaltet.'; }
  if (!optedOut && (automatic || saved?.session)) {
    if (doc.visibilityState === 'visible') void start(automatic ? null : saved);
    else doc.addEventListener('visibilitychange',function resume() { if (doc.visibilityState === 'visible') { doc.removeEventListener('visibilitychange',resume); if (!cancelled) void start(automatic ? null : saved); } });
  }
  return () => win.clearInterval(timer);
}
if (typeof document !== 'undefined') attachTracking();
