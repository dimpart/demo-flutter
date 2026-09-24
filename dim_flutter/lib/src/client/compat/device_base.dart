
import 'package:device_info_plus/device_info_plus.dart';


/// Returns true if the given DMI/SMBIOS product name is a generic placeholder
/// left by DIY motherboards (ASUS, MSI, etc.), such as "System Product Name"
/// or "To Be Filled By O.E.M.".
bool isPlaceholderProductName(String name) {
  final lower = name.trim().toLowerCase();
  return lower.isEmpty || lower == 'system product name' || lower.contains('to be filled');
}


String getWebPlatform(WebBrowserInfo info) {
  final p = info.platform ?? '';
  if (p == 'MacIntel' && (info.maxTouchPoints ?? 0) > 0) {
    // iPad disguised as MacIntel
    return 'iPadOS';
  }
  if (p.toLowerCase().contains('arm')) {
    // Android Chrome reports Linux armv71/aarch64
    return 'Android';
  }
  // MacIntel / Win32 / Linux x86_64 / iPhone / iPadOS ...
  return p;
}

// "Windows 11 Pro"
String getWindowsProductName(WindowsDeviceInfo info) => info.productName;

// "ubuntu"
String getLinuxProductName(LinuxDeviceInfo info) => info.id;

// unknown
String getDefaultProductName(BaseDeviceInfo info) => '';
