import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdir,readFile,writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fixture,movie } from './offer-fixture.mjs';

test('one media, separate offers, request idempotency, escaped CTA and private fields',async () => {
  const f = await fixture();
  try {
    const data = movie(),v = await f.upload(data); assert.equal(v.durationSeconds,120); assert.equal((await f.upload(data)).id,v.id);
    const request = { creationRequestId:'request-1234567890',title:'<script>Hallo</script>',message:'<img src=x>',bookingURL:'https://booking.example.test/?x=1&y=2' };
    const a = await f.offer(v,request),b = await f.offer(v,{ recipientLabel:'Zweiter Empfänger' }); assert.notEqual(a.id,b.id);
    assert.equal((await f.offer(v,request)).id,a.id);
    assert.equal((await f.call('POST','/api/offers',{ videoId:v.id,...request,title:'anders' })).status,409);
    const page = await f.call('GET',`/o/${a.id}`); const content = await page.text();
    assert.match(content,/Termin buchen/); assert.match(content,/&lt;script&gt;Hallo/); assert.doesNotMatch(content,/INTERNER EMPFÄNGER|recipientLabel|creationRequestId/);
    assert.doesNotMatch(content,new RegExp(v.id)); assert.match(content,new RegExp(`/om/${a.id}`)); assert.match(content,/rel="noopener noreferrer"/);
    assert.match(page.headers.get('content-security-policy'),/connect-src 'self'/);
    const media = await f.call('GET',`/om/${a.id}`,null,{ headers:{ Range:'bytes=0-31' } }); assert.equal(media.status,206); assert.equal((await media.arrayBuffer()).byteLength,32);
    assert.equal((await readdir(f.directory)).filter(f => f.endsWith('.mp4')).length,1);
    const status = await (await f.call('GET','/api/status')).json(); assert.ok(status.features.includes('video-offers-v1'));
    assert.equal((await (await f.call('GET','/api/offer-activity')).json()).entries.length,0);
    assert.equal((await f.call('GET','/api/offers',null,{ owner:false })).status,401);
    assert.equal((await f.call('PATCH',`/api/videos/${'z'.repeat(32)}`,{ expiresAt:null })).status,404);
    assert.equal((await f.call('GET',`/api/offers/${a.id}/analytics`,null,{ owner:false })).status,401);
    for (const url of ['javascript:alert(1)','data:text/plain,x','//evil.test','http://evil.test','https://user:password@example.test']) assert.equal((await f.call('PATCH',`/api/offers/${a.id}`,{ bookingURL:url })).status,400);
  } finally { await f.close(); }
});
test('preview, normal GET/HEAD and preload do not measure; expiry and revoke isolate links',async () => {
  const f = await fixture({ publicBaseURL:'https://share.example.test/focus-share' });
  try {
    const v = await f.upload(),a = await f.offer(v),b = await f.offer(v);
    const preview = await (await f.call('POST',`/api/offers/${a.id}/preview`)).json();
    assert.equal((await f.call('POST',`/api/offers/${a.id}/preview`,null,{ owner:false })).status,401);
    const relative = new URL(preview.url).pathname.replace('/focus-share','')+new URL(preview.url).search;
    const html = await (await f.call('GET',relative)).text(); assert.match(html,/VORSCHAU/); assert.doesNotMatch(html,/data-offer-api|tracking.js|allow-tracking/);
    assert.match(html,/\/focus-share\/om\//); assert.match(html,/\/focus-share\/assets\/player.css/);
    await f.call('HEAD',`/o/${a.id}`); await f.call('GET',`/om/${a.id}`,null,{ headers:{ Range:'bytes=0-10' } });
    assert.equal((await (await f.call('GET',`/api/offers/${a.id}/analytics`)).json()).summary.openings,0);
    f.advance(16*60000); assert.equal((await f.call('GET',relative)).status,403);
    assert.equal((await f.call('DELETE',`/api/offers/${a.id}`)).status,204);
    for (const route of [`/o/${a.id}`,`/om/${a.id}`]) assert.equal((await f.call('GET',route)).status,404);
    assert.equal((await f.call('GET',`/o/${b.id}`)).status,200);
    assert.equal((await f.call('GET',`/v/${v.id}`)).status,200);
    await f.call('PATCH',`/api/offers/${b.id}`,{ expiresAt:new Date(Date.now()+17*60000).toISOString() }); f.advance(2*60000);
    assert.equal((await f.call('GET',`/o/${b.id}`)).status,410);
    const c = await f.offer(v); await f.call('DELETE',`/api/videos/${v.id}`); assert.equal((await f.call('GET',`/o/${c.id}`)).status,404);
  } finally { await f.close(); }
});
test('old metadata lazily acquires duration; rollback flag keeps existing offer playback',async () => {
  const f = await fixture();
  try {
    const v = await f.upload(); await f.stop();
    const file = path.join(f.directory,'metadata',v.id+'.json'),old = JSON.parse(await readFile(file)); delete old.durationSeconds; await writeFile(file,JSON.stringify(old));
    await f.start(); const a = await f.offer(v); assert.equal(a.durationSeconds,120);
    await f.stop(); await f.start({ offersEnabled:false });
    assert.equal((await f.call('GET',`/o/${a.id}`)).status,200); assert.equal((await f.call('GET',`/om/${a.id}`)).status,200);
    assert.equal((await f.call('POST','/api/offers',{ videoId:v.id })).status,503);
    assert.equal((await f.call('POST',`/api/offers/${a.id}/sessions`,{ consent:'playback-v1' })).status,403);
  } finally { await f.close(); }
});

test('legacy guide revocation also invalidates linked offer sessions across restart',async () => {
  const f = await fixture();
  try {
    const v = await f.upload(),o = await f.offer(v),s = await f.session(o); const guideID = 'G'.repeat(32);
    await f.stop();
    await writeFile(path.join(f.directory,'guides',guideID+'.json'),JSON.stringify({ id:guideID,title:'Synthetic legacy guide',videoId:v.id,apps:[],steps:[{ text:'step',image:false }],bytes:0,createdAt:new Date().toISOString() }));
    await f.start();
    assert.equal((await f.call('DELETE',`/api/guides/${guideID}`)).status,204);
    assert.equal((await f.call('GET',`/o/${o.id}`)).status,404); assert.equal((await f.call('GET',`/om/${o.id}`)).status,404);
    assert.equal((await f.event(o,s)).status,404);
    assert.equal((await (await f.call('GET','/api/status')).json()).offerAnalytics.sessions,0);
    await f.stop(); await f.start(); assert.equal((await f.call('GET',`/o/${o.id}`)).status,404);
  } finally { await f.close(); }
});

test('landing template snapshots and automatic measurements survive restart without fabricated consent',async () => {
  const f = await fixture();
  try {
    const v = await f.upload(),legacy = await f.offer(v);
    const input = { trackingMode:'automatic',landingPage:{ sender:'Acme <script>',buttonTitle:'Gespräch & Termin',accent:'blue' } };
    const o = await f.offer(v,input),url = `/api/offers/${o.id}`;
    assert.equal(o.trackingMode,'automatic'); assert.deepEqual(o.landingPage,input.landingPage);
    const page = await (await f.call('GET',`/o/${o.id}`)).text();
    assert.match(page,/accent-blue/); assert.match(page,/Acme &lt;script&gt;/); assert.match(page,/Gespräch &amp; Termin/);
    assert.match(page,/data-tracking-mode="automatic"/); assert.doesNotMatch(page,/allow-tracking|tracking-choice/);
    for (const body of [{ landingPage:{ accent:'red" onclick="evil' } },{ landingPage:{ buttonTitle:' ' } },{ landingPage:{ sender:'x'.repeat(101) } },{ landingPage:null },{ trackingMode:'secret' }]) {
      assert.equal((await f.call('PATCH',url,body)).status,400);
    }
    const mode = { measurementMode:'automatic-v1' };
    assert.equal((await f.call('POST',`/api/offers/${legacy.id}/sessions`,mode,{ owner:false })).status,400);
    assert.equal((await f.call('POST',url+'/sessions',{ ...mode,preview:true },{ owner:false })).status,400);
    const response = await f.call('POST',url+'/sessions',mode,{ owner:false }); assert.equal(response.status,201); const session = await response.json();
    const record = JSON.parse(await readFile(path.join(f.directory,'analytics',`${o.id}.json`),'utf8'));
    assert.equal(record.sessions[0].measurementMode,'automatic-v1'); assert.equal(record.sessions[0].consentVersion,undefined);
    await f.stop(); await f.start();
    const list = await (await f.call('GET','/api/offers')).json();
    assert.deepEqual(list.offers.find(x => x.id === o.id).landingPage,input.landingPage);
    assert.equal((await (await f.call('GET',url+'/analytics')).json()).summary.openings,1);
    const preview = await (await f.call('POST',url+'/preview')).json();
    const previewHTML = await (await fetch(preview.url)).text(); assert.doesNotMatch(previewHTML,/tracking.js|data-offer-api/);
    await f.call('PATCH',url,{ trackingMode:'consent' }); assert.equal((await f.event(o,session)).status,410);
    const stopped = await f.call('DELETE',url+`/sessions/${session.id}`,{ sessionKey:session.sessionKey },{ owner:false }); assert.equal(stopped.status,204);
    assert.equal((await (await f.call('GET',url+'/analytics')).json()).summary.openings,0);
  } finally { await f.close(); }
});
