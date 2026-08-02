import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Whether the app is running on macOS (where native menus are used).
final bool isMacOSPlatform =
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Whether the app runs on a desktop platform (Windows, Linux or macOS).
final bool isDesktopPlatform =
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// A keyboard shortcut that maps to Cmd on macOS and Ctrl elsewhere.
MenuSerializableShortcut cmdShortcut(LogicalKeyboardKey key) =>
    SingleActivator(key, meta: isMacOSPlatform, control: !isMacOSPlatform);

/// Represents a menu item that can be rendered as both a native macOS menu
/// and a Flutter in-app menu.
sealed class AppMenuItem {
  const AppMenuItem();
}

class AppMenuAction extends AppMenuItem {
  final String label;
  final VoidCallback? onPressed;
  final MenuSerializableShortcut? shortcut;
  final bool checked;
  final bool hideOnMacOS;

  const AppMenuAction({
    required this.label,
    this.onPressed,
    this.shortcut,
    this.checked = false,
    this.hideOnMacOS = false,
  });
}

class AppMenuDivider extends AppMenuItem {
  final bool hideOnMacOS;
  const AppMenuDivider({this.hideOnMacOS = false});
}

class AppSubmenu extends AppMenuItem {
  final String label;
  final String? macOSLabel;
  final List<AppMenuItem> children;

  /// When false the submenu is shown grayed out and cannot be opened.
  final bool enabled;

  const AppSubmenu({
    required this.label,
    this.macOSLabel,
    required this.children,
    this.enabled = true,
  });
}

/// Wraps [child] with an application menu. On macOS the native menu bar is used
/// (via [PlatformMenuBar]); on every other platform an in-app [MenuBar] is
/// rendered above the content.
class AppMenuBar extends StatelessWidget {
  const AppMenuBar({
    super.key,
    required this.menus,
    required this.appName,
    required this.child,
    this.onAbout,
  });

  final List<AppSubmenu> menus;
  final String appName;
  final Widget child;
  final VoidCallback? onAbout;

  @override
  Widget build(BuildContext context) {
    if (isMacOSPlatform) {
      return PlatformMenuBar(menus: _buildPlatformMenus(), child: child);
    }
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            top: true,
            bottom: false,
            child: _buildBuiltInMenuBar(context),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }

  // ==========================================================================
  // Native macOS platform menus
  // ==========================================================================

  List<PlatformMenuItem> _buildPlatformMenus() {
    return [
      // Standard macOS application menu.
      PlatformMenu(
        label: appName,
        menus: [
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(label: 'About $appName', onSelected: onAbout),
            ],
          ),
          const PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Hide',
                shortcut: SingleActivator(LogicalKeyboardKey.keyH, meta: true),
              ),
              PlatformMenuItem(
                label: 'Hide Others',
                shortcut: SingleActivator(
                  LogicalKeyboardKey.keyH,
                  meta: true,
                  alt: true,
                ),
              ),
              PlatformMenuItem(label: 'Show All'),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Quit $appName',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyQ,
                  meta: true,
                ),
                onSelected: () => SystemNavigator.pop(),
              ),
            ],
          ),
        ],
      ),
      // Convert our menu definitions, dropping any that are empty on macOS.
      ...menus.map((submenu) {
        final items = _convertMenuItems(submenu.children);
        if (items.isEmpty) return null;
        return PlatformMenu(
          label: submenu.macOSLabel ?? submenu.label,
          menus: items,
        );
      }).whereType<PlatformMenu>(),
    ];
  }

  List<PlatformMenuItem> _convertMenuItems(List<AppMenuItem> items) {
    final result = <PlatformMenuItem>[];
    final currentGroup = <PlatformMenuItem>[];

    void flush() {
      if (currentGroup.isNotEmpty) {
        result.add(PlatformMenuItemGroup(members: List.from(currentGroup)));
        currentGroup.clear();
      }
    }

    for (final item in items) {
      if (item is AppMenuDivider) {
        if (item.hideOnMacOS) continue;
        flush();
      } else if (item is AppMenuAction) {
        if (item.hideOnMacOS) continue;
        currentGroup.add(
          PlatformMenuItem(
            label: item.checked ? '✓ ${item.label}' : item.label,
            shortcut: item.shortcut,
            onSelected: item.onPressed,
          ),
        );
      } else if (item is AppSubmenu) {
        flush();
        // PlatformMenu has no disabled state, so show a grayed-out item.
        if (!item.enabled) {
          result.add(
            PlatformMenuItemGroup(
              members: [PlatformMenuItem(label: item.label, onSelected: null)],
            ),
          );
        } else {
          result.add(
            PlatformMenu(
              label: item.label,
              menus: _convertMenuItems(item.children),
            ),
          );
        }
      }
    }

    flush();
    return result;
  }

  // ==========================================================================
  // Built-in Flutter menu bar
  // ==========================================================================

  Widget _buildBuiltInMenuBar(BuildContext context) {
    final menuStyle = const MenuStyle(
      padding: WidgetStatePropertyAll(EdgeInsets.zero),
      minimumSize: WidgetStatePropertyAll(Size.zero),
    );
    final menuItemStyle = ButtonStyle(
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
    );
    final submenuStyle = ButtonStyle(
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
    );

    return SizedBox(
      width: double.infinity,
      child: MenuBar(
        style: menuStyle,
        children: menus.map((submenu) {
          return SubmenuButton(
            style: submenuStyle,
            menuStyle: menuStyle,
            menuChildren: _buildBuiltInMenuItems(
              submenu.children,
              menuItemStyle,
              menuStyle,
            ),
            child: Text(submenu.label),
          );
        }).toList(),
      ),
    );
  }

  List<Widget> _buildBuiltInMenuItems(
    List<AppMenuItem> items,
    ButtonStyle menuItemStyle,
    MenuStyle menuStyle,
  ) {
    final anyChecked = items.any((i) => i is AppMenuAction && i.checked);
    return items.map((item) {
      if (item is AppMenuDivider) {
        return const Divider(height: 1);
      } else if (item is AppMenuAction) {
        return MenuItemButton(
          style: menuItemStyle,
          onPressed: item.onPressed,
          shortcut: item.shortcut,
          leadingIcon: item.checked
              ? const Icon(Icons.check, size: 16)
              : (anyChecked ? const SizedBox(width: 16) : null),
          child: Text(item.label),
        );
      } else if (item is AppSubmenu) {
        return SubmenuButton(
          style: menuItemStyle,
          menuStyle: menuStyle,
          leadingIcon: anyChecked ? const SizedBox(width: 16) : null,
          menuChildren: item.enabled
              ? _buildBuiltInMenuItems(item.children, menuItemStyle, menuStyle)
              : const <Widget>[],
          child: Text(item.label),
        );
      }
      return const SizedBox.shrink();
    }).toList();
  }
}
