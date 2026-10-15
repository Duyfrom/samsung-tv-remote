'use strict';

const SERVICE = 'urn:schemas-upnp-org:service:RenderingControl:1';

function valueOf(tag, xml) {
  const m = new RegExp(`<${tag}>\\s*([^<]*?)\\s*</${tag}>`).exec(xml);
  return m ? m[1] : null;
}

/**
 * UPnP RenderingControl on the TV's DLNA renderer (`http://<tv>:9197/dmr`). The remote channel only has
 * relative volume keys; this gives absolute volume and mute state for the slider.
 */
class RenderingControl {
  constructor(host, { port = 9197, controlPath = '/upnp/control/RenderingControl1' } = {}) {
    this.url = `http://${host}:${port}${controlPath}`;
  }

  async volume() {
    const v = parseInt(valueOf('CurrentVolume', await this._call('GetVolume')), 10);
    if (Number.isNaN(v)) throw new Error('Unexpected answer from the TV.');
    return v;
  }

  async setVolume(level) {
    await this._call('SetVolume', `<DesiredVolume>${Math.max(0, Math.min(100, Math.round(level)))}</DesiredVolume>`);
  }

  async isMuted() {
    return valueOf('CurrentMute', await this._call('GetMute')) === '1';
  }

  async setMute(muted) {
    await this._call('SetMute', `<DesiredMute>${muted ? 1 : 0}</DesiredMute>`);
  }

  async _call(action, args = '') {
    const body = '<?xml version="1.0" encoding="utf-8"?>'
      + '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      + `<s:Body><u:${action} xmlns:u="${SERVICE}"><InstanceID>0</InstanceID><Channel>Master</Channel>${args}</u:${action}></s:Body></s:Envelope>`;
    const res = await fetch(this.url, {
      method: 'POST',
      headers: { 'Content-Type': 'text/xml; charset="utf-8"', SOAPACTION: `"${SERVICE}#${action}"` },
      body,
      signal: AbortSignal.timeout(3000),
    });
    if (!res.ok) throw new Error(`TV answered HTTP ${res.status}.`);
    return res.text();
  }
}

module.exports = { RenderingControl, valueOf };
