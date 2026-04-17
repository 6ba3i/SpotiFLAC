import 'package:flutter/widgets.dart';

class ShellNavigationService {
  static final GlobalKey<NavigatorState> homeTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> libraryTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> repoTabNavigatorKey =
      GlobalKey<NavigatorState>();

  static int _currentTabIndex = 0;
  static bool _showRepoTab = false;
  static void Function(int index)? _tabSelectionCallback;

  static void syncState({
    required int currentTabIndex,
    required bool showRepoTab,
  }) {
    _currentTabIndex = currentTabIndex;
    _showRepoTab = showRepoTab;
  }

  static NavigatorState? activeTabNavigator() {
    if (_currentTabIndex == 0) return homeTabNavigatorKey.currentState;
    if (_currentTabIndex == 1) return libraryTabNavigatorKey.currentState;
    if (_showRepoTab && _currentTabIndex == 2) {
      return repoTabNavigatorKey.currentState;
    }
    return null;
  }

  static void registerTabSelectionCallback(
    void Function(int index)? callback,
  ) {
    _tabSelectionCallback = callback;
  }

  static void openLibraryTab() {
    _tabSelectionCallback?.call(1);
  }
}
