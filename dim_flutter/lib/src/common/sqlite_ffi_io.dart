import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Windows/Linux: initialize sqflite's FFI implementation and make it the default factory.
void initDesktopSQLite() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
