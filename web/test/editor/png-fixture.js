import { deflateSync } from 'node:zlib';
export function pngChunk(type, data) {
  const contents = Buffer.concat([Buffer.from(type), data]);
  let crc = 0xffffffff;
  for (const byte of contents) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  const header = Buffer.alloc(4), tail = Buffer.alloc(4);
  header.writeUInt32BE(data.length); tail.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([header, contents, tail]);
}
export function png16({ width, height, gray = false, interlaced = false, sample, chunks = [] }) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width); header.writeUInt32BE(height, 4);
  header[8] = 16; header[9] = gray ? 4 : 6; header[12] = +interlaced;
  const rows = [], channels = gray ? 2 : 4;
  const passes = interlaced ? [[0,0,8,8],[4,0,8,8],[0,4,4,8],[2,0,4,4],[0,2,2,4],[1,0,2,2],[0,1,1,2]] : [[0,0,1,1]];
  for (const [x0,y0,dx,dy] of passes) {
    if (x0 >= width) continue;
    for (let y = y0; y < height; y += dy) {
      const row = Buffer.alloc(1 + Math.ceil((width - x0) / dx) * channels * 2);
      let i = 1;
      for (let x = x0; x < width; x += dx) for (const value of sample(x, y)) {
        row.writeUInt16BE(value, i); i += 2;
      }
      rows.push(row);
    }
  }
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), pngChunk('IHDR', header),
    ...chunks.map(([type, data]) => pngChunk(type, data)),
    pngChunk('IDAT', deflateSync(Buffer.concat(rows))), pngChunk('IEND', Buffer.alloc(0))]);
}
