import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:win32_registry/win32_registry.dart';

import 'package:dim_client/ok.dart';

import 'device_base.dart';


/// Windows / Linux
String readProductName(BaseDeviceInfo info) {
  if (info is WindowsDeviceInfo) {
    // SMBIOS product name, fallback to "Windows 11 Pro"
    return _windowsSystemProductName() ?? getWindowsProductName(info);
  } else if (info is LinuxDeviceInfo) {
    // DMI product name, fallback to "ubuntu"
    return _linuxSystemProductName() ?? getLinuxProductName(info);
  }
  // unknown
  return getDefaultProductName(info);
}


/// SMBIOS device model, equivalent to iOS utsname.machine / Android device / macOS model.
/// SOURCE: HKLM\HARDWARE\DESCRIPTION\System\BIOS\SystemProductName
String? _windowsSystemProductName() {
  const path = r'HARDWARE\DESCRIPTION\System\BIOS';
  final RegistryKey registryKey;
  try {
    registryKey = Registry.openPath(RegistryHive.localMachine, path: path);
  } catch (e) {
    Log.error('failed to read windows product name: $e');
    return null;
  }
  try {
    String? name = registryKey.getValueAsString('SystemProductName');
    if (name == null || isPlaceholderProductName(name)) {
      Log.warning('ignore product name: "$name"');
      name = registryKey.getValueAsString('SystemManufacturer');
      if (name == null || isPlaceholderProductName(name)) {
        Log.warning('ignore manufacturer name: "$name"');
        return null;
      }
    }
    return name;
  } finally {
    registryKey.close();
  }
}


/// DMI device model, equivalent to iOS utsname.machine / Android device / macOS model.
/// SOURCE: /sys/class/dmi/id/product_name
String? _linuxSystemProductName() {
  const file = r'/sys/class/dmi/id/product_name';
  final String productName;
  try {
    productName = File(file).readAsStringSync().trim();
  } catch (e) {
    Log.error('failed to read linux product name: $e');
    return null;
  }
  // Filter the placeholder string of DIY motherboards
  if (isPlaceholderProductName(productName)) {
    Log.warning('ignore product name: "$productName"');
    return null;
  }
  return productName;
}
