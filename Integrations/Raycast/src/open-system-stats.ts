import { openNotch } from "./notch";

export default async function Command() {
  await openNotch("com.notchtherock.systemstats");
}
