import 'dart:developer';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// This machine's name, which a Device is named after until its owner names
/// it: the host name on a computer; on Android, whose host name is always
/// `localhost`, the name given to the phone in its settings, else its model.
/// Empty when there is none to tell.
Future<String> thisMachineName() async {
  if (!Platform.isAndroid) return Platform.localHostname;
  try {
    final phone = await DeviceInfoPlugin().androidInfo;
    return androidMachineName(name: phone.name, model: phone.model);
  } catch (error) {
    log('The phone\'s name could not be read: $error', name: 'MachineName');
    return '';
  }
}

/// An Android phone's name: the [name] given to it in its settings, else its
/// [model].
String androidMachineName({required String name, required String model}) =>
    name.trim().isNotEmpty ? name.trim() : model.trim();
