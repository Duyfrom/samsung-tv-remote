'use strict';

class RestError extends Error {
  constructor(status) {
    super(`TV answered HTTP ${status}.`);
    this.name = 'RestError';
    this.status = status;
  }
}

async function getJSON(url, timeout) {
  const res = await fetch(url, { signal: AbortSignal.timeout(timeout) });
  if (!res.ok) throw new RestError(res.status);
  return res.json();
}

/** `GET http://<tv>:8001/api/v2/` – the Multiscreen device description. */
async function info(host, { timeout = 3000, port = 8001 } = {}) {
  const json = await getJSON(`http://${host}:${port}/api/v2/`, timeout);
  const d = json.device || {};
  return {
    name: String(d.name || json.name || 'Samsung TV').replace('[TV] ', ''),
    type: d.type || json.type || null, // 'Samsung SmartTV' for real TVs
    modelName: d.modelName || '',
    model: d.model || null, // platform code, e.g. 16_HAWKM_FHD – leading digits are the model year
    wifiMac: d.wifiMac || null,
    ip: d.ip || null,
    networkType: d.networkType || null,
    resolution: d.resolution || null,
    os: d.OS || null,
    tokenAuthSupport: d.TokenAuthSupport === 'true', // true: wss :8002 with a token
    powerState: d.PowerState || null, // 2017+ firmwares only
  };
}

/** Status of a Smart Hub web app; `null` when it isn't installed. */
async function appStatus(host, id, { timeout = 2000, port = 8001 } = {}) {
  try {
    const d = await getJSON(`http://${host}:${port}/api/v2/applications/${encodeURIComponent(id)}`, timeout);
    return { id: d.id || id, name: d.name || id, running: !!d.running, visible: !!d.visible };
  } catch (err) {
    if (err instanceof RestError && err.status === 404) return null;
    throw err;
  }
}

module.exports = { info, appStatus, RestError };
