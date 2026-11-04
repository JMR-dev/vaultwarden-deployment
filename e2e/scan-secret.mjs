// Look for a secret in the files a failed run would upload, including inside
// the HTML report's embedded zip, before scripts/e2e-disposable.sh lets any
// of them out.
//
//   printf '%s\n' "$secret" | node scan-secret.mjs <dir>...
//
// The secret comes on stdin, never as an argument. Prints only the names of
// files (and zip entries) that hold it, and exits 1 if there are any; 0 if
// none; 2 on a usage error or an unreadable report.
//
// Why the zip: Playwright's HTML report keeps its test data, step titles and
// error messages included, as a base64 zip inside index.html, so a plain grep
// of the report can't see them.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { inflateRawSync } from 'node:zlib';

const dirs = process.argv.slice(2);
const secret = readFileSync(0, 'utf8').replace(/\n$/, '');
if (dirs.length === 0 || secret.length < 8) {
  console.error('usage: printf "%s\\n" "$secret" | node scan-secret.mjs <dir>...  (secret of 8+ characters)');
  process.exit(2);
}
const needle = Buffer.from(secret, 'utf8');

// Every regular file under dir.
function* walk(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    const stat = statSync(path);
    if (stat.isDirectory()) {
      yield* walk(path);
    } else if (stat.isFile()) {
      yield path;
    }
  }
}

// The entries of a zip archive, as { name, data }, from its central
// directory. Stored (0) and deflated (8) entries only: what Playwright writes.
function* zipEntries(zip) {
  const eocdSignature = 0x06054b50;
  let eocd = -1;
  for (let i = zip.length - 22; i >= Math.max(0, zip.length - 22 - 65535); i--) {
    if (zip.readUInt32LE(i) === eocdSignature) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) {
    throw new Error('no end of central directory');
  }
  const count = zip.readUInt16LE(eocd + 10);
  let entry = zip.readUInt32LE(eocd + 16);
  for (let n = 0; n < count; n++) {
    if (zip.readUInt32LE(entry) !== 0x02014b50) {
      throw new Error('bad central directory entry');
    }
    const method = zip.readUInt16LE(entry + 10);
    const compressedSize = zip.readUInt32LE(entry + 20);
    const nameLength = zip.readUInt16LE(entry + 28);
    const extraLength = zip.readUInt16LE(entry + 30);
    const commentLength = zip.readUInt16LE(entry + 32);
    const localHeader = zip.readUInt32LE(entry + 42);
    const name = zip.subarray(entry + 46, entry + 46 + nameLength).toString('utf8');
    const localNameLength = zip.readUInt16LE(localHeader + 26);
    const localExtraLength = zip.readUInt16LE(localHeader + 28);
    const start = localHeader + 30 + localNameLength + localExtraLength;
    const raw = zip.subarray(start, start + compressedSize);
    if (method === 0) {
      yield { name, data: raw };
    } else if (method === 8) {
      yield { name, data: inflateRawSync(raw) };
    } else {
      throw new Error(`entry ${name}: compression method ${method} not supported`);
    }
    entry += 46 + nameLength + extraLength + commentLength;
  }
}

const zipPrefix = 'data:application/zip;base64,';
const hits = [];
try {
  for (const dir of dirs) {
    for (const path of walk(dir)) {
      const data = readFileSync(path);
      if (data.includes(needle)) {
        hits.push(path);
      }
      if (!path.endsWith('.html')) {
        continue;
      }
      // Each embedded zip: the base64 run after the data: prefix.
      const text = data.toString('latin1');
      for (let at = text.indexOf(zipPrefix); at >= 0; at = text.indexOf(zipPrefix, at + 1)) {
        const base64 = /^[A-Za-z0-9+/=]*/.exec(text.slice(at + zipPrefix.length))[0];
        for (const { name, data: entry } of zipEntries(Buffer.from(base64, 'base64'))) {
          if (entry.includes(needle)) {
            hits.push(`${path} (zip entry ${name})`);
          }
        }
      }
    }
  }
} catch (error) {
  console.error(`scan-secret: ${error.message}`);
  process.exit(2);
}

for (const hit of hits) {
  console.log(hit);
}
process.exit(hits.length > 0 ? 1 : 0);
