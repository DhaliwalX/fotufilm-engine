import curves from "./generated/video-curves.wgsl?raw";
import kernel from "./video-color.wgsl?raw";
import { videoColorParameters } from "./video-color-parameters.js";

// One pipeline and one reusable set of buffers per serial decoding worker.
export class VideoColorGPU {
  static async create() {
    const adapter = await globalThis.navigator?.gpu?.requestAdapter({
      powerPreference: "high-performance",
    });
    if (!adapter) return null;
    const limit = Math.min(
      adapter.limits.maxStorageBufferBindingSize,
      640_000_000,
    );
    const device = await adapter.requestDevice({
      requiredLimits: {
        maxStorageBufferBindingSize: limit,
        maxBufferSize: Math.max(limit, 134217728),
      },
    });
    try {
      const module = device.createShaderModule({ code: curves + kernel });
      const pipeline = await device.createComputePipelineAsync({
        layout: "auto",
        compute: { module, entryPoint: "main" },
      });
      return new VideoColorGPU(device, pipeline);
    } catch (error) {
      device.destroy();
      throw error;
    }
  }
  constructor(device, pipeline) {
    this.device = device;
    this.pipeline = pipeline;
    this.buffers = [];
    this.key = "";
    device.lost.then(() => {
      this.lost = true;
      this.clear();
    });
  }
  clear() {
    for (const buffer of this.buffers) buffer.destroy();
    this.buffers = [];
    this.key = "";
  }
  dispose() {
    this.clear();
    this.device.destroy();
  }
  async decode(frame, encoding) {
    if (this.lost) throw new Error("Video GPU was lost.");
    const parameters = videoColorParameters(frame, encoding),
      d = this.device;
    const inputSize = Math.ceil(frame.data.byteLength / 4) * 4,
      outputSize = frame.displayWidth * frame.displayHeight * 16;
    if (Math.max(inputSize, outputSize) > d.limits.maxStorageBufferBindingSize)
      return null;
    const key = `${inputSize}:${outputSize}`;
    if (key !== this.key) {
      this.clear();
      this.buffers = [
        d.createBuffer({
          size: inputSize,
          usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
        }),
        d.createBuffer({
          size: parameters.byteLength,
          usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
        }),
        d.createBuffer({
          size: outputSize,
          usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
        }),
        d.createBuffer({
          size: outputSize,
          usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST,
        }),
      ];
      this.key = key;
    }
    const [input, params, output, readback] = this.buffers;
    const padded =
      inputSize === frame.data.byteLength
        ? frame.data
        : new Uint8Array(inputSize);
    if (padded !== frame.data) padded.set(frame.data);
    d.pushErrorScope("validation");
    try {
      d.queue.writeBuffer(input, 0, padded);
      d.queue.writeBuffer(params, 0, parameters);
      const group = d.createBindGroup({
        layout: this.pipeline.getBindGroupLayout(0),
        entries: [input, params, output].map((buffer, binding) => ({
          binding,
          resource: { buffer },
        })),
      });
      const commands = d.createCommandEncoder(),
        pass = commands.beginComputePass();
      pass.setPipeline(this.pipeline);
      pass.setBindGroup(0, group);
      pass.dispatchWorkgroups(
        Math.ceil(frame.displayWidth / 16),
        Math.ceil(frame.displayHeight / 16),
      );
      pass.end();
      commands.copyBufferToBuffer(output, 0, readback, 0, outputSize);
      d.queue.submit([commands.finish()]);
      await readback.mapAsync(GPUMapMode.READ);
      try {
        return new Float32Array(readback.getMappedRange().slice(0));
      } finally {
        readback.unmap();
      }
    } finally {
      const error = await d.popErrorScope();
      if (error) throw new Error(error.message);
    }
  }
}
