// Project-authored DNGs; generated files remain in ignored build output.
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { makeDNG } from '../web/test/editor/raw-fixture.js'

const root = process.argv[2]
if (!root) throw new Error('Pass an output directory')
mkdirSync(root, { recursive: true })
const save = (name, options = {}) => writeFileSync(join(root, name), makeDNG(options))
for (let orientation = 1; orientation <= 8; orientation++) {
  save(`orientation-${orientation}`, { width: 320, height: 192, orientation, mosaic: false })
  save(`crop-${orientation}`, { width: 320, height: 192, orientation, mosaic: false,
    extraTags: [[50719, 5, [11, 7]], [50720, 5, [282, 166]]] })
}
for (const mosaic of [false, true]) for (const exposure of [-2, 0, 2]) {
  save(`neutral-${mosaic}-${exposure}`, { mosaic, baselineExposure: exposure,
    asShotNeutral: [0.5, 1, 0.25], patches: [[0.02, 0.02, 0.02], [0.18, 0.18, 0.18], [0.8, 0.8, 0.8]] })
}
for (const mosaic of [false, true]) for (const littleEndian of [false, true])
  save(`byte-order-${mosaic}-${littleEndian}`, { mosaic, littleEndian })
save('odd', { width: 321, height: 193, mosaic: false })
save('half', { width: 640, height: 384 })
save('headroom', { mosaic: false, asShotNeutral: [0.5, 1, 0.25], patches: [[1.6, 0.8, 2.8]] })
save('bad-crop', { extraTags: [[50719, 5, [11, 7]], [50720, 5, [0.01, 0.01]]] })
const truncated = makeDNG()
writeFileSync(join(root, 'truncated'), truncated.subarray(0, truncated.length / 2))
writeFileSync(join(root, 'ordinary'), Buffer.concat([
  Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jMlkAAAAASUVORK5CYII=', 'base64'),
  Buffer.alloc(512),
]))
console.log(`Wrote synthetic RAW fixtures to ${root}`)
