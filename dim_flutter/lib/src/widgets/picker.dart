import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';

import 'package:dim_client/ok.dart';

import '../common/platform.dart';

import '../pnf/image.dart';
import '../ui/icons.dart';

import 'alert.dart';
import 'permissions.dart';


typedef OnImagePicked = void Function(String path);
typedef OnImageRead = void Function(String path, Uint8List data);

void openImagePicker(BuildContext context, {OnImagePicked? onPicked, required OnImageRead onRead}) {
  if (DevicePlatform.isDesktop) {
    // Windows / Linux / macOS: image_picker has no camera there, and the camera permission
    // check cannot succeed either (Linux: no permission_handler -> "Permission Denied";
    // Windows: "granted" -> image_picker throws "Camera Error"). Open the file dialog directly.
    _openImagePicker(context, false, onPicked, onRead);
    return;
  }
  Alert.actionSheet(context, null, null,
      Alert.action(AppIcons.cameraIcon, 'Camera'),
          () => PermissionCenter().requestCameraPermissions(context,
            onGranted: (context) => _openImagePicker(context, true, onPicked, onRead),
          ),
      Alert.action(AppIcons.albumIcon, 'Album'),
          () => PermissionCenter().requestPhotoReadingPermissions(context,
            onGranted: (context) => _openImagePicker(context, false, onPicked, onRead),
          ),
    );
}

void _openImagePicker(BuildContext context, bool camera, OnImagePicked? onPicked, OnImageRead onRead) =>
    ImagePicker().pickImage(source: camera ? ImageSource.camera : ImageSource.gallery).then((file) {
      if (file == null) {
        Log.error('failed to get image file');
        return;
      }
      String path = file.path;
      file.readAsBytes().then((data) {
        if (!context.mounted) {
          Log.warning('context unmounted: $context');
          return;
        }
        _confirmImage(context, path, data, onPicked, onRead);
      }).onError((error, stackTrace) {
        if (context.mounted) {
          Alert.show(context, 'Image File Error', '$error');
        }
      });
    }).onError((error, stackTrace) {
      if (context.mounted) {
        String title = camera ? 'Camera Error' : 'Gallery Error';
        Alert.show(context, title, '$error');
      }
    });


void _confirmImage(BuildContext context, String path, Uint8List data, OnImagePicked? onPicked, OnImageRead onRead) {
  Log.debug('image file length: ${data.length}, path: $path');
  Image body = ImageUtils.memoryImage(data);
  Alert.confirm(context, 'Pick Image', body,
    okAction: () {
      if (onPicked != null) {
        onPicked(path);
      }
      onRead(path, data);
    },
  );
}

final RegExp _imageFile = RegExp(r'\.(png|jpe?g|gif|bmp|webp|heic)$', caseSensitive: false);

///  Desktop: paste an image from the clipboard (a screenshot, or an image file copied in the
///  file manager) and confirm it like a picked one.
///  Returns false when the clipboard holds no image -- the normal text paste is unaffected.
Future<bool> pasteImage(BuildContext context, {OnImagePicked? onPicked, required OnImageRead onRead}) async {
  Uint8List? data;
  String path = 'clipboard.png';
  try {
    data = await Pasteboard.image;
    if (data == null || data.isEmpty) {
      for (String file in await Pasteboard.files()) {
        if (_imageFile.hasMatch(file)) {
          data = await File(file).readAsBytes();
          path = file;
          break;
        }
      }
    }
  } catch (e, st) {
    Log.error('failed to read image from clipboard: $e, $st');
    return false;
  }
  if (data == null || data.isEmpty) {
    return false;
  } else if (!context.mounted) {
    Log.warning('context unmounted: $context');
    return true;
  }
  _confirmImage(context, path, data, onPicked, onRead);
  return true;
}


///  Check whether needs resize down a large image
///
/// @param jpeg   - image data
/// @param onSank - callback with small image data after resized down
/// @param size   - target size (width & height)
void adjustImage(Uint8List jpeg, int size, void Function(Uint8List small) onSank) {
  int fileSize = jpeg.length;
  int maxFileSize = size * size;
  if (fileSize <= maxFileSize) {
    Log.info('no need to resize: $fileSize <= $maxFileSize');
    onSank(jpeg);
  } else {
    double ratio = sqrt(maxFileSize / fileSize);
    Log.info('resize image with ratio: $ratio, $fileSize > $maxFileSize');
    _resolveImage(jpeg, (ui.Image image) async {
      double width = image.width * ratio;
      double height = image.height * ratio;
      // zoom out
      Uint8List? small = await ImageUtils.compress(jpeg,
        minWidth: width.toInt(),
        minHeight: height.toInt(),
      );
      int borderline = fileSize < _lintel  // 2 MB
          ? fileSize - (fileSize >> 2)     // size * 0.75
          : fileSize - _threshold;         // size - 0.5 MB
      Log.info('resized: ${image.width} * ${image.height} => $width * $height,'
          ' $fileSize => ${small?.length} bytes');
      if (small != null && small.length < borderline) {
        onSank(small);
      } else {
        Log.warning('unworthy compression: $fileSize -> ${small?.length}, borderline: $borderline');
        onSank(jpeg);
      }
    });
  }
}
const int _lintel = 1 << 21;  // 1024 * 1024 * 2
const int _threshold = 1 << 19;  // 1024 * 512

/// fetch size info from image data
void _resolveImage(Uint8List jpeg, void Function(ui.Image image) onResolved) =>
    ImageUtils.memoryImageProvider(jpeg).resolve(const ImageConfiguration()).addListener(
        ImageStreamListener((info, _) => onResolved(info.image))
    );
