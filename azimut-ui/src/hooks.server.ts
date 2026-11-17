/**
 * SvelteKit server hooks — inject security headers on every response.
 *
 * Headers set here:
 *   X-Frame-Options           — prevents clickjacking (DENY)
 *   X-Content-Type-Options    — prevents MIME-type sniffing
 *   Referrer-Policy           — limits Referer leakage to same-origin
 *   Permissions-Policy        — disables unused browser features
 *   Content-Security-Policy   — restricts resource origins
 *
 * NOTE: The CSP `connect-src` directive includes 'self' plus a ws:/wss:
 * wildcard so that the WebSocket connection to the metrics stream works in
 * all environments (dev on ws://localhost, prod on wss://azimutcp.*).
 * Tighten the ws: origin to your own domain once the domain is stable.
 */

import type { Handle } from '@sveltejs/kit';

export const handle: Handle = async ({ event, resolve }) => {
  const response = await resolve(event);

  // ── Clickjacking protection ─────────────────────────────────────────────────
  response.headers.set('X-Frame-Options', 'DENY');

  // ── MIME-type sniffing protection ───────────────────────────────────────────
  response.headers.set('X-Content-Type-Options', 'nosniff');

  // ── Referrer policy ─────────────────────────────────────────────────────────
  response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');

  // ── Feature / Permissions policy ────────────────────────────────────────────
  response.headers.set(
    'Permissions-Policy',
    'camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()',
  );

  // ── Cache policy ────────────────────────────────────────────────────────────
  // HTML must never be cached: a cached SPA shell references hashed assets from
  // the build it was generated with, so after an upgrade the browser would load
  // stale HTML and 404 on the new JS/CSS. Assets themselves are immutable and
  // hashed, so they can stay cacheable.
  const contentType = response.headers.get('content-type') ?? '';
  if (contentType.includes('text/html')) {
    response.headers.set('Cache-Control', 'no-store, must-revalidate');
  }
  if (event.url.pathname === '/sw.js') {
    response.headers.set('Cache-Control', 'no-cache');
  }

  // ── Content-Security-Policy ──────────────────────────────────────────────────
  // Directives are intentionally strict for a server-admin control panel:
  //   • No inline scripts or styles unless explicitly allowed via nonces (not
  //     yet in use — add nonce support when SvelteKit gains first-class CSP nonce API)
  //   • Images and fonts from self only
  //   • API calls restricted to same-origin (plus ws:/wss: for live metrics)
  //   • No <object>, <embed>, or <base> elements allowed
  const csp = [
    "default-src 'self'",
    // SvelteKit inlines a small hydration script; 'unsafe-inline' is required
    // until SvelteKit's built-in CSP nonce support is wired in.
    // static.cloudflareinsights.com: Cloudflare auto-injects its RUM beacon when proxied.
    "script-src 'self' 'unsafe-inline' https://static.cloudflareinsights.com",
    // SvelteKit also inlines critical CSS; same caveat applies.
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self' data:",
    // WebSocket for live server metrics stream
    "connect-src 'self' ws: wss:",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    // Only meaningful over HTTPS; adding it to an HTTP-only panel can make the
    // browser upgrade asset requests to https:// and break the UI.
    ...(event.url.protocol === 'https:' ? ['upgrade-insecure-requests'] : []),
  ].join('; ');

  response.headers.set('Content-Security-Policy', csp);

  return response;
};
