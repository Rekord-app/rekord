import { createShareServer } from '../server.mjs';
import { randomBytes } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
const root = path.resolve(process.argv[2]);
await mkdir(root,{ recursive:true,mode:0o700 });
const token = randomBytes(32).toString('hex');
const server = await createShareServer({ storageDirectory:path.join(root,'storage'),uploadToken:token });
await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
// Malicious receipt fixtures exercise the native client's exact origin/capability checks.
const invalid = http.createServer((req,res) => {
  const kind = req.url.split('/')[1], base = `http://127.0.0.1:${invalid.address().port}/${kind}`;
  if (req.url.endsWith('/api/status')) { res.end(JSON.stringify({ service:'focus-recorder-share',version:1,features:kind === 'legacy' ? [] : ['guide-lifecycle-v2'],maxUploadBytes:1000,availableBytes:1000 })); return; }
  const id = 'A'.repeat(32), offer = req.url.includes('/api/offers'), url = new URL(`${base}/${offer ? 'o' : 'g'}/${id}`);
  if (kind === 'port') url.port = String(Number(url.port)+1);
  if (kind === 'credentials') url.username = 'not-allowed';
  if (kind === 'query') url.search = '?not=allowed';
  if (kind === 'fragment') url.hash = '#not-allowed';
  if (kind === 'path') url.pathname = '/elsewhere';
  if (kind === 'scheme') url.protocol = 'https:';
  if (offer) { res.end(JSON.stringify({ offers:[{ id,videoId:'V'.repeat(32),url:url.href,title:'Synthetic forged offer',recipientLabel:'',message:'',bookingURL:'https://example.test/booking',trackingEnabled:true,notifyOnFirstOpen:false,createdAt:new Date().toISOString(),expiresAt:null,durationSeconds:120,summary:{ openings:0,started:0,bestPercent:0,bestPlayedSeconds:0,ctaClickCount:0,lastActivityAt:null,state:'ready',retentionDays:90 } }],nextCursor:'',hasMore:false })); return; }
  res.end(JSON.stringify({ guides:[{ id,url:url.href,title:'Synthetic forged receipt',bytes:1,createdAt:new Date().toISOString() }] }));
});
await new Promise(resolve => invalid.listen(0,'127.0.0.1',resolve));
await writeFile(path.join(root,'connection.json'),JSON.stringify({ baseURL:`http://127.0.0.1:${server.address().port}`,token,invalidReceiptBaseURL:`http://127.0.0.1:${invalid.address().port}` }),{ mode:0o600 });
console.log(`Local share integration server ready on port ${server.address().port}; credentials saved privately, not logged.`);
for (const signal of ['SIGINT','SIGTERM']) process.on(signal,() => { invalid.close(); server.close(() => process.exit(0)); });
