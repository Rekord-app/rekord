import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './offer-fixture.mjs';
import { writeFile } from 'node:fs/promises';
import path from 'node:path';

test('consent, separated sessions, interval union, retries and durable first activity',async () => {
  const f = await fixture();
  try {
    const v = await f.upload(),a = await f.offer(v),b = await f.offer(v);
    const url = `/api/offers/${a.id}`;
    assert.equal((await f.call('POST',url+'/sessions',{}, { owner:false })).status,400);
    assert.equal((await f.call('POST',url+'/sessions',{ consent:'playback-v1' },{ origin:'https://evil.test' })).status,403);
    assert.equal((await f.call('POST',url+'/sessions',{ consent:'playback-v1' },{ origin:null })).status,403);
    const s = await f.session(a); f.advance(30000); assert.equal((await f.event(a,s)).status,204);
    assert.equal((await f.event(a,s)).status,204);
    assert.equal((await f.event(b,s)).status,403);
    let stats = await (await f.call('GET',url+'/analytics')).json(); assert.equal(stats.summary.bestPercent,25); assert.equal(stats.summary.ctaClickCount,1);
    f.advance(30000); assert.equal((await f.event(a,s,{ sequence:2,playedRanges:[[0,30],[10,30],[30,60]],lastPosition:60 })).status,204);
    stats = await (await f.call('GET',url+'/analytics')).json(); assert.equal(stats.summary.bestPercent,50);
    const s2 = await f.session(a); f.advance(15000); assert.equal((await f.event(a,s2,{ playedRanges:[[0,10],[110,115]],lastPosition:115 })).status,204);
    stats = await (await f.call('GET',url+'/analytics')).json(); assert.equal(stats.entries[1].percent,12.5); assert.equal(stats.summary.bestPercent,50); assert.equal(stats.summary.openings,2);
    let activity = await (await f.call('GET','/api/offer-activity')).json(); assert.equal(activity.entries.length,1);
    const cursor = activity.nextCursor; assert.equal((await (await f.call('GET','/api/offer-activity?after='+encodeURIComponent(cursor))).json()).entries.length,0);
    await f.stop(); await f.start();
    activity = await (await f.call('GET','/api/offer-activity')).json(); assert.equal(activity.entries.length,1); assert.equal(activity.nextCursor,cursor);
    assert.equal((await (await f.call('GET',url+'/analytics')).json()).summary.bestPercent,50);
    const resume = await f.call('POST',url+'/sessions',{ consent:'playback-v1',sessionId:s.id,sessionKey:s.sessionKey }); assert.equal((await resume.json()).id,s.id);
    assert.equal((await f.call('DELETE',url+'/sessions/'+s.id,{ sessionKey:s.sessionKey },{ owner:false })).status,204);
    assert.equal((await f.event(a,s,{ sequence:9 })).status,403);
    stats = await (await f.call('GET',url+'/analytics')).json(); assert.equal(stats.summary.bestPercent,12.5); assert.equal(stats.summary.openings,1);
    assert.equal((await (await f.call('GET','/api/offer-activity')).json()).entries.length,0);
  } finally { await f.close(); }
});
test('reset, tracking toggles, inactivity, quotas, malformed input and retention fail safely',async () => {
  const f = await fixture({ offerOptions:{ analyticsOptions:{ maxSessions:2 } } });
  try {
    const v = await f.upload(),o = await f.offer(v),url = `/api/offers/${o.id}`,s = await f.session(o);
    f.advance(30000);
    for (const ranges of [[[0,121]],[[20,10]],[[null,20]],'bad',Array.from({ length:257 },() => [1,2])]) assert.equal((await f.event(o,s,{ playedRanges:ranges })).status,400);
    assert.equal((await f.event(o,s,{ sequence:-1 })).status,400);
    await f.call('PATCH',url,{ trackingEnabled:false }); assert.equal((await f.event(o,s)).status,403);
    await f.call('PATCH',url,{ trackingEnabled:true }); assert.equal((await f.event(o,s)).status,410);
    const s2 = await f.session(o); assert.equal((await f.call('POST',url+'/sessions',{ consent:'playback-v1' })).status,503);
    assert.equal((await (await f.call('GET',url+'/analytics')).json()).summary.state,'limited');
    assert.equal((await f.call('GET',`/om/${o.id}`)).status,200);
    await f.call('DELETE',url+'/analytics'); assert.equal((await f.event(o,s2)).status,403);
    const s3 = await f.session(o); f.advance(31*60000); assert.equal((await f.event(o,s3)).status,410);
    f.advance(91*86400000); const stats = await (await f.call('GET',url+'/analytics')).json(); assert.equal(stats.summary.openings,0);
    assert.equal((await (await f.call('GET','/api/offer-activity')).json()).entries.length,0);
    await f.session(o); assert.equal((await (await f.call('GET','/api/offer-activity')).json()).entries.length,0,'retention never rearms first-open notification');
  } finally { await f.close(); }
});
test('damaged analytics quarantines in isolation; explicit reset restores measurement',async () => {
  const f = await fixture();
  try {
    const v = await f.upload(),o = await f.offer(v); await f.session(o); await f.stop();
    await writeFile(path.join(f.directory,'analytics',o.id+'.json'),'{broken'); await f.start();
    assert.equal((await f.call('GET',`/om/${o.id}`)).status,200);
    assert.equal((await (await f.call('GET',`/api/offers/${o.id}/analytics`)).json()).summary.state,'damaged');
    await f.call('DELETE',`/api/offers/${o.id}/analytics`); await f.session(o);
  } finally { await f.close(); }
});

test('20 concurrent sessions, rate/byte limits and revoked permissions',async () => {
  const f = await fixture();
  try {
    const v = await f.upload(),o = await f.offer(v),url = `/api/offers/${o.id}`;
    const sessions = await Promise.all(Array.from({ length:20 },() => f.session(o))); f.advance(30000);
    const results = await Promise.all(sessions.map(s => f.event(o,s))); assert.ok(results.every(r => r.status === 204));
    const stats = await (await f.call('GET',url+'/analytics')).json(); assert.equal(stats.summary.openings,20); assert.equal(stats.summary.bestPercent,25); assert.equal(stats.summary.ctaClickCount,20);
    assert.equal((await f.call('GET',`/om/${o.id}`,null,{ headers:{ Range:'bytes=0-31' } })).status,206);
    for (let i=2;i<=12;i++) assert.equal((await f.event(o,sessions[0],{ sequence:i })).status,204);
    assert.equal((await f.event(o,sessions[0],{ sequence:13 })).status,429);
    assert.equal((await f.call('POST',url+'/events',{ payload:'x'.repeat(17000) })).status,413);
    await f.call('DELETE',`/api/videos/${v.id}`); f.advance(60000); assert.equal((await f.event(o,sessions[1],{ sequence:2 })).status,404);
    assert.equal((await (await f.call('GET','/api/status')).json()).offerAnalytics.sessions,0);
  } finally { await f.close(); }
  const small = await fixture({ offerOptions:{ analyticsOptions:{ maxBytes:100 } } });
  try { const o = await small.offer(await small.upload()); assert.equal((await small.call('POST',`/api/offers/${o.id}/sessions`,{ consent:'playback-v1' })).status,503); assert.equal((await small.call('GET',`/om/${o.id}`)).status,200); }
  finally { await small.close(); }
});

test('pagination uses the same ordering as its cursor, and quarantine survives restart',async () => {
  const { pageOf } = await import('../analytics.mjs');
  const values = Array.from({ length:180 },(_,i) => ({ cursor:`2026|${String.fromCharCode(33+i)}` }));
  let after = '',found = [];
  do { const page = pageOf(values,after); found.push(...page.entries); if (!page.hasMore) break; after = page.nextCursor; } while (found.length <= 200);
  assert.equal(new Set(found.map(x => x.cursor)).size,180);
  const f = await fixture();
  try {
    const o = await f.offer(await f.upload()); await f.session(o); await f.stop();
    await writeFile(path.join(f.directory,'analytics',o.id+'.json'),'{}'); await f.start(); await f.stop(); await f.start();
    assert.equal((await (await f.call('GET',`/api/offers/${o.id}/analytics`)).json()).summary.state,'damaged');
    await f.call('DELETE',`/api/offers/${o.id}/analytics`); await f.stop(); await f.start();
    assert.equal((await (await f.call('GET',`/api/offers/${o.id}/analytics`)).json()).summary.state,'ready');
  } finally { await f.close(); }
});
