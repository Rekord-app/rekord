// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node test/automatic-acceptance.mjs <120-second.mp4> <artifacts>
import assert from 'node:assert/strict';
import { readFile,mkdir,writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { fixture } from './offer-fixture.mjs';
const { chromium,webkit } = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE).href);
const root = path.resolve(process.argv[3]); await mkdir(root,{ recursive:true });
const media = await readFile(process.argv[2]);
for (const [name,engine,options] of [['chrome',chromium,{ channel:'chrome' }],['webkit',webkit,{}]]) {
  const f = await fixture(),tick = setInterval(() => f.advance(1000),1000),browser = await engine.launch({ headless:true,...options });
  try {
    const context = await browser.newContext({ viewport:{ width:1280,height:900 } }),page = await context.newPage(),errors = [],writes = [];
    page.on('pageerror',e => errors.push(e.message));
    page.on('request',r => { if (/\/(sessions|events)/.test(r.url())) writes.push(r); });
    await context.route('https://booking.example.test/**',route => route.fulfill({ status:200,body:'Synthetic booking destination.' }));
    const v = await f.upload(media),o = await f.offer(v,{ trackingMode:'automatic',landingPage:{ sender:'Beispielagentur',buttonTitle:'Kennenlernen buchen',accent:'blue' },title:'Dein nächster Schritt',message:'In diesem Video zeige ich dir unseren Vorschlag. Lass uns über dein Projekt sprechen.' });
    const stats = async () => (await (await f.call('GET',`/api/offers/${o.id}/analytics`)).json()).summary;
    const active = async () => page.waitForFunction(() => document.querySelector('#tracking-status').textContent.includes('ist aktiv'));
    await page.goto(o.url); await active(); assert.equal((await stats()).openings,1);
    assert.equal(await page.locator('#allow-tracking').count(),0);
    assert.equal((await page.locator('#book').innerText()).replace(/\s+/g,' '),'Kennenlernen buchen ↗');
    assert.equal(await page.locator('.brand').innerText(),'Beispielagentur');
    assert.deepEqual(await context.cookies(),[]);
    assert.equal(await page.evaluate(() => sessionStorage.length+localStorage.length),0);
    const start = writes.find(r => r.url().endsWith('/sessions')).postDataJSON(); assert.deepEqual(start,{ measurementMode:'automatic-v1' });
    await page.evaluate(async () => { const v = document.querySelector('video'); v.muted = true; v.playbackRate = 2; await v.play(); });
    await page.waitForFunction(() => document.querySelector('video').currentTime >= 10);
    await page.evaluate(() => document.querySelector('video').pause()); await page.waitForTimeout(350);
    let s = await stats(); assert.ok(s.bestPercent > 7 && s.bestPercent < 10,JSON.stringify(s));
    const [popup] = await Promise.all([page.waitForEvent('popup'),page.click('#book')]); await popup.close(); await page.bringToFront(); await page.waitForTimeout(250);
    assert.equal((await stats()).ctaClickCount,1);
    await page.screenshot({ path:path.join(root,`${name}-automatic-desktop.png`),fullPage:true });
    await page.setViewportSize({ width:390,height:844 }); await page.screenshot({ path:path.join(root,`${name}-automatic-mobile.png`),fullPage:true });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await page.reload(); await active(); assert.equal((await stats()).openings,2); // no persistent identifier
    await page.click('#withdraw-tracking'); await page.waitForFunction(() => document.querySelector('#tracking-status').textContent.includes('gelöscht'));
    assert.equal((await stats()).openings,1);
    await page.reload(); await page.waitForTimeout(300); assert.equal((await stats()).openings,1);
    assert.match(await page.locator('#tracking-status').innerText(),/ausgeschaltet/);
    const privacy = await browser.newContext(); await privacy.addInitScript(() => Object.defineProperty(navigator,'globalPrivacyControl',{ value:true }));
    const privatePage = await privacy.newPage(); await privatePage.goto(o.url); await privatePage.waitForTimeout(250); assert.equal((await stats()).openings,1); await privacy.close();
    const noJS = await browser.newContext({ javaScriptEnabled:false }),plain = await noJS.newPage();
    await plain.goto(o.url); assert.equal(await plain.locator('video[controls]').count(),1); assert.equal(await plain.locator('#book').getAttribute('href'),'https://booking.example.test/termin'); assert.equal((await stats()).openings,1); await noJS.close();
    const preview = await (await f.call('POST',`/api/offers/${o.id}/preview`)).json(); await page.goto(preview.url); assert.equal(await page.locator('[data-offer-api]').count(),0); assert.equal((await stats()).openings,1);
    // Stop while the initial request is still in flight: its eventual session must be deleted.
    const delayed = await browser.newContext(),race = await delayed.newPage();
    await delayed.route('**/sessions',async route => { await new Promise(resolve => setTimeout(resolve,300)); await route.continue(); });
    await race.goto(o.url); await race.click('#withdraw-tracking'); await race.waitForTimeout(800);
    assert.equal((await stats()).openings,1); assert.match(await race.locator('#tracking-status').innerText(),/gelöscht|ausgeschaltet/); await delayed.close();
    assert.deepEqual(errors,[]);
    await writeFile(path.join(root,`${name}-automatic-report.json`),JSON.stringify({ pass:true,checks:['no checkbox','automatic opening','playback','CTA','template','no automatic storage/cookies','fresh reload','opt-out and reload','GPC','no JavaScript','preview','in-flight stop','390px layout'] },null,2));
    console.log(`PASS ${name}: automatic stats, template, playback/CTA, no cookies/storage, opt-out/reload, GPC, preview/no-JS, cancellation race`);
  } finally { clearInterval(tick); await browser.close(); await f.close(); }
}
