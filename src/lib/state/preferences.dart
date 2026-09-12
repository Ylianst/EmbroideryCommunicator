import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shared [SharedPreferences] instance, overridden at startup in `main`.
/// Null when not provided (e.g. tests), so consumers fall back to defaults
/// and simply skip persistence.
final sharedPreferencesProvider = Provider<SharedPreferences?>((ref) => null);
