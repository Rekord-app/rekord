import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const connection = JSON.parse(await readFile(process.argv[2],'utf8'));
const movie = await readFile(process.argv[3]);
const response = await fetch(`${connection.baseURL}/api/videos`,{ method:'POST',headers:{ authorization:`Bearer ${connection.token}`,'content-type':'video/mp4','x-focus-title':Buffer.from('Ein klarer Gedanke. Einfach geteilt.').toString('base64url'),'x-focus-sha256':createHash('sha256').update(movie).digest('hex') },body:movie });
if (!response.ok) throw new Error(`Demo upload failed (${response.status})`);
const result = await response.json();
await writeFile(process.argv[4],JSON.stringify(result));
console.log(result.url);
