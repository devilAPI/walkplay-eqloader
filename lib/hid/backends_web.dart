import 'hid.dart';
import 'web_hid.dart';

HidBackend createBackend() => WebHid();
