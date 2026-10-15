import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomBytes, createHash } from 'node:crypto';
import { createShareServer } from '../server.mjs';
const token = randomBytes(32).toString('hex');
// Smallest structurally valid MP4: ftyp, moov (mvhd with 1 s duration, one video track) and mdat.
const box = (type,...parts) => { const payload = Buffer.concat(parts); const header = Buffer.alloc(8); header.writeUInt32BE(payload.length+8,0); header.write(type,4,'latin1'); return Buffer.concat([header,payload]); };
function mvhd() { const b = Buffer.alloc(100); b.writeUInt32BE(1000,12); b.writeUInt32BE(1000,16); return box('mvhd',b); }
function hdlr(kind) { const b = Buffer.alloc(24); b.write(kind,8,'latin1'); return box('hdlr',b); }
const makeMovie = (payload = randomBytes(4000),kind = 'vide') => Buffer.concat([box('ftyp',Buffer.from('isom\0\0\0\0isomiso2')),box('moov',mvhd(),box('trak',box('mdia',hdlr(kind)))),box('mdat',payload)]);
const movie = makeMovie();
async function fixture(options = {}) {
  const directory = await mkdtemp(path.join(tmpdir(),'focus-share-'));
  const server = await createShareServer({ storageDirectory:directory,uploadToken:token,...options });
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  return { directory,server,base:`http://127.0.0.1:${server.address().port}`,async close() { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory,{ recursive:true,force:true }); } };
}
async function upload(f,body = movie,extra = {}) {
  return fetch(`${f.base}/api/videos`,{ method:'POST',headers:{ authorization:`Bearer ${token}`,'content-type':'video/mp4',...extra },body });
}
test('authenticated upload → escaped player → seekable bytes → revoke',async () => {
  const f = await fixture();
  try {
    const response = await upload(f,movie,{ 'x-focus-title':Buffer.from('<script>alert("x")</script> Aufnahme').toString('base64url') });
    assert.equal(response.status,201); const result = await response.json();
    assert.match(result.id,/^[A-Za-z0-9_-]{32}$/); assert.equal(result.bytes,movie.length);
    assert.equal(result.sha256,createHash('sha256').update(movie).digest('hex'));
    assert.equal(result.url,`${f.base}/v/${result.id}`);
    assert.equal((await fetch(`${f.base}/api/videos`)).status,401);
    const listing = await fetch(`${f.base}/api/videos`,{ headers:{ authorization:`Bearer ${token}` } });
    assert.equal((await listing.json()).videos[0].id,result.id);
    const page = await fetch(result.url), content = await page.text();
    assert.equal(page.status,200); assert.match(content,/&lt;script&gt;/); assert.doesNotMatch(content,/<script>alert/);
    assert.match(content,/<video controls playsinline/); assert.equal(page.headers.get('referrer-policy'),'no-referrer');
    assert.match(page.headers.get('content-security-policy'),/frame-ancestors 'none'/);
    const video = `${f.base}/media/${result.id}`;
    const full = await fetch(video); assert.deepEqual(Buffer.from(await full.arrayBuffer()),movie);
    const partial = await fetch(video,{ headers:{ range:'bytes=9-34' } });
    assert.equal(partial.status,206); assert.equal(partial.headers.get('content-range'),`bytes 9-34/${movie.length}`);
    assert.deepEqual(Buffer.from(await partial.arrayBuffer()),movie.subarray(9,35));
    const suffix = await fetch(video,{ headers:{ range:'bytes=-10' } }); assert.deepEqual(Buffer.from(await suffix.arrayBuffer()),movie.subarray(-10));
    const head = await fetch(video,{ method:'HEAD' }); assert.equal(head.headers.get('content-length'),String(movie.length)); assert.equal((await head.arrayBuffer()).byteLength,0);
    const invalid = await fetch(video,{ headers:{ range:'bytes=999999-' } }); assert.equal(invalid.status,416); assert.equal(invalid.headers.get('content-range'),`bytes */${movie.length}`);
    assert.equal((await fetch(`${f.base}/api/videos/${result.id}`,{ method:'DELETE' })).status,401);
    assert.equal((await fetch(`${f.base}/api/videos/${result.id}`,{ method:'DELETE',headers:{ authorization:`Bearer ${token}` } })).status,204);
    assert.equal((await fetch(result.url)).status,404); assert.equal((await fetch(video)).status,404);
    assert.ok((await readdir(path.join(f.directory,'revoked'))).includes(`${result.id}.mp4`));
  } finally { await f.close(); }
});
test('rejects unauthenticated, wrong MIME, invalid MP4, oversize and exhausted quota',async () => {
  const f = await fixture({ maxUploadBytes:5000,maxStorageBytes:movie.length+10 });
  try {
    assert.equal((await fetch(`${f.base}/api/videos`,{ method:'POST',body:movie })).status,401);
    assert.equal((await upload(f,movie,{ 'content-type':'text/html' })).status,415);
    assert.equal((await upload(f,Buffer.from('this is not MP4'))).status,415);
    assert.equal((await upload(f,Buffer.alloc(5001))).status,413);
    assert.equal((await upload(f)).status,201); assert.equal((await upload(f)).status,507);
    assert.equal((await fetch(`${f.base}/api/status`)).status,401);
    const status = await fetch(`${f.base}/api/status`,{ headers:{ authorization:`Bearer ${token}` } }); assert.equal((await status.json()).availableBytes,10);
    assert.ok(!(await readdir(f.directory)).some(file => file.endsWith('.part')));
  } finally { await f.close(); }
});
test('no index or traversal; invalid IDs and ranges cannot expose storage',async () => {
  const f = await fixture();
  try {
    for (const route of ['/','/metadata','/storage','/media/../../server.mjs','/v/no','/assets/../server.mjs','/api/videos/invalid']) assert.equal((await fetch(f.base+route)).status,404);
    const uploaded = await (await upload(f)).json();
    for (const range of ['bytes=2-1','bytes=-0','bytes=0-1,3-4','bytes=99999999999999999999999999999999-','something']) assert.equal((await fetch(`${f.base}/media/${uploaded.id}`,{ headers:{ range } })).status,416);
  } finally { await f.close(); }
});
test('validates configuration and advertised public origin',async () => {
  await assert.rejects(createShareServer({ storageDirectory:'/tmp/focus-unused',uploadToken:'short' }));
  await assert.rejects(createShareServer({ storageDirectory:'/tmp/focus-unused',uploadToken:token,publicBaseURL:'http://example.com' }));
  const f = await fixture({ publicBaseURL:'https://share.example.com/' });
  try { assert.match((await (await upload(f)).json()).url,/^https:\/\/share\.example\.com\/v\//); } finally { await f.close(); }
});

test('idempotent retry returns same capability and checksum mismatch is rejected',async () => {
  const f = await fixture({ maxStorageBytes:movie.length });
  try {
    const hash = createHash('sha256').update(movie).digest('hex');
    assert.equal((await upload(f,movie,{ 'x-focus-sha256':'0'.repeat(64) })).status,400);
    const first = await (await upload(f,movie,{ 'x-focus-sha256':hash })).json();
    const second = await (await upload(f,movie,{ 'x-focus-sha256':hash })).json();
    assert.equal(first.id,second.id); assert.equal(first.url,second.url);
    assert.equal((await readdir(f.directory)).filter(x => x.endsWith('.mp4')).length,1);
  } finally { await f.close(); }
});

test('interrupted upload releases quota and removes partial media',async () => {
  const { request } = await import('node:http');
  const f = await fixture({ maxStorageBytes:10000 });
  try {
    await new Promise(resolve => {
      const req = request(`${f.base}/api/videos`,{ method:'POST',headers:{ authorization:`Bearer ${token}`,'content-type':'video/mp4','content-length':'9000' } });
      req.on('error',resolve); req.flushHeaders(); req.write(movie.subarray(0,100)); setTimeout(() => req.destroy(),30);
    });
    const deadline = Date.now()+2000;
    while (Date.now() < deadline) {
      const result = await fetch(`${f.base}/api/status`,{ headers:{ authorization:`Bearer ${token}` } });
      if ((await result.json()).availableBytes === 10000) break;
      await new Promise(resolve => setTimeout(resolve,20));
    }
    assert.ok(!(await readdir(f.directory)).some(file => file.endsWith('.part')));
    assert.equal((await upload(f)).status,201);
  } finally { await f.close(); }
});

test('restart retains links, revocation, retry identity and on-disk quota after interrupted publication',async () => {
  const directory = await mkdtemp(path.join(tmpdir(),'focus-share-restart-'));
  let server;
  async function start() {
    server = await createShareServer({ storageDirectory:directory,uploadToken:token,maxStorageBytes:movie.length*2+100 });
    await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
    return { base:`http://127.0.0.1:${server.address().port}` };
  }
  async function stop() { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  try {
    let f = await start();
    const revoked = await (await upload(f)).json();
    assert.equal((await fetch(`${f.base}/api/videos/${revoked.id}`,{ method:'DELETE',headers:{ authorization:`Bearer ${token}` } })).status,204);
    const hash = createHash('sha256').update(movie).digest('hex');
    const active = await (await upload(f,movie,{ 'x-focus-sha256':hash })).json();
    await stop();
    const orphan = 'o'.repeat(32), partial = 'p'.repeat(32);
    await writeFile(path.join(directory,`${orphan}.mp4`),Buffer.alloc(13));
    await writeFile(path.join(directory,`${partial}.part`),Buffer.alloc(7));
    f = await start();
    const auth = { headers:{ authorization:`Bearer ${token}` } };
    assert.equal((await (await fetch(`${f.base}/api/status`,auth)).json()).availableBytes,87);
    const listing = (await (await fetch(`${f.base}/api/videos`,auth)).json()).videos;
    assert.deepEqual(listing.map(item => item.id),[active.id]);
    assert.equal((await fetch(`${f.base}/v/${active.id}`)).status,200);
    assert.equal((await fetch(`${f.base}/v/${revoked.id}`)).status,404);
    assert.equal((await fetch(`${f.base}/media/${orphan}`)).status,404);
    const retry = await (await upload(f,movie,{ 'x-focus-sha256':hash })).json();
    assert.equal(retry.id,active.id);
    assert.ok(!(await readdir(directory)).includes(`${partial}.part`));
  } finally { if (server.listening) await stop(); await rm(directory,{ recursive:true,force:true }); }
});


test('mounted HTTPS base path keeps API, player assets and media within its namespace',async () => {
  const f = await fixture({ publicBaseURL:'https://os.example.com/focus-share/' });
  try {
    assert.equal((await fetch(f.base+'/api/status',{ headers:{ authorization:`Bearer ${token}` } })).status,404);
    f.base += '/focus-share';
    const uploaded = await (await upload(f)).json();
    assert.equal(uploaded.url,`https://os.example.com/focus-share/v/${uploaded.id}`);
    const page = await (await fetch(`${f.base}/v/${uploaded.id}`)).text();
    assert.match(page,/href="\/focus-share\/assets\/player.css"/);
    assert.match(page,/src="\/focus-share\/assets\/player.js"/);
    assert.ok(page.includes(`src="/focus-share/media/${uploaded.id}"`));
    for (const asset of ['/assets/player.css','/assets/player.js']) assert.equal((await fetch(f.base+asset)).status,200);
    assert.equal((await fetch(`${f.base}/media/${uploaded.id}`,{ headers:{range:'bytes=0-11'} })).status,206);
    const listing = await (await fetch(f.base+'/api/videos',{ headers:{authorization:`Bearer ${token}`} })).json();
    assert.equal(listing.videos[0].url,uploaded.url);
    assert.equal((await fetch(`${f.base}/api/videos/${uploaded.id}`,{method:'DELETE',headers:{authorization:`Bearer ${token}`}})).status,204);
    assert.equal((await fetch(`${f.base}/v/${uploaded.id}`)).status,404);
  } finally { await f.close(); }
});

test('rejects MP4 headers without a playable video: no link, no quota (review F12)',async () => {
  const f = await fixture();
  try {
    const before = (await (await fetch(`${f.base}/api/status`,{ headers:{ authorization:`Bearer ${token}` } })).json()).availableBytes;
    const tiny = Buffer.concat([Buffer.from([0,0,0,12]),Buffer.from('ftypisom')]);
    const noMovie = Buffer.concat([box('ftyp',Buffer.from('isom\0\0\0\0')),box('mdat',randomBytes(500))]);
    for (const body of [tiny,noMovie,makeMovie(randomBytes(300),'soun')]) assert.equal((await upload(f,body)).status,415);
    const status = await (await fetch(`${f.base}/api/status`,{ headers:{ authorization:`Bearer ${token}` } })).json();
    assert.equal(status.availableBytes,before);
    assert.equal((await (await fetch(`${f.base}/api/videos`,{ headers:{ authorization:`Bearer ${token}` } })).json()).videos.length,0);
    assert.deepEqual((await readdir(f.directory)).filter(name => name.endsWith('.mp4') || name.endsWith('.part')),[]);
  } finally { await f.close(); }
});
test('one damaged metadata file is quarantined; the server starts and other links keep working (review F11)',async () => {
  const directory = await mkdtemp(path.join(tmpdir(),'rekord-share-'));
  try {
    let server = await createShareServer({ storageDirectory:directory,uploadToken:token });
    await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    const good = await (await fetch(`${base}/api/videos`,{ method:'POST',headers:{ authorization:`Bearer ${token}`,'content-type':'video/mp4' },body:makeMovie() })).json();
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    const broken = 'A'.repeat(32);
    await writeFile(path.join(directory,'metadata',`${broken}.json`),'{"id": "' + broken + '", broken');
    server = await createShareServer({ storageDirectory:directory,uploadToken:token });
    await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
    const again = `http://127.0.0.1:${server.address().port}`;
    try {
      assert.equal((await fetch(`${again}/v/${good.id}`)).status,200);
      assert.equal((await fetch(`${again}/v/${broken}`)).status,404);
      assert.equal((await (await fetch(`${again}/api/status`,{ headers:{ authorization:`Bearer ${token}` } })).json()).problems,1);
      assert.deepEqual(await readdir(path.join(directory,'quarantine')),[`${broken}.json`]);
      const page = await (await fetch(`${again}/v/${good.id}`)).text();
      assert.match(page,/Aufgenommen mit Rekord/); assert.doesNotMatch(page,/Focus Recorder/);
    } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  } finally { await rm(directory,{ recursive:true,force:true }); }
});
test('guide upload → mobile page with escaped steps, images, brief, CTA → revoke',async () => {
  const f = await fixture({ ctaURL:'https://example.com/check' });
  try {
    const video = await (await upload(f)).json();
    const jpeg = Buffer.concat([Buffer.from([0xff,0xd8,0xff,0xe0]),randomBytes(300)]);
    const guide = { title:'Rechnung <anlegen>',summary:'So geht es.',apps:['Safari'],cta:true,
      steps:[{ text:'Klicke auf „Neue Rechnung“.',note:'Tipp <b>',image:jpeg.toString('base64') },{ text:'Fülle das Feld „Kunde“ aus.' }],
      brief:{ summary:'Zwei Schritte lassen sich automatisieren.',saving:'Spart etwa 3 Stunden pro Monat.',groups:[{ title:'Rechnung anlegen',automatable:'ja',method:'api',steps:[1,2] }] } };
    const post = body => fetch(`${f.base}/api/guides`,{ method:'POST',headers:{ authorization:`Bearer ${token}`,'content-type':'application/json' },body:JSON.stringify(body) });
    assert.equal((await fetch(`${f.base}/api/guides`,{ method:'POST',headers:{ 'content-type':'application/json' },body:'{}' })).status,401);
    assert.equal((await post({ ...guide,steps:[{ text:'x',image:Buffer.from('nojpeg').toString('base64') }] })).status,415);
    assert.equal((await post({ ...guide,steps:[] })).status,400);
    assert.equal((await post({ ...guide,videoId:'A'.repeat(32) })).status,409);
    const response = await post(guide); assert.equal(response.status,201);
    const result = await response.json(); assert.equal(result.url,`${f.base}/g/${result.id}`);
    const page = await (await fetch(result.url)).text();
    assert.match(page,/Rechnung &lt;anlegen&gt;/); assert.match(page,/Tipp &lt;b&gt;/); assert.doesNotMatch(page,/<anlegen>/);
    assert.match(page,/width=device-width/); assert.match(page,new RegExp(`/gi/${result.id}/1.jpg`)); assert.doesNotMatch(page,/\/2\.jpg/);
    assert.match(page,/Was sich davon automatisieren lässt/); assert.match(page,/Spart etwa 3 Stunden/); assert.match(page,/href="https:\/\/example.com\/check"/);
    assert.doesNotMatch(page,/<video|\/media\//);
    const image = await fetch(`${f.base}/gi/${result.id}/1.jpg`); assert.equal(image.headers.get('content-type'),'image/jpeg'); assert.deepEqual(Buffer.from(await image.arrayBuffer()),jpeg);
    assert.equal((await fetch(`${f.base}/gi/${result.id}/2.jpg`)).status,404);
    assert.equal((await fetch(`${f.base}/assets/guide.css`)).status,200);
    const quiet = await (await post({ ...guide,cta:false })).json();
    assert.doesNotMatch(await (await fetch(quiet.url)).text(),/automatisieren lassen/);
    const listing = await (await fetch(`${f.base}/api/guides`,{ headers:{ authorization:`Bearer ${token}` } })).json(); assert.equal(listing.guides.length,2);
    assert.equal((await fetch(`${f.base}/api/guides/${result.id}`,{ method:'DELETE',headers:{ authorization:`Bearer ${token}` } })).status,204);
    assert.equal((await fetch(result.url)).status,404); assert.equal((await fetch(`${f.base}/gi/${result.id}/1.jpg`)).status,404);
    // Restart keeps the remaining guide.
    f.server.closeAllConnections(); await new Promise(resolve => f.server.close(resolve));
    const again = await createShareServer({ storageDirectory:f.directory,uploadToken:token }); await new Promise(resolve => again.listen(0,'127.0.0.1',resolve));
    assert.equal((await fetch(`http://127.0.0.1:${again.address().port}/g/${quiet.id}`)).status,200);
    again.closeAllConnections(); await new Promise(resolve => again.close(resolve)); f.server = { closeAllConnections() {}, close(cb) { cb(); } };
  } finally { await f.close(); }
});
test('expiring links: set on upload, kept forever via PATCH, expired links free their storage and show a friendly page',async () => {
  const f = await fixture();
  const auth = { authorization:`Bearer ${token}` };
  const status = async () => (await (await fetch(`${f.base}/api/status`,{ headers:auth })).json());
  try {
    assert.ok((await status()).features.includes('expiry'));
    assert.ok((await status()).features.includes('guide-lifecycle-v2'));
    assert.equal((await upload(f,makeMovie(),{ 'x-focus-expires-days':'0' })).status,400);
    assert.equal((await upload(f,makeMovie(),{ 'x-focus-expires-days':'abc' })).status,400);
    const free = (await status()).availableBytes;
    const keep = await (await upload(f,makeMovie(),{ 'x-focus-expires-days':'90' })).json();
    const days = (Date.parse(keep.expiresAt)-Date.now())/86400000;
    assert.ok(days > 89.9 && days <= 90,'expiry is 90 days ahead');
    // Keep forever.
    let patched = await fetch(`${f.base}/api/videos/${keep.id}`,{ method:'PATCH',headers:{ ...auth,'content-type':'application/json' },body:JSON.stringify({ expiresAt:null }) });
    assert.equal(patched.status,200); assert.equal((await patched.json()).expiresAt,undefined);
    assert.equal((await fetch(`${f.base}/api/videos/${keep.id}`,{ method:'PATCH',headers:auth,body:JSON.stringify({ expiresAt:'2001-01-01T00:00:00Z' }) })).status,400);
    assert.equal((await fetch(`${f.base}/api/videos/${keep.id}`,{ method:'PATCH',body:JSON.stringify({ expiresAt:null }) })).status,401);
    // A link that runs out while the server is running.
    const short = await (await upload(f,makeMovie(),{ 'x-focus-expires-days':'1' })).json();
    patched = await fetch(`${f.base}/api/videos/${short.id}`,{ method:'PATCH',headers:auth,body:JSON.stringify({ expiresAt:new Date(Date.now()+400).toISOString() }) });
    assert.equal(patched.status,200);
    assert.equal((await fetch(short.url)).status,200);
    await new Promise(resolve => setTimeout(resolve,600));
    const gone = await fetch(short.url);
    assert.equal(gone.status,410); assert.match(await gone.text(),/Dieser Link ist abgelaufen/);
    assert.equal((await fetch(`${f.base}/media/${short.id}`)).status,404);
    assert.ok(!(await readdir(f.directory)).includes(`${short.id}.mp4`),'expired media deleted');
    assert.equal((await status()).availableBytes,free-keep.bytes,'storage of the expired link is free again');
    const page = await fetch(`${f.base}/v/${'B'.repeat(32)}`);
    assert.equal(page.status,404); assert.match(page.headers.get('content-type'),/text\/html/);
    assert.equal((await fetch(keep.url)).status,200,'kept link still works');
  } finally { await f.close(); }
});
test('links that expired while the server was down are removed at start',async () => {
  const directory = await mkdtemp(path.join(tmpdir(),'rekord-share-'));
  try {
    let server = await createShareServer({ storageDirectory:directory,uploadToken:token });
    await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
    let base = `http://127.0.0.1:${server.address().port}`;
    const item = await (await fetch(`${base}/api/videos`,{ method:'POST',headers:{ authorization:`Bearer ${token}`,'content-type':'video/mp4','x-focus-expires-days':'30' },body:makeMovie() })).json();
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    const file = path.join(directory,'metadata',`${item.id}.json`);
    const stored = JSON.parse(await (await import('node:fs/promises')).readFile(file,'utf8')); stored.expiresAt = '2020-01-01T00:00:00.000Z';
    await writeFile(file,JSON.stringify(stored));
    server = await createShareServer({ storageDirectory:directory,uploadToken:token });
    await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
    base = `http://127.0.0.1:${server.address().port}`;
    try {
      assert.equal((await fetch(`${base}/v/${item.id}`)).status,404);
      assert.ok(!(await readdir(directory)).includes(`${item.id}.mp4`));
      assert.ok(!(await readdir(path.join(directory,'metadata'))).includes(`${item.id}.json`));
    } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  } finally { await rm(directory,{ recursive:true,force:true }); }
});
