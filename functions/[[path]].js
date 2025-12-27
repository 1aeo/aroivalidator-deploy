/**
 * Cloudflare Pages Function - Multi-Storage Data Proxy
 * Serves JSON/archive files from DO Spaces (primary) with R2 fallback.
 * Static assets (HTML/CSS/JS) pass through to Pages.
 */

// Cache TTLs in seconds
const TTL = { latest: 60, historical: 31536000, default: 300 };

// Security: Pattern to detect traversal attempts (encoded or raw)
const UNSAFE_PATH = /(?:^|\/)\.\.(?:\/|$)|%2e|%00|\x00/i;

// Valid proxy paths pattern
const PROXY_PATH = /^(?:archives\/.*\.tar\.gz|.*\.json)$/;

const getPath = (params) => {
  const p = Array.isArray(params.path) ? params.path.join('/') : (params.path || '');
  // Normalize: remove leading slash and empty/dot segments in one pass
  const cleaned = p.replace(/^\/+/, '').split('/').filter(s => s && s !== '.').join('/');
  // Security: reject paths with traversal attempts
  return UNSAFE_PATH.test(cleaned) ? '' : cleaned;
};

const shouldProxy = (path) => path && PROXY_PATH.test(path);

const isImmutable = (path) => path[0] === 'a';  // 'aroi_validation_*' or 'archives/*'

const getCacheTTL = (path, env) => {
  if (path === 'latest.json' || path === 'files.json') 
    return parseInt(env.CACHE_TTL_LATEST) || TTL.latest;
  return isImmutable(path) ? (parseInt(env.CACHE_TTL_HISTORICAL) || TTL.historical) : TTL.default;
};

const makeResponse = (body, path, source, ttl) => {
  const immutable = isImmutable(path);
  const cacheControl = `public, max-age=${ttl}${immutable ? ', immutable' : ''}`;
  return new Response(body, {
    headers: {
      'Content-Type': path.endsWith('.json') ? 'application/json' : 'application/octet-stream',
      'Cache-Control': cacheControl,
      'CDN-Cache-Control': cacheControl,
      'X-Served-From': source,
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
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

  // Security: Don't leak requested path in error messages
  return new Response('Not Found', { 
    status: 404, 
    headers: { 'Content-Type': 'text/plain' }
  });
}
