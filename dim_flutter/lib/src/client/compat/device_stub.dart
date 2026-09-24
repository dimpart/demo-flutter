
import 'package:device_info_plus/device_info_plus.dart';

import 'device_base.dart';


/// Web
String readProductName(BaseDeviceInfo info) {
  if (info is WindowsDeviceInfo) {
    // "Windows 11 Pro"
    return getWindowsProductName(info);
  } else if (info is LinuxDeviceInfo) {
    // "ubuntu"
    return getLinuxProductName(info);
  }
  // unknown
  return getDefaultProductName(info);
}
