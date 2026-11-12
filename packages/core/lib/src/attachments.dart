import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'codec.dart';
import 'crypto.dart';

/// 仓库只存密文摘要命名的对象，明文摘要放在加密消息中，不做跨会话可观察去重。
class AttachmentDescriptor {
  final String objectId;
  final String name;
  final String mime;
  final int size;
  final String plainHash;
  final String nonce;
  final String tag;
  AttachmentDescriptor({required this.objectId, required this.name, required this.mime, required this.size, required this.plainHash, required this.nonce, required this.tag});
  Map<String,dynamic> toJson() => {'object_id':objectId,'name':name,'mime':mime,'size':size,'plain_hash':plainHash,'nonce':nonce,'tag':tag};
  factory AttachmentDescriptor.fromJson(Map<String,dynamic> value) => AttachmentDescriptor(objectId:readString(value,'object_id'),name:readString(value,'name',max:256),mime:readString(value,'mime',max:128),size:readInt(value,'size',max:20*1024*1024),plainHash:readString(value,'plain_hash'),nonce:readString(value,'nonce'),tag:readString(value,'tag'));
}

class EncryptedAttachments {
  final Directory root;
  final int maxBytes;
  EncryptedAttachments(this.root,{this.maxBytes=2*1024*1024}) {
    if(maxBytes<1 || maxBytes>20*1024*1024) throw ArgumentError('附件上限需1字节～20MiB');
  }
  File _file(String id) {
    if(!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) throw const FormatException('无效附件对象号');
    return File(p.join(root.path,'$id.bin'));
  }
  Future<AttachmentDescriptor> put(List<int> compressed, ConversationKey key,{required String name,required String mime}) async {
    if(compressed.isEmpty || compressed.length>maxBytes) throw ArgumentError('附件为空或超过发送上限');
    if(name.isEmpty || name.length>256 || mime.isEmpty || mime.length>128) throw ArgumentError('无效附件描述');
    final box=await AesGcm.with256bits().encrypt(compressed,secretKey:SecretKey(key.bytes),aad:utf8.encode('zaizuo.attachment.v1:${key.context}'));
    final id=await sha256Hex(box.cipherText);
    await root.create(recursive:true);
    await _file(id).writeAsBytes(box.cipherText,flush:true);
    return AttachmentDescriptor(objectId:id,name:name,mime:mime,size:compressed.length,plainHash:await sha256Hex(compressed),nonce:base64Encode(box.nonce),tag:base64Encode(box.mac.bytes));
  }
  Future<List<int>> get(AttachmentDescriptor descriptor,ConversationKey key) async {
    if(descriptor.size>maxBytes) throw StateError('附件超过本机加载上限');
    final file=_file(descriptor.objectId);
    if(await file.length()>maxBytes) throw StateError('密文对象过大');
    final bytes=await file.readAsBytes();
    if(await sha256Hex(bytes)!=descriptor.objectId) throw StateError('附件密文摘要不匹配');
    final clear=await AesGcm.with256bits().decrypt(SecretBox(bytes,nonce:base64Decode(descriptor.nonce),mac:Mac(base64Decode(descriptor.tag))),secretKey:SecretKey(key.bytes),aad:utf8.encode('zaizuo.attachment.v1:${key.context}'));
    if(clear.length!=descriptor.size || await sha256Hex(clear)!=descriptor.plainHash) throw StateError('附件原文摘要不匹配');
    return clear;
  }
}

/// WebP 编码器适配口。桌面可显式配置本机 cwebp，Android 后续接原生库。
/// 不自动下载、不运行仓库指定的可执行文件。不能称为已完成 Android 图像栈。
class CWebpEncoder {
  final String executable;
  final bool lossless;
  final int quality;
  final int maxInputBytes;
  CWebpEncoder({required this.executable,this.lossless=true,this.quality=85,this.maxInputBytes=20*1024*1024}) {
    if(!p.isAbsolute(executable) || !File(executable).existsSync() || quality<0 || quality>100) throw ArgumentError('请配置本机可信 cwebp 绝对路径');
  }
  Future<List<int>> encode(File input) async {
    if(await input.length()>maxInputBytes) throw StateError('图片输入过大');
    final temp=await Directory.systemTemp.createTemp('zaizuo-webp-');
    try {
      final output=File(p.join(temp.path,'compressed.webp'));
      final args=<String>['-quiet',if(lossless) '-lossless','-q','$quality',input.absolute.path,'-o',output.path];
      final process=await Process.start(executable,args,runInShell:false,mode:ProcessStartMode.normal);
      // 两条管道都持续读，限制输出而非不读导致子进程死锁。
      final stdout=process.stdout.fold<int>(0,(sum,bytes)=>sum+bytes.length);
      final stderr=process.stderr.fold<int>(0,(sum,bytes)=>sum+bytes.length);
      int code;
      try { code=await process.exitCode.timeout(const Duration(seconds:30)); }
      on Object { process.kill(); await process.exitCode; rethrow; }
      await stdout; await stderr;
      if(code!=0 || !await output.exists() || await output.length()>maxInputBytes) throw StateError('WebP编码失败/超出上限');
      return output.readAsBytes();
    } finally { await temp.delete(recursive:true); }
  }
}
