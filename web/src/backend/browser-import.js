import { isVideoFile, isEXRFile, isRawFile } from "../media-types.js";
import { importVideo } from "../video-import.js";
import { importEXR } from "../exr-import.js";
import { importRaw } from "../raw-import.js";
import { importPhoto } from "../photo-import.js";

export function importMedia(file, options) {
  const decode = isVideoFile(file)
    ? importVideo
    : isEXRFile(file)
      ? importEXR
      : isRawFile(file)
        ? importRaw
        : importPhoto;
  if (
    decode === importPhoto &&
    !file.type.startsWith("image/") &&
    !/\.(png|jpe?g|webp|avif|gif|bmp|tiff?)$/i.test(file.name)
  )
    return Promise.reject(
      new Error("Choose a photo, camera RAW file, or video."),
    );
  return decode(file, options);
}
