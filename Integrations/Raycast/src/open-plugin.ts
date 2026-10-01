import { LaunchProps, showToast, Toast } from "@raycast/api";
import { isPluginID, openNotch } from "./notch";

export default async function Command(props: LaunchProps<{ arguments: Arguments.OpenPlugin }>) {
  const pluginID = props.arguments.pluginID.trim();
  if (!isPluginID(pluginID)) {
    await showToast({
      style: Toast.Style.Failure,
      title: "플러그인 식별자를 확인해 주세요",
      message: "com.example.clock처럼 역도메인 형식으로 적어요.",
    });
    return;
  }
  await openNotch(pluginID);
}
