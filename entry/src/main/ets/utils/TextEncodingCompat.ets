export function encodeUtf8Compat(value: string): Uint8Array {
  return encodeUtf8Manually(value);
}

export function decodeUtf8Compat(bytes: Uint8Array): string {
  let output: string[] = [];
  let segment: string[] = [];
  let index = 0;
  while (index < bytes.length) {
    let first = bytes[index];
    if (first <= 0x7F) {
      segment.push(String.fromCharCode(first));
      if (segment.length >= 8192) {
        output.push(segment.join(''));
        segment = [];
      }
      index++;
      continue;
    }

    let codePoint = 0xFFFD;
    if (first >= 0xC2 && first <= 0xDF && index + 1 < bytes.length) {
      let second = bytes[index + 1];
      if (isContinuationByte(second)) {
        codePoint = ((first & 0x1F) << 6) | (second & 0x3F);
        index += 2;
      } else {
        index++;
      }
    } else if (first >= 0xE0 && first <= 0xEF && index + 2 < bytes.length) {
      let second = bytes[index + 1];
      let third = bytes[index + 2];
      if (isContinuationByte(second) && isContinuationByte(third)) {
        codePoint = ((first & 0x0F) << 12) | ((second & 0x3F) << 6) | (third & 0x3F);
        index += 3;
      } else {
        index++;
      }
    } else if (first >= 0xF0 && first <= 0xF4 && index + 3 < bytes.length) {
      let second = bytes[index + 1];
      let third = bytes[index + 2];
      let fourth = bytes[index + 3];
      if (isContinuationByte(second) && isContinuationByte(third) && isContinuationByte(fourth)) {
        codePoint = ((first & 0x07) << 18) | ((second & 0x3F) << 12) | ((third & 0x3F) << 6) | (fourth & 0x3F);
        index += 4;
      } else {
        index++;
      }
    } else {
      index++;
    }

    appendDecodedCodePoint(segment, codePoint);
    if (segment.length >= 8192) {
      output.push(segment.join(''));
      segment = [];
    }
  }
  if (segment.length > 0) {
    output.push(segment.join(''));
  }
  return output.join('');
}

function encodeUtf8Manually(value: string): Uint8Array {
  let bytes = new Uint8Array(utf8ByteLength(value));
  let offset = 0;
  for (let index = 0; index < value.length; index++) {
    let codePoint = value.charCodeAt(index);
    if (codePoint >= 0xD800 && codePoint <= 0xDBFF && index + 1 < value.length) {
      let next = value.charCodeAt(index + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        codePoint = 0x10000 + ((codePoint - 0xD800) * 0x400) + (next - 0xDC00);
        index++;
      }
    }
    offset = writeUtf8CodePoint(bytes, offset, codePoint);
  }
  return bytes;
}

function utf8ByteLength(value: string): number {
  let length = 0;
  for (let index = 0; index < value.length; index++) {
    let codePoint = value.charCodeAt(index);
    if (codePoint >= 0xD800 && codePoint <= 0xDBFF && index + 1 < value.length) {
      let next = value.charCodeAt(index + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        codePoint = 0x10000 + ((codePoint - 0xD800) * 0x400) + (next - 0xDC00);
        index++;
      }
    }
    length += utf8CodePointLength(codePoint);
  }
  return length;
}

function utf8CodePointLength(codePoint: number): number {
  if (codePoint <= 0x7F) {
    return 1;
  }
  if (codePoint <= 0x7FF) {
    return 2;
  }
  if (codePoint <= 0xFFFF) {
    return 3;
  }
  return 4;
}

function writeUtf8CodePoint(bytes: Uint8Array, offset: number, codePoint: number): number {
  if (codePoint <= 0x7F) {
    bytes[offset] = codePoint;
    return offset + 1;
  }
  if (codePoint <= 0x7FF) {
    bytes[offset] = 0xC0 | (codePoint >> 6);
    bytes[offset + 1] = 0x80 | (codePoint & 0x3F);
    return offset + 2;
  }
  if (codePoint <= 0xFFFF) {
    bytes[offset] = 0xE0 | (codePoint >> 12);
    bytes[offset + 1] = 0x80 | ((codePoint >> 6) & 0x3F);
    bytes[offset + 2] = 0x80 | (codePoint & 0x3F);
    return offset + 3;
  }
  bytes[offset] = 0xF0 | (codePoint >> 18);
  bytes[offset + 1] = 0x80 | ((codePoint >> 12) & 0x3F);
  bytes[offset + 2] = 0x80 | ((codePoint >> 6) & 0x3F);
  bytes[offset + 3] = 0x80 | (codePoint & 0x3F);
  return offset + 4;
}

function isContinuationByte(value: number): boolean {
  return (value & 0xC0) === 0x80;
}

function appendDecodedCodePoint(output: string[], codePoint: number): void {
  if (codePoint <= 0xFFFF) {
    output.push(String.fromCharCode(codePoint));
    return;
  }
  let adjusted = codePoint - 0x10000;
  output.push(String.fromCharCode(0xD800 + (adjusted >> 10)));
  output.push(String.fromCharCode(0xDC00 + (adjusted & 0x3FF)));
}
