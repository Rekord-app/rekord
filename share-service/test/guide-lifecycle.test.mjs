import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile, readFile, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createShareServer } from '../server.mjs';
import { request } from 'node:http';
const token = 'synthetic-test-token-'.repeat(3), auth = { authorization:`Bearer ${token}` };
const jpeg = Buffer.from([255,216,255,224,1,2,3,4]);
const body = (source = 'source-one',title = 'Reviewed guide') => ({ sourceGuideId:source,title,steps:[{ text:'Reviewed step',image:jpeg.toString('base64') }] });
async function fixture(t,options = {}) {
  const directory = await mkdtemp(path.join(tmpdir(),'rekord-lifecycle-')); let server, base;
  async function stop() { if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); server = null; } }
  async function start() { server = await createShareServer({ storageDirectory:directory,uploadToken:token,...options }); await new Promise(resolve => server.listen(0,'127.0.0.1',resolve)); base = `http://127.0.0.1:${server.address().port}`; }
  t.after(async () => { await stop(); await rm(directory,{ recursive:true,force:true }); }); await start();
  return { directory,start,stop,get base() { return base; },async get(route) { return fetch(base+route,{ headers:auth }); },async post(value) { return fetch(base+'/api/guides',{ method:'POST',headers:{ ...auth,'content-type':'application/json' },body:JSON.stringify(value) }); },async revoke(kind,id) { return fetch(`${base}/api/${kind}/${id}`,{ method:'DELETE',headers:auth }); } };
}
test('new guides never embed raw video; retry deduplicates; revoke includes all source revisions across restart',async t => {
  const f = await fixture(t);
  assert.equal((await f.post({ ...body(),videoId:'A'.repeat(32) })).status,409);
  const a = await (await f.post(body())).json(), retry = await (await f.post(body())).json();
  assert.equal(a.id,retry.id); assert.ok(a.bytes > jpeg.length);
  const b = await (await f.post(body('source-one','Edited'))).json(), other = await (await f.post(body('source-two'))).json();
  assert.notEqual(a.id,b.id); assert.doesNotMatch(await (await f.get(`/g/${a.id}`)).text(),/<video|\/media\//);
  const free = (await (await f.get('/api/status')).json()).availableBytes;
  assert.equal((await f.revoke('guides',a.id)).status,204);
  for (const id of [a.id,b.id]) for (const route of [`/g/${id}`,`/gi/${id}/1.jpg`]) assert.equal((await f.get(route)).status,404);
  assert.equal((await f.revoke('guides',a.id)).status,204);
  await f.stop(); await f.start();
  assert.equal((await f.get(`/g/${b.id}`)).status,404); assert.equal((await f.get(`/g/${other.id}`)).status,200);
  assert.equal((await (await f.get('/api/status')).json()).availableBytes,free,'retained guide files still consume quota');
});
for (const kind of ['guides','videos']) test(`legacy graph cascades from ${kind}, journal blocks stale files after crash`,async t => {
  const f = await fixture(t); await f.stop();
  const video = 'V'.repeat(32), g1 = 'A'.repeat(32), g2 = 'B'.repeat(32);
  await writeFile(path.join(f.directory,`${video}.mp4`),Buffer.alloc(500));
  await writeFile(path.join(f.directory,'metadata',`${video}.json`),JSON.stringify({ id:video,title:'Legacy raw video',bytes:500,sha256:'a'.repeat(64),createdAt:new Date().toISOString() }));
  for (const id of [g1,g2]) {
    await mkdir(path.join(f.directory,'guides',id)); await writeFile(path.join(f.directory,'guides',id,'1.jpg'),jpeg);
    await writeFile(path.join(f.directory,'guides',`${id}.json`),JSON.stringify({ id,title:'Legacy guide',videoId:video,apps:[],steps:[{ text:'step',image:true }],bytes:jpeg.length,createdAt:new Date().toISOString() }));
  }
  await f.start(); assert.equal((await f.get(`/g/${g1}`)).status,200);
  assert.equal((await f.revoke(kind,kind === 'guides' ? g1 : video)).status,204);
  for (const route of [`/g/${g1}`,`/g/${g2}`,`/gi/${g2}/1.jpg`,`/v/${video}`,`/media/${video}`]) assert.equal((await f.get(route)).status,404);
  await f.stop();
  // Simulate a crash after durable journal publication but before all retained data was moved.
  await cp(path.join(f.directory,'revoked','guides',`${g1}.json`),path.join(f.directory,'guides',`${g1}.json`));
  await cp(path.join(f.directory,'revoked','guides',g1),path.join(f.directory,'guides',g1),{ recursive:true });
  await f.start(); assert.equal((await f.get(`/g/${g1}`)).status,404);
});
test('corrupt metadata and missing images are quarantined, orphan and retained images count toward quota',async t => {
  const f = await fixture(t,{ maxStorageBytes:10000 });
  const good = await (await f.post(body())).json(); await f.stop();
  await writeFile(path.join(f.directory,'guides',`${'C'.repeat(32)}.json`),'{broken');
  await mkdir(path.join(f.directory,'guides','orphan')); await writeFile(path.join(f.directory,'guides','orphan','1.jpg'),Buffer.alloc(2000));
  await f.start(); const status = await (await f.get('/api/status')).json();
  assert.equal(status.problems,1); assert.equal(status.availableBytes,10000-good.bytes-2000-7); assert.equal((await f.get(`/g/${good.id}`)).status,200);
  await f.stop(); await rm(path.join(f.directory,'guides',good.id,'1.jpg')); await f.start();
  assert.equal((await f.get(`/g/${good.id}`)).status,404);
});
test('in-flight guides reserve slots and quota; interrupted uploads release both',async t => {
  const f = await fixture(t,{ maxConcurrentUploads:1,maxStorageBytes:5000 });
  const req = request(f.base+'/api/guides',{ method:'POST',headers:{ ...auth,'content-type':'application/json','content-length':'4000' } });
  req.on('error',() => {}); req.flushHeaders(); req.write('{');
  await new Promise(resolve => setTimeout(resolve,30));
  assert.equal((await (await f.get('/api/status')).json()).availableBytes,1000);
  assert.equal((await f.post(body())).status,429); req.destroy();
  await new Promise(resolve => setTimeout(resolve,30)); assert.equal((await f.post(body())).status,201);
});
test('revocation cancels an already in-flight revision; deliberate later publication remains possible',async t => {
  const f = await fixture(t);
  const first = await (await f.post(body())).json(), pending = JSON.stringify(body('source-one','Pending edit'));
  let finish;
  const response = new Promise(resolve => { finish = resolve; });
  const req = request(f.base+'/api/guides',{ method:'POST',headers:{ ...auth,'content-type':'application/json','content-length':Buffer.byteLength(pending) } },res => { res.resume(); finish(res.statusCode); });
  req.on('error',error => { throw error; }); req.write(pending.slice(0,-1));
  await new Promise(resolve => setTimeout(resolve,30));
  assert.equal((await f.revoke('guides',first.id)).status,204);
  req.end(pending.slice(-1)); assert.equal(await response,409);
  assert.equal((await (await f.get('/api/guides')).json()).guides.length,0);
  assert.equal((await f.post(body())).status,201);
});
