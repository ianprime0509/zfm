export type ConsoleLogFunction = (level: number, msgPtr: number, msgLen: number) => void;

export function consoleLogFactory(memorySupplier: () => WebAssembly.Memory): ConsoleLogFunction {
  return (level, msgPtr, msgLen) => {
    const msgBytes = new Uint8Array(memorySupplier().buffer, msgPtr, msgLen);
    // TextDecoder is not available in AudioWorklet.
    const msg = Array.from(msgBytes, (b) => String.fromCharCode(b)).join("");
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
