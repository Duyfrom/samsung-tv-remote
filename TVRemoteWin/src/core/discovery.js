'use strict';

const os = require('node:os');
const rest = require('./rest');

/** Every other address in the /24 of each active, non-loopback IPv4 interface. */
function localSubnetHosts() {
  const hosts = new Set();
  for (const addrs of Object.values(os.networkInterfaces())) {
    for (const a of addrs || []) {
      if (a.family !== 'IPv4' || a.internal || a.address.startsWith('169.254.')) continue;
      const base = a.address.split('.').slice(0, 3).join('.');
      for (let i = 1; i <= 254; i++) if (`${base}.${i}` !== a.address) hosts.add(`${base}.${i}`);
    }
  }
  return [...hosts];
}

/**
 * Finds TVs by asking every address on the local /24 for the `/api/v2/` device description. Samsung's own
 * clients use SSDP first, but the TV drops multicast while busy and a direct sweep verifies the API too.
 * Port 8001 is a common dev-server port, so only devices that say they are Samsung TVs are accepted.
 */
async function scan({ timeout = 1500, concurrency = 64 } = {}) {
  const queue = localSubnetHosts();
  const found = [];
  async function worker() {
    for (let host = queue.pop(); host; host = queue.pop()) {
      try {
        const i = await rest.info(host, { timeout });
        if (i.type === 'Samsung SmartTV') found.push({ host, name: i.name, modelName: i.modelName, wifiMac: i.wifiMac });
      } catch { /* not a TV */ }
    }
  }
  await Promise.all(Array.from({ length: concurrency }, worker));
  return found.sort((a, b) => a.host.localeCompare(b.host, undefined, { numeric: true }));
}

module.exports = { scan, localSubnetHosts };
