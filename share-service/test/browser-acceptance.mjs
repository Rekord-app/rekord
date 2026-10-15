// Optional acceptance: PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs node test/browser-acceptance.mjs <120-second.mp4> <artifacts>
// Uses isolated profiles and synthetic media only. Does not contact the booking destination.
import assert from 'node:assert/strict';
import { readFile,mkdir,writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { fixture } from './offer-fixture.mjs';
const { chromium,webkit } = await import(process.env.PLAYWRIGHT_MODULE ? pathToFileURL(process.env.PLAYWRIGHT_MODULE).href : 'playwright');
const root = path.resolve(process.argv[3]); await mkdir(root,{ recursive:true });
const media = await readFile(process.argv[2]);
const report = [];
for (const [name,engine,options] of [['chrome',chromium,{ channel:'chrome' }],['webkit',webkit,{}]]) {
  if (process.env.BROWSER && process.env.BROWSER !== name) continue;
  const f = await fixture(),tick = setInterval(() => f.advance(1000),1000);
  const browser = await engine.launch({ headless:true,...options });
  try {
    const context = await browser.newContext({ viewport:{ width:1280,height:900 } }),page = await context.newPage(),errors = [],requests = [];
    page.on('pageerror',e => errors.push(e.message)); page.on('request',r => { if (/\/(sessions|events)/.test(r.url())) requests.push(r.url()); });
    await context.route('https://booking.example.test/**',route => route.fulfill({ status:200,contentType:'text/html',body:'Synthetic booking target. No booking was made.' }));
    const v = await f.upload(media),o = await f.offer(v,{ title:'Dein nächster Schritt',message:'In diesem kurzen Video zeige ich dir unseren Vorschlag. Wenn es passt, lass uns einen Termin finden.' });
    const stats = async () => (await (await f.call('GET',`/api/offers/${o.id}/analytics`)).json()).summary;
    await page.goto(o.url); await page.waitForFunction(() => document.querySelector('video').readyState >= 1);
    await page.screenshot({ path:path.join(root,`${name}-desktop.png`),fullPage:true });
    assert.equal(requests.length,0);
    await page.evaluate(async () => { const v = document.querySelector('video'); v.muted = true; await v.play(); });
    await page.waitForTimeout(1100); await page.evaluate(() => document.querySelector('video').pause());
    assert.equal(requests.length,0);
    await page.click('#deny-tracking'); assert.equal(requests.length,0);
    assert.equal((await stats()).openings,0);
    await page.reload(); await page.waitForFunction(() => document.querySelector('video').readyState >= 1);
    await page.click('#allow-tracking'); await page.waitForSelector('#withdraw-tracking:not([hidden])');
    async function segment(start,end,rate=2) {
      await page.evaluate(async ({start,rate}) => { const v = document.querySelector('video'); v.pause(); v.muted = true; if (Math.abs(v.currentTime-start)>0.01) { await new Promise(resolve => { v.addEventListener('seeked',resolve,{ once:true }); v.currentTime = start; }); } v.playbackRate = rate; await v.play(); },{ start,rate });
      await page.waitForFunction(end => document.querySelector('video').currentTime >= end,end,{ timeout:40000,polling:30 });
      await page.evaluate(() => document.querySelector('video').pause());
      await page.waitForTimeout(300);
    }
    await segment(0,30); let s = await stats(); assert.ok(Math.abs(s.bestPercent-25)<1,JSON.stringify(s));
    await segment(0,30); s = await stats(); assert.ok(Math.abs(s.bestPercent-25)<1,JSON.stringify(s));
    await segment(60,90); s = await stats(); assert.ok(Math.abs(s.bestPercent-50)<1,JSON.stringify(s));
    const before = s.bestPercent; await page.waitForTimeout(1000); assert.equal((await stats()).bestPercent,before);
    const [popup] = await Promise.all([page.waitForEvent('popup'),page.click('#book')]); await popup.close(); await page.bringToFront(); await page.waitForTimeout(300);
    assert.equal((await stats()).ctaClickCount,1);
    await page.reload(); await page.waitForSelector('#withdraw-tracking:not([hidden])'); assert.equal((await stats()).openings,1);
    await page.click('#withdraw-tracking'); await page.waitForFunction(() => document.querySelector('#tracking-status').textContent.includes('gelöscht')); assert.equal((await stats()).openings,0);
    // A fresh separate session: 10 seconds plus 5 after a large seek is 12.5%, never 95.8%.
    await page.reload(); await page.waitForFunction(() => document.querySelector('video').readyState >= 1); await page.click('#allow-tracking'); await page.waitForSelector('#withdraw-tracking:not([hidden])');
    await segment(0,10); await segment(110,115); s = await stats(); assert.ok(Math.abs(s.bestPercent-12.5)<1,JSON.stringify(s));
    await page.setViewportSize({ width:390,height:844 });
    await page.screenshot({ path:path.join(root,`${name}-mobile.png`),fullPage:true });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await page.focus('#book'); assert.equal(await page.evaluate(() => document.activeElement.id),'book');
    const noJS = await browser.newContext({ javaScriptEnabled:false,viewport:{ width:390,height:844 } }),plain = await noJS.newPage();
    await plain.goto(o.url); assert.equal(await plain.locator('#book').getAttribute('href'),'https://booking.example.test/termin'); assert.equal(await plain.locator('video[controls]').count(),1); await noJS.close();
    assert.deepEqual(errors,[]);
    report.push({ browser:name,pass:true,lastPercent:s.bestPercent,checks:['no pre-consent requests','decline','30/120','replay union','two different ranges','pause','CTA','reload','withdrawal','seek 10+5','390px layout','keyboard','no JavaScript'] });
    await writeFile(path.join(root,`${name}-report.json`),JSON.stringify(report.at(-1),null,2));
    console.log(`PASS ${name}: consent, 25% / 50% / ${s.bestPercent.toFixed(2)}%, CTA, reload/withdrawal, desktop/mobile/no-JS`);
  } finally { clearInterval(tick); await browser.close(); await f.close(); }
}
await writeFile(path.join(root,'browser-report.json'),JSON.stringify(report,null,2));
