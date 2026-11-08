import { access, open, readdir, readFile, writeFile, constants } from 'node:fs/promises';
import { join } from 'node:path';

const placeholder = 'http://fuqn-runtime-backend.invalid/api';
const banned = [
  'replace-with-a-long-random-secret',
  'postiz-password',
  'postiz-local-pwd',
  'changeme',
  'random string',
];

function fail(message) {
  console.error(`fuqn runtime config: ${message}`);
  process.exit(1);
}

function rejectPlaceholder(name, value) {
  if (!value) {
    fail(`${name} is required`);
  }
  const lower = value.toLowerCase();
  for (const item of banned) {
    if (lower.includes(item)) {
      fail(`${name} still contains a known placeholder`);
    }
  }
}

function requireHttpUrl(name, value) {
  rejectPlaceholder(name, value);
  let url;
  try {
    url = new URL(value);
  } catch {
    fail(`${name} is not a URL`);
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    fail(`${name} must use http or https`);
  }
  if (url.username || url.password) {
    fail(`${name} must not include credentials`);
  }
  if (value.endsWith('/')) {
    fail(`${name} must not end with /`);
  }
  return url;
}

function replaceBuffer(buf, from, to) {
  const parts = [];
  let start = 0;
  let count = 0;
  while (start <= buf.length) {
    const idx = buf.indexOf(from, start);
    if (idx === -1) {
      break;
    }
    parts.push(buf.subarray(start, idx), to);
    start = idx + from.length;
    count += 1;
  }
  if (count === 0) {
    return { buf, count: 0 };
  }
  parts.push(buf.subarray(start));
  return { buf: Buffer.concat(parts), count };
}

async function walk(dir, from, to) {
  let count = 0;
  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      count += await walk(path, from, to);
      continue;
    }
    if (!entry.isFile()) {
      continue;
    }
    const data = await readFile(path);
    if (!data.includes(from)) {
      continue;
    }
    const replaced = replaceBuffer(data, from, to);
    await writeFile(path, replaced.buf);
    count += replaced.count;
  }
  return count;
}

const jwt = process.env.JWT_SECRET || '';
rejectPlaceholder('JWT_SECRET', jwt);
if (jwt.trim().length < 32) {
  fail('JWT_SECRET must be at least 32 characters');
}

rejectPlaceholder('DATABASE_URL', process.env.DATABASE_URL);
let database;
try {
  database = new URL(process.env.DATABASE_URL);
} catch {
  fail('DATABASE_URL is not a URL');
}
if (database.protocol !== 'postgresql:' && database.protocol !== 'postgres:') {
  fail('DATABASE_URL must be a postgres URL');
}
if (!database.username || !database.password || database.pathname === '/') {
  fail('DATABASE_URL must include a user, a password, and a database name');
}

rejectPlaceholder('REDIS_URL', process.env.REDIS_URL);
let redis;
try {
  redis = new URL(process.env.REDIS_URL);
} catch {
  fail('REDIS_URL is not a URL');
}
if (redis.protocol !== 'redis:' && redis.protocol !== 'rediss:') {
  fail('REDIS_URL must use redis or rediss');
}
if (!redis.password) {
  fail('REDIS_URL must include a password');
}

const frontend = requireHttpUrl('FRONTEND_URL', process.env.FRONTEND_URL);
const main = requireHttpUrl('MAIN_URL', process.env.MAIN_URL);
const backend = requireHttpUrl(
  'NEXT_PUBLIC_BACKEND_URL',
  process.env.NEXT_PUBLIC_BACKEND_URL
);
if (process.env.FRONTEND_URL !== process.env.MAIN_URL) {
  fail('MAIN_URL must equal FRONTEND_URL on this base image');
}
if (frontend.origin !== main.origin || frontend.origin !== backend.origin) {
  fail('FRONTEND_URL, MAIN_URL, and NEXT_PUBLIC_BACKEND_URL must share one origin');
}
if (backend.pathname !== '/api') {
  fail('NEXT_PUBLIC_BACKEND_URL path must be /api');
}
if (backend.hostname === 'fuqn-runtime-backend.invalid') {
  fail('NEXT_PUBLIC_BACKEND_URL is still the image build placeholder');
}

const internal = process.env.BACKEND_INTERNAL_URL;
if (internal !== 'http://127.0.0.1:3000' && internal !== 'http://localhost:3000') {
  fail('BACKEND_INTERNAL_URL must be http://127.0.0.1:3000 for this single-container image');
}

if (!/^[A-Za-z0-9._-]+:[0-9]{2,5}$/.test(process.env.TEMPORAL_ADDRESS || '')) {
  fail('TEMPORAL_ADDRESS must look like host:port');
}

if (process.env.IS_GENERAL !== 'true') {
  fail('IS_GENERAL=true is required by the current Postiz configuration');
}

if ((process.env.STORAGE_PROVIDER || 'local') !== 'local') {
  fail(
    'This base image was built for STORAGE_PROVIDER=local. Upload redirects are fixed at image build time.'
  );
}

const notSecured = (process.env.NOT_SECURED || '').toLowerCase();
if (notSecured === '1' || notSecured === 'true' || notSecured === 'yes') {
  fail('NOT_SECURED is refused by the fuqn base image');
}

if (process.env.FUQN_PUBLIC_BACKEND_PLACEHOLDER !== placeholder) {
  fail('FUQN_PUBLIC_BACKEND_PLACEHOLDER does not match this image');
}

const replacement = process.env.NEXT_PUBLIC_BACKEND_URL;
if (
  replacement.includes(placeholder) ||
  replacement.includes('\0') ||
  replacement.includes('\n') ||
  replacement.includes('\r')
) {
  fail('NEXT_PUBLIC_BACKEND_URL cannot be written into the frontend bundle');
}

const nextDir = '/app/apps/frontend/.next';
let replacements = 0;
try {
  await access(nextDir, constants.R_OK);
  replacements = await walk(
    nextDir,
    Buffer.from(placeholder),
    Buffer.from(replacement)
  );
} catch (error) {
  fail(`could not update the frontend bundle (${error.code || error.message})`);
}
if (replacements < 1) {
  let alreadyApplied = false;
  try {
    alreadyApplied = await walk(
      nextDir,
      Buffer.from(replacement),
      Buffer.from(replacement)
    );
  } catch (error) {
    fail(`could not read the frontend bundle (${error.code || error.message})`);
  }
  if (!alreadyApplied) {
    fail('frontend bundle does not contain the public URL placeholder');
  }
  replacements = alreadyApplied;
}

try {
  await access('/app/.env', constants.F_OK);
} catch {
  const handle = await open('/app/.env', 'w', 0o600);
  await handle.close();
}

console.log(
  `fuqn runtime config applied for ${frontend.origin} (${replacements} frontend placeholder replacements)`
);
