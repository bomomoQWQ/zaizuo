/// 在座纯业务内核。认证、签名验证、跨设备归并须由可信调用边界完成。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:characters/characters.dart';

part 'src/models.dart';
part 'src/state.dart';
part 'src/service.dart';
