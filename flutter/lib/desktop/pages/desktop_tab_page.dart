import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

class DesktopTabPage extends StatefulWidget {
  const DesktopTabPage({Key? key}) : super(key: key);

  @override
  State<DesktopTabPage> createState() => _DesktopTabPageState();

  static final Rx<SettingsTabKey?> requestedSettingsTab = Rxn();

  static void onAddSetting(
      {SettingsTabKey initialPage = SettingsTabKey.general}) {
    requestedSettingsTab.value = initialPage;
  }
}

class _DesktopTabPageState extends State<DesktopTabPage>
    with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: const DesktopHomePage(),
    );
    return isMacOS || kUseCompatibleUiMode
        ? page
        : Obx(
            () => DragToResizeArea(
              resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
              enableResizeEdges: windowManagerEnableResizeEdges,
              child: page,
            ),
          );
  }
}
