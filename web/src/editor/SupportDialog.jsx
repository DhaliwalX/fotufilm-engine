import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
export default function SupportDialog() {
  return (
    <Dialog aria-label="Browser support" isDismissible size={"M"}>
      <Heading>{"Browser support"}</Heading>
      <Content>
        <div className="support-copy">
          <p>
            Photos and videos are processed on this device. WebGPU is used when
            available, with WebAssembly CPU fallback.
          </p>
          <p>
            A smaller overview keeps movement smooth. Once movement settles, the
            visible image is developed at the display’s pixel resolution. Export
            develops the entire image at the selected size.
          </p>
          <p>
            The browser supports film selection and format, ageing, halation,
            grain models, measured push/pull, bleach bypass, colour separation,
            print viewing, a simulated printer, an ordered lens-filter stack,
            automatic and manual lens correction, Auto Adjust, photo frames,
            light and color adjustments, three-way grading, color and light
            selections, crop, rotation and flip. Camera RAW files use as-shot
            white balance. RAW, linear EXR and supported HDR JPEG gain maps
            preserve decoded highlight detail before film exposure.
          </p>
          <p>
            Scanned-negative conversion, automatic subject selections, custom
            packs, and HDR export are available in the Mac app. Still previews
            and exports use Display P3 where supported; TIFF preserves 16-bit
            Display P3 precision. Other browsers use sRGB for canvas output.
          </p>
        </div>
      </Content>
    </Dialog>
  );
}
