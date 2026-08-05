declare module "virtual:zfm/initial-bank" {
  import type { Patch } from "./patch/types";
  const bank: Patch[];
  export default bank;
}
