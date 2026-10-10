import { decodeUtf8Compat, encodeUtf8Compat } from '../TextEncodingCompat';

// Wire layout follows OpenHarmony developtools_hdc's session.h/serial_struct.h.
// This is the device-facing protocol, not the PC hdc server's port 8710 protocol.
export enum HdcCommand {
  Handshake = 1,
  ChannelClose = 2,
  Echo = 9,
  EchoRaw = 10,
  Execute = 1001
}

export enum HdcAuth {
  None = 0,
  Token = 1,
  Signature = 2,
  PublicKey = 3,
  Ok = 4,
  Fail = 5,
  TlsPsk = 6
}

export interface HdcPacket {
  channel: number;
  command: number;
  data: Uint8Array;
}

export interface HdcHandshake {
  banner: string;
  auth: number;
  session: number;
  target: string;
  data: Uint8Array;
  version: string;
}

class WireField {
  id: number = 0;
  wire: number = 0;
  number: number = 0;
  bytes: Uint8Array = new Uint8Array(0);
}

class WireReader {
  private offset: number = 0;
  private bytes: Uint8Array;
  constructor(bytes: Uint8Array) { this.bytes = bytes; }

  private varint(): number {
    let result = 0;
    for (let shift = 0; shift <= 28; shift += 7) {
      if (this.offset >= this.bytes.length) {
        throw new Error('HDC_PROTO: truncated varint');
      }
      let value = this.bytes[this.offset++];
      result += (value & 127) * Math.pow(2, shift);
      if (result > 0xFFFFFFFF) {
        throw new Error('HDC_PROTO: uint32 overflow');
      }
      if (value < 128) {
        return result;
      }
    }
    throw new Error('HDC_PROTO: invalid varint');
  }

  fields(): WireField[] {
    let result: WireField[] = [];
    while (this.offset < this.bytes.length) {
      let tag = this.varint();
      let field = new WireField();
      field.id = Math.floor(tag / 8);
      if (field.id === 0) {
        throw new Error('HDC_PROTO: zero field id');
      }
      let wire = tag % 8;
      field.wire = wire;
      if (wire === 0) {
        field.number = this.varint();
      } else {
        let length = wire === 2 ? this.varint() : (wire === 1 ? 8 : (wire === 5 ? 4 : -1));
        if (length < 0 || length > this.bytes.length - this.offset) {
          throw new Error('HDC_PROTO: invalid field length/type');
        }
        field.bytes = this.bytes.slice(this.offset, this.offset + length);
        this.offset += length;
      }
      result.push(field);
    }
    return result;
  }
}

class WireWriter {
  private bytes: number[] = [];
  private varint(value: number): void {
    if (!Number.isInteger(value) || value < 0 || value > 0xFFFFFFFF) {
      throw new Error('HDC_PROTO: invalid uint32');
    }
    do {
      let next = value % 128;
      value = Math.floor(value / 128);
      this.bytes.push(next + (value > 0 ? 128 : 0));
    } while (value > 0);
  }
  number(id: number, value: number): void {
    this.varint(id * 8);
    this.varint(value);
  }
  data(id: number, bytes: Uint8Array): void {
    this.varint(id * 8 + 2);
    this.varint(bytes.length);
    for (let index = 0; index < bytes.length; index++) {
      this.bytes.push(bytes[index]);
    }
  }
  finish(): Uint8Array {
    return new Uint8Array(this.bytes);
  }
}

export function joinHdcBytes(parts: Uint8Array[]): Uint8Array {
  let size = 0;
  parts.forEach((part: Uint8Array): void => { size += part.length; });
  let result = new Uint8Array(size);
  let offset = 0;
  parts.forEach((part: Uint8Array): void => {
    result.set(part, offset);
    offset += part.length;
  });
  return result;
}

export function encodeHdcHandshake(handshake: HdcHandshake): Uint8Array {
  let writer = new WireWriter();
  writer.data(1, encodeUtf8Compat(handshake.banner));
  writer.number(2, handshake.auth);
  writer.number(3, handshake.session);
  writer.data(4, encodeUtf8Compat(handshake.target));
  writer.data(5, handshake.data);
  writer.data(6, encodeUtf8Compat(handshake.version));
  return writer.finish();
}

export function decodeHdcHandshake(bytes: Uint8Array): HdcHandshake {
  let result: HdcHandshake = {
    banner: '', auth: 0, session: 0, target: '', data: new Uint8Array(0), version: ''
  };
  new WireReader(bytes).fields().forEach((field: WireField): void => {
    if (field.id <= 6 && field.wire !== (field.id === 2 || field.id === 3 ? 0 : 2)) {
      throw new Error('HDC_PROTO: wrong handshake field type');
    }
    switch (field.id) {
      case 1: result.banner = decodeUtf8Compat(field.bytes); break;
      case 2: result.auth = field.number; break;
      case 3: result.session = field.number; break;
      case 4: result.target = decodeUtf8Compat(field.bytes); break;
      case 5: result.data = field.bytes; break;
      case 6: result.version = decodeUtf8Compat(field.bytes); break;
    }
  });
  return result;
}

export function encodeHdcTlv(tag: string, value: string): Uint8Array {
  let bytes = encodeUtf8Compat(value);
  if (tag.length > 16 || String(bytes.length).length > 16) {
    throw new Error('HDC_PROTO: TLV header too long');
  }
  return joinHdcBytes([encodeUtf8Compat(tag.padEnd(16, ' ') + String(bytes.length).padEnd(16, ' ')), bytes]);
}

export function decodeHdcTlv(bytes: Uint8Array): Map<string, string> {
  let result = new Map<string, string>();
  let offset = 0;
  while (offset < bytes.length) {
    if (bytes.length - offset < 32) {
      throw new Error('HDC_PROTO: truncated TLV');
    }
    let tag = decodeUtf8Compat(bytes.slice(offset, offset + 16)).trim();
    let lengthText = decodeUtf8Compat(bytes.slice(offset + 16, offset + 32)).trim();
    if (!/^\d+$/.test(lengthText) || tag.length === 0) {
      throw new Error('HDC_PROTO: invalid TLV');
    }
    let length = Number(lengthText);
    offset += 32;
    if (!Number.isSafeInteger(length) || length > bytes.length - offset) {
      throw new Error('HDC_PROTO: invalid TLV length');
    }
    result.set(tag, decodeUtf8Compat(bytes.slice(offset, offset + length)));
    offset += length;
  }
  return result;
}

export function encodeHdcPacket(packet: HdcPacket): Uint8Array {
  let writer = new WireWriter();
  writer.number(1, packet.channel);
  writer.number(2, packet.command);
  writer.number(3, 0); // Official default disables the optional IO checksum.
  writer.number(4, 9);
  let protect = writer.finish();
  let head = new Uint8Array(11);
  head[0] = 72;
  head[1] = 87;
  head[4] = 1;
  let view = new DataView(head.buffer);
  view.setUint16(5, protect.length, false);
  view.setUint32(7, packet.data.length, false);
  return joinHdcBytes([head, protect, packet.data]);
}

export class HdcPacketStream {
  private pending: Uint8Array = new Uint8Array(0);

  feed(bytes: Uint8Array): HdcPacket[] {
    // Bound a single frame and incoming batch. Shell output is streamed separately.
    if (this.pending.length + bytes.length > 4 * 1024 * 1024) {
      throw new Error('HDC_PROTO: receive buffer exceeds 4 MiB');
    }
    this.pending = joinHdcBytes([this.pending, bytes]);
    let packets: HdcPacket[] = [];
    let offset = 0;
    while (this.pending.length - offset >= 11) {
      let head = this.pending.slice(offset, offset + 11);
      if (head[0] !== 72 || head[1] !== 87 || head[4] !== 1) {
        throw new Error('HDC_PROTO: wrong magic/version; use the wireless HDC device port');
      }
      if (head[2] !== 0 || head[3] !== 0) {
        throw new Error('HDC_PROTO: unsupported reserved/encryption flags');
      }
      let view = new DataView(head.buffer);
      let protectSize = view.getUint16(5, false);
      let dataSize = view.getUint32(7, false);
      if (protectSize === 0 || protectSize > 1024 || dataSize > 2 * 1024 * 1024) {
        throw new Error('HDC_PROTO: invalid frame size');
      }
      let total = 11 + protectSize + dataSize;
      if (this.pending.length - offset < total) {
        break;
      }
      let channel = 0;
      let command = 0;
      let checksum = 0;
      let vcode = 0;
      new WireReader(this.pending.slice(offset + 11, offset + 11 + protectSize)).fields()
        .forEach((field: WireField): void => {
          if (field.id <= 4 && field.wire !== 0) { throw new Error('HDC_PROTO: wrong protection field type'); }
          switch (field.id) {
            case 1: channel = field.number; break;
            case 2: command = field.number; break;
            case 3: checksum = field.number; break;
            case 4: vcode = field.number; break;
          }
        });
      if (vcode !== 9 || command === 0) {
        throw new Error('HDC_PROTO: invalid payload protection');
      }
      let data = this.pending.slice(offset + 11 + protectSize, offset + total);
      if (checksum !== 0) {
        let sum = 0;
        data.forEach((value: number): void => { sum = (sum + value) % 256; });
        if (sum !== checksum) {
          throw new Error('HDC_PROTO: checksum mismatch');
        }
      }
      packets.push({ channel: channel, command: command, data: data });
      offset += total;
    }
    this.pending = this.pending.slice(offset);
    return packets;
  }
}

export function isHdcAuthPending(message: string): boolean {
  return message.indexOf('[E000002]') >= 0;
}
