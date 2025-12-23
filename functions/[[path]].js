/**
 * Cloudflare Pages Function - Multi-Storage Data Proxy
 * Serves JSON/archive files from DO Spaces (primary) with R2 fallback.
 * Static assets (HTML/CSS/JS) pass through to Pages.
 */

// Cache TTLs in seconds
const TTL = {
  latest: 60,           // latest.json, files.json - updates hourly
  historical: 31536000, // 1 year - immutable timestamped files
  default: 300,
};

const getPath = (params) => {
  const p = Array.isArray(params.path) ? params.path.join('/') : (params.path || '');
  return p.startsWith('/') ? p.slice(1) : p;
};

const shouldProxy = (path) => 
  path.endsWith('.json') || path.endsWith('.tar.gz') || path.startsWith('archives/');

const isImmutable = (path) =>
  path.startsWith('aroi_validation_') || path.startsWith('archives/');

const getCacheTTL = (path, env) => {
  if (path === 'latest.json' || path === 'files.json') 
    return parseInt(env.CACHE_TTL_LATEST) || TTL.latest;
  if (isImmutable(path))
    return parseInt(env.CACHE_TTL_HISTORICAL) || TTL.historical;
  return TTL.default;
};

const makeResponse = (body, path, source, ttl) => {
  const immutable = isImmutable(path);
  return new Response(body, {
    headers: {
      'Content-Type': path.endsWith('.json') ? 'application/json' : 'application/octet-stream',
      'Cache-Control': immutable 
        ? `public, max-age=${ttl}, immutable` 
        : `public, max-age=${ttl}`,
      'CDN-Cache-Control': immutable
        ? `public, max-age=${ttl}, immutable`
        : `public, max-age=${ttl}`,
      'X-Served-From': source,
      'X-Immutable': immutable ? 'true' : 'false',
      'Access-Control-Allow-Origin': '*',
    },
  });
};

const fetchDO = async (env, path, ttl) => {
  if (!env.DO_SPACES_URL) return null;
  try {
    const res = await fetch(`${env.DO_SPACES_URL.replace(/\/$/, '')}/${path}`);
    return res.ok ? makeResponse(res.body, path, 'digitalocean-spaces', ttl) : null;
  } catch { return null; }
};

const fetchR2 = async (env, path, ttl) => {
  if (!env.AROI_BUCKET) return null;
  try {
    const obj = await env.AROI_BUCKET.get(path);
    return obj ? makeResponse(obj.body, path, 'cloudflare-r2', ttl) : null;
  } catch { return null; }
};

export async function onRequest({ request, env, params, next, waitUntil }) {
  const path = getPath(params);
  if (!shouldProxy(path)) return next();

  const cache = caches.default;
  const cacheKey = new Request(new URL(request.url).origin + '/' + path);
  const cached = await cache.match(cacheKey);
  if (cached) {
    const res = new Response(cached.body, cached);
    res.headers.set('X-Cache-Status', 'HIT');
    return res;
  }

  const ttl = getCacheTTL(path, env);
  const order = (env.STORAGE_ORDER || 'do,r2').split(',').map(s => s.trim());
  
  for (const backend of order) {
    const res = backend === 'do' ? await fetchDO(env, path, ttl) : 
                backend === 'r2' ? await fetchR2(env, path, ttl) : null;
    if (res) {
      waitUntil(cache.put(cacheKey, res.clone()));
      res.headers.set('X-Cache-Status', 'MISS');
      return res;
    }
  }

  return new Response(`Not Found: ${path}`, { 
    status: 404, 
    headers: { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': '*' }
  });
}
