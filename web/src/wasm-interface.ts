import { decodeBytes } from "./worklet-shims.ts";

export type ConsoleLogFunction = (level: number, msgPtr: number, msgLen: number) => void;

export function consoleLogFactory(memorySupplier: () => WebAssembly.Memory): ConsoleLogFunction {
  return (level, msgPtr, msgLen) => {
    const msg = decodeBytes(new Uint8Array(memorySupplier().buffer, msgPtr, msgLen));
    // Keep in sync with Zig `std.log.Level`.
    switch (level) {
      case 0:
        console.error(msg);
        break;
      case 1:
        console.warn(msg);
        break;
      case 2:
        console.info(msg);
        break;
      case 3:
        console.debug(msg);
        break;
      default:
        // Should not be possible.
        console.log(msg);
        break;
    }
  };
}
