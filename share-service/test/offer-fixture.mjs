import { mkdtemp,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomBytes,createHash } from 'node:crypto';
import { createShareServer } from '../server.mjs';
const box = (type,...parts) => { const body = Buffer.concat(parts),head = Buffer.alloc(8); head.writeUInt32BE(body.length+8); head.write(type,4,'latin1'); return Buffer.concat([head,body]); };
export function movie(duration = 120) {
  const mvhd = Buffer.alloc(100),hdlr = Buffer.alloc(24); mvhd.writeUInt32BE(1000,12); mvhd.writeUInt32BE(duration*1000,16); hdlr.write('vide',8,'latin1');
  return Buffer.concat([box('ftyp',Buffer.from('isom\0\0\0\0isomiso2')),box('moov',box('mvhd',mvhd),box('trak',box('mdia',box('hdlr',hdlr)))),box('mdat',randomBytes(4000))]);
}
export async function fixture(options = {}) {
  const directory = await mkdtemp(path.join(tmpdir(),'rekord-offers-')),token = randomBytes(32).toString('hex');
  let time = Date.now(); const f = { directory,token,advance:ms => time += ms };
  f.start = async extra => {
    f.server = await createShareServer({ storageDirectory:directory,uploadToken:token,...options,...extra,offerOptions:{ ...options.offerOptions,now:() => time } });
    await new Promise(resolve => f.server.listen(0,'127.0.0.1',resolve));
    const configured = options.publicBaseURL ? new URL(options.publicBaseURL) : null;
    f.base = `http://127.0.0.1:${f.server.address().port}${configured?.pathname.replace(/\/$/,'') ?? ''}`;
    f.origin = configured?.origin ?? new URL(f.base).origin;
  };
  f.stop = async () => { f.server.closeAllConnections(); await new Promise(resolve => f.server.close(resolve)); };
  f.close = async () => { await f.stop(); await rm(directory,{ recursive:true,force:true }); };
  f.call = (method,url,body,{ owner = true,origin = f.origin,headers = {} } = {}) => fetch(f.base+url,{ method,headers:{ ...(owner ? { Authorization:`Bearer ${token}` } : {}),...(body ? { 'Content-Type':'application/json' } : {}),...(origin ? { Origin:origin } : {}),...headers },...(body ? { body:JSON.stringify(body) } : {}) });
  f.upload = async (data = movie()) => {
    const r = await fetch(f.base+'/api/videos',{ method:'POST',headers:{ Authorization:`Bearer ${token}`,'Content-Type':'video/mp4','X-Focus-SHA256':createHash('sha256').update(data).digest('hex') },body:data });
    if (r.status !== 201) throw Error(await r.text()); return r.json();
  };
  f.offer = async (video,extra = {}) => {
    const r = await f.call('POST','/api/offers',{ videoId:video.id,creationRequestId:randomBytes(16).toString('hex'),recipientLabel:'INTERNER EMPFÄNGER',title:'Dein Angebot',message:'Hier der Ablauf.',bookingURL:'https://booking.example.test/termin',...extra });
    if (r.status !== 201) throw Error(await r.text()); return r.json();
  };
  f.session = async offer => { const r = await f.call('POST',`/api/offers/${offer.id}/sessions`,{ consent:'playback-v1' },{ owner:false }); if (r.status !== 201) throw Error(await r.text()); return r.json(); };
  f.event = (offer,s,extra = {}) => f.call('POST',`/api/offers/${offer.id}/events`,{ sessionId:s.id,sessionKey:s.sessionKey,sequence:1,playedRanges:[[0,30]],lastPosition:30,ctaClickCount:1,...extra },{ owner:false });
  await f.start(); return f;
}
