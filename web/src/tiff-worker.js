import { encodeTiff16 } from "./tiff.js";
self.onmessage = ({ data }) => {
  try {
    self.postMessage({ blob: encodeTiff16(data) });
  } catch (error) {
    self.postMessage({ error: error.message });
  }
};
