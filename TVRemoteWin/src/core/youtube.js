'use strict';

const { TVError } = require('./errors');

/**
 * DIAL – the protocol phones use to "cast" to the YouTube app: the TV advertises an Application-URL and
 * accepts a POST with the launch payload. On the 2016 Tizen YouTube app this is the only launch path that
 * carries a video; the websocket DEEP_LINK launch drops its metaTag.
 */
async function applicationURL(host) {
  const fallback = `http://${host}:8080/ws/app/`;
  try {
    const res = await fetch(`http://${host}:7678/nservice/`, { signal: AbortSignal.timeout(2000) });
    const value = res.headers.get('application-url');
    if (value && new URL(value).hostname === host) return value.endsWith('/') ? value : `${value}/`;
  } catch { /* use the usual address */ }
  return fallback;
}

/** POSTs `payload` (e.g. `v=<videoId>&t=0`) to the DIAL app; the TV answers 201 and (re)starts it. */
async function dialLaunch(host, app, payload) {
  const res = await fetch(`${await applicationURL(host)}${app}`, {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    body: payload,
    signal: AbortSignal.timeout(8000),
  });
  if (![200, 201].includes(res.status)) {
    throw new TVError(res.status === 404 ? `The TV has no “${app}” app.` : `The TV refused the launch (HTTP ${res.status}).`);
  }
}

const isVideoID = (x) => /^[A-Za-z0-9_-]{11}$/.test(x);

/** 11-character video id from a bare id, a watch URL, youtu.be, shorts, embed or live link. */
function videoID(input) {
  const s = String(input || '').trim();
  if (isVideoID(s)) return s;
  let url;
  try { url = new URL(/^[a-z]+:\/\//i.test(s) ? s : `https://${s}`); } catch { return null; }
  const v = url.searchParams.get('v');
  if (v && isVideoID(v)) return v;
  const parts = url.pathname.split('/').filter(Boolean);
  if (url.hostname.includes('youtu.be') && parts[0] && isVideoID(parts[0])) return parts[0];
  const i = parts.findIndex((p) => ['shorts', 'embed', 'live', 'v'].includes(p));
  if (i >= 0 && parts[i + 1] && isVideoID(parts[i + 1])) return parts[i + 1];
  return null;
}

const unescapeXML = (s) => s.replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'")
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
const first = (re, text) => (re.exec(text) || [])[1];

/** Newest regular upload (Shorts skipped) from a channel's RSS feed XML. */
function latestFromFeed(xml, fallbackChannel = '') {
  const [head, ...entries] = xml.split('<entry>');
  const channel = unescapeXML(first(/<title>([^<]*)<\/title>/, head) || fallbackChannel);
  for (const entry of entries) {
    if (entry.includes('/shorts/')) continue;
    const id = first(/<yt:videoId>([^<]+)<\/yt:videoId>/, entry);
    if (!id) continue;
    return {
      id,
      title: unescapeXML(first(/<title>([^<]*)<\/title>/, entry) || id),
      channel,
      published: (first(/<published>([^<]+)<\/published>/, entry) || '').slice(0, 10),
    };
  }
  return null;
}

const FETCH_OPTIONS = {
  headers: { 'Accept-Language': 'en-US,en;q=0.9', Cookie: 'CONSENT=YES+1', 'User-Agent': 'Mozilla/5.0' },
  signal: undefined,
};
const get = (url) => fetch(url, { ...FETCH_OPTIONS, signal: AbortSignal.timeout(10_000) });

/** Accepts a channel id (`UC…`), an `@handle`, a channel/handle URL, or a plain name used as the handle. */
async function channelID(query) {
  const q = String(query || '').trim();
  const direct = first(/(UC[\w-]{22})/, q);
  if (direct) return direct;
  let handle = first(/(@[\w.-]+)/, q);
  if (!handle) {
    const simple = q.toLowerCase().replace(/[^\p{L}\p{N}_.-]/gu, '');
    handle = simple ? `@${simple}` : null;
  }
  if (!handle) throw new TVError('Which channel? Give an @handle such as @mkbhd.');
  const res = await get(`https://www.youtube.com/${encodeURI(handle)}`);
  if (!res.ok) throw new TVError(`No YouTube channel ${handle}. Give the channel's @handle, its id, or a video URL.`);
  const html = await res.text();
  const id = first(/channel_id=(UC[\w-]{22})/, html) || first(/"externalId":"(UC[\w-]{22})"/, html);
  if (!id) throw new TVError(`Couldn't read the channel id for ${handle}.`);
  return id;
}

async function latestVideo(channel) {
  const id = await channelID(channel);
  const res = await get(`https://www.youtube.com/feeds/videos.xml?channel_id=${id}`);
  if (!res.ok) throw new TVError(`YouTube's feed for that channel answered HTTP ${res.status}.`);
  const video = latestFromFeed(await res.text(), channel);
  if (!video) throw new TVError(`No videos found for “${channel}”.`);
  return video;
}

module.exports = { dialLaunch, applicationURL, videoID, latestFromFeed, latestVideo, channelID };
