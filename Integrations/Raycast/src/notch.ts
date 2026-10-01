import { closeMainWindow, getApplications, open, showToast, Toast } from "@raycast/api";

const bundleID = "com.notchtherock.NotchTheRock";

/** The plugin id rule the app's links accept: reverse-DNS, at most 255 characters. */
export function isPluginID(id: string): boolean {
  return id.length <= 255 && /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(id);
}

/** Opens the notch on the home, or on the screen of the plugin `pluginID`, then closes Raycast. */
export async function openNotch(pluginID?: string): Promise<void> {
  const applications = await getApplications();
  if (!applications.some((application) => application.bundleId === bundleID)) {
    await showToast({
      style: Toast.Style.Failure,
      title: "NotchTheRock이 설치되어 있지 않아요",
      message: "앱을 설치한 뒤 다시 실행해 주세요.",
    });
    return;
  }
  const url = pluginID === undefined ? "notchtherock://open" : `notchtherock://open/${encodeURIComponent(pluginID)}`;
  try {
    await open(url);
    await closeMainWindow();
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: "노치를 열지 못했어요", message: String(error) });
  }
}
