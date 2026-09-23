export const RAW_EXTENSIONS = [
  'dng',
  'cr2',
  'cr3',
  'crw',
  'nef',
  'nrw',
  'arw',
  'srf',
  'sr2',
  'raf',
  'orf',
  'ori',
  'rw2',
  'raw',
  'rwl',
  'pef',
  'ptx',
  'srw',
  '3fr',
  'fff',
  'iiq',
  'kdc',
  'dcr',
  'mrw',
  'mos',
  'erf',
  'mef',
  'mdc',
  'x3f',
]
export const IMAGE_ACCEPT = ['image/*', '.exr', ...RAW_EXTENSIONS.map((ext) => `.${ext}`)].join(',')
export const isRawFile = (file) =>
  RAW_EXTENSIONS.includes(file.name.split('.').at(-1).toLowerCase()) ||
  /(?:raw|dng|cr2|cr3|nef|arw|raf)/i.test(file.type)

export const VIDEO_ACCEPT = 'video/*,.mp4,.mov,.m4v,.webm,.mkv'
export const isVideoFile = (file) =>
  file.type.startsWith('video/') || /\.(mp4|mov|m4v|webm|mkv)$/i.test(file.name)
export const isEXRFile = (file) => /\.exr$/i.test(file.name)
