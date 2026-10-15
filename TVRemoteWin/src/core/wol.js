'use strict';

const dgram = require('node:dgram');
const os = require('node:os');
const { execFile } = require('node:child_process');

function magicPacket(mac) {
  const bytes = String(mac).split(/[:-]/).map((x) => parseInt(x, 16));
  if (bytes.length !== 6 || bytes.some((b) => Number.isNaN(b) || b < 0 || b > 255)) {
    throw new Error(`"${mac}" is not a MAC address.`);
  }
  return Buffer.concat([Buffer.alloc(6, 0xff), ...Array.from({ length: 16 }, () => Buffer.from(bytes))]);
}

function broadcastOf(address, netmask) {
  const a = address.split('.').map(Number);
  const m = netmask.split('.').map(Number);
  return a.map((x, i) => (x | (~m[i] & 0xff))).join('.');
}

function sendFrom(localAddress, packet, targets) {
  return new Promise((resolve) => {
    const socket = dgram.createSocket('udp4');
    let sent = 0;
    socket.on('error', () => { try { socket.close(); } catch { /* ignore */ } resolve(sent); });
    socket.bind(0, localAddress, () => {
      socket.setBroadcast(true);
      let left = targets.length * 2;
      for (const target of targets) {
        for (const port of [9, 7]) {
          socket.send(packet, port, target, (err) => {
            if (!err) sent++;
            if (--left === 0) { try { socket.close(); } catch { /* ignore */ } resolve(sent); }
          });
        }
      }
    });
  });
}

/**
 * Magic packet sender. On Windows with several adapters (Wi-Fi, Ethernet, VPN, virtual switches) a single
 * 255.255.255.255 send goes out one arbitrary adapter, so it is sent from every IPv4 interface with that
 * interface's directed broadcast, plus a unicast to the TV's address.
 */
async function wake(mac, host) {
  const packet = magicPacket(mac);
  let sent = 0;
  for (const addrs of Object.values(os.networkInterfaces())) {
    for (const a of addrs || []) {
      if (a.family !== 'IPv4' || a.internal || a.address.startsWith('169.254.')) continue;
      const targets = ['255.255.255.255', broadcastOf(a.address, a.netmask)];
      if (host) targets.push(host);
      sent += await sendFrom(a.address, packet, [...new Set(targets)]);
    }
  }
  if (sent === 0) throw new Error('Could not send the wake packet (no usable network adapter).');
  return sent;
}

/** MAC from an `arp -a <ip>` line on Windows (`f8-77-b8-bf-df-bb`) or macOS/Linux (`f8:77:b8:bf:df:bb`, maybe `8:0:...`). */
function parseArp(output, host) {
  for (const line of String(output).split(/\r?\n/)) {
    if (host && !new RegExp(`(^|[\\s(])${host.replace(/\./g, '\\.')}([\\s)]|$)`).test(line)) continue;
    const m = /\b([0-9a-f]{1,2}(?:[:-][0-9a-f]{1,2}){5})\b/i.exec(line);
    if (m) {
      const parts = m[1].split(/[:-]/).map((p) => p.padStart(2, '0'));
      if (parts.every((p) => p === 'ff') || parts.every((p) => p === '00')) continue;
      return parts.join(':').toUpperCase();
    }
  }
  return null;
}

/** MAC address of a host from the system ARP cache (populated by any recent traffic to it). */
function macAddress(host) {
  return new Promise((resolve) => {
    execFile('arp', process.platform === 'win32' ? ['-a', host] : ['-n', host], { timeout: 3000, windowsHide: true },
      (err, stdout) => resolve(err ? null : parseArp(stdout, host)));
  });
}

module.exports = { wake, magicPacket, parseArp, macAddress, broadcastOf };
