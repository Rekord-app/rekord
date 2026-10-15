import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PlaybackMeter } from '../public/tracking.js';
const sample = (meter,p,t,options = {}) => meter.observe({ position:p,wall:t,playing:true,seeking:false,played:[[0,p]],...options });
const seconds = m => m.ranges.reduce((n,[a,b]) => n+b-a,0);
test('meter excludes pre-consent, seek, buffering and pause; replay unions and speed respects media time',() => {
  const m = new PlaybackMeter();
  sample(m,20,0); sample(m,30,10000); assert.equal(seconds(m),10,'pre-consent 0–20 excluded');
  m.resetPosition(); sample(m,110,11000,{ played:[[0,30]] }); sample(m,115,16000,{ played:[[0,30],[110,115]] }); assert.equal(seconds(m),15);
  sample(m,115,26000,{ playing:false,played:[[0,30],[110,115]] }); assert.equal(seconds(m),15);
  sample(m,115,40000,{ playing:false }); assert.equal(seconds(m),15);
  m.resetPosition(); sample(m,20,41000); sample(m,30,51000); assert.equal(seconds(m),15,'replay does not inflate');
  m.resetPosition(); sample(m,40,52000,{ rate:2 }); sample(m,60,62000,{ rate:2,played:[[0,60],[110,115]] }); assert.equal(seconds(m),35);
});
test('30 of 120 seconds is 25%, 10 + 5 across a seek is 12.5%, missed seek event rejected',() => {
  const m = new PlaybackMeter(); sample(m,0,0); sample(m,30,30000); assert.equal(seconds(m)/120*100,25);
  const n = new PlaybackMeter(); sample(n,0,0); sample(n,10,10000); sample(n,110,10001); sample(n,115,15001,{ played:[[0,10],[110,115]] }); assert.equal(seconds(n)/120*100,12.5);
});
