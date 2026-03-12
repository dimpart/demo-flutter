/* license: https://mit-license.org
 *
 *  DIM-SDK : Decentralized Instant Messaging Software Development Kit
 *
 *                               Written in 2026 by Moky <albert.moky@gmail.com>
 *
 * =============================================================================
 * The MIT License (MIT)
 *
 * Copyright (c) 2026 Albert Moky
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 * =============================================================================
 */
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_section_list/flutter_section_list.dart';

import '../common/platform.dart';
import '../ui/styles.dart';


Widget buildScrollView({
  bool enableScrollbar = false,
  Axis scrollDirection = Axis.vertical,
  // bool reverse = false,
  // EdgeInsetsGeometry? padding,
  // bool? primary,
  // ScrollPhysics? physics,
  // ScrollController? controller,
  required Widget child,
  // DragStartBehavior dragStartBehavior = DragStartBehavior.start,
  // Clip clipBehavior = Clip.hardEdge,
  // String? restorationId,
  // ScrollViewKeyboardDismissBehavior keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
}) {
  var view = SingleChildScrollView(
    scrollDirection: scrollDirection,
    child: child,
  );
  if (DevicePlatform.isMobile) {
    // needs to enable scroll bar
  } else {
    enableScrollbar = false;
  }
  return enableScrollbar ? Scrollbar(child: view) : view;
}


Widget buildSectionListView({
  bool enableScrollbar = false,
  // Axis scrollDirection = Axis.vertical,
  bool reverse = false,
  // ScrollController? controller,
  // bool? primary,
  // ScrollPhysics? physics,
  // bool shrinkWrap = false,
  // EdgeInsetsGeometry? padding,
  required SectionAdapter adapter,
  // bool addAutomaticKeepAlives = true,
  // bool addRepaintBoundaries = true,
  // bool addSemanticIndexes = true,
  // double? cacheExtent,
  // DragStartBehavior dragStartBehavior = DragStartBehavior.start,
  // ScrollViewKeyboardDismissBehavior keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
  // String? restorationId,
  // Clip clipBehavior = Clip.hardEdge,
}) {
  var view = SectionListView.builder(
    reverse: reverse,
    adapter: adapter,
  );
  if (DevicePlatform.isMobile) {
    // needs to enable scroll bar
  } else {
    enableScrollbar = false;
  }
  return enableScrollbar ? Scrollbar(child: view) : view;
}


/*
    CupertinoListTile(
        backgroundColor: backgroundColor,
        backgroundColorActivated: backgroundColorActivated,
        padding: Styles.settingsSectionItemPadding,
        title: Text('ID', style: TextStyle(color: primaryTextColor)),
        additionalInfo: _idLabel(context),
    )
 */
Widget buildAdaptiveListTile(BuildContext context, {
  required Widget title,
  // Widget? subtitle,
  Widget? additionalInfo,
  // Widget? leading,
  // Widget? trailing,
  // FutureOr<void> Function()? onTap,
  Color? backgroundColor,
  Color? backgroundColorActivated,
  EdgeInsetsGeometry? padding,
  double leadingSize = 120,
  // double leadingToTitle = 16.0,
}) {
  final textStyle = CupertinoTheme.of(context).textTheme.textStyle;
  final screenWidth = MediaQuery.of(context).size.width;
  final width = screenWidth - leadingSize;
  return Container(
    color: backgroundColor,
    child: InkWell(
      onTap: () {},
      child: Padding(
        padding: padding ?? Styles.settingsSectionItemPadding,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // title
            DefaultTextStyle(
              style: textStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: title,
            ),
            // additional info
            Container(
              width: width.clamp(160, 1024),
              constraints: BoxConstraints(maxWidth: width),
              child: additionalInfo,
            ),
          ],
        ),
      ),
    ),
  );
}
