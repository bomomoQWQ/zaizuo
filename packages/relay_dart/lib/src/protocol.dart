import 'dart:convert';

final _requestIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _topicPattern = RegExp(r'^[0-9a-f]{64}$');
final _payloadPattern = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

/// Package-internal, pure parser so shared vectors do not require network timing.
sealed class ParseResult {
  const ParseResult();
}

final class RelayRequest extends ParseResult {
  const RelayRequest(this.op, this.requestId, this.topic, this.payload);

  final String op;
  final String requestId;
  final String topic;
  final String? payload;
}

final class RequestFailure extends ParseResult {
  const RequestFailure(this.code, [this.requestId]);

  final String code;
  final String? requestId;
}

ParseResult parseRequest(String text, {required int maxPayloadBytes}) {
  final Object? value;
  try {
    value = jsonDecode(text);
  } on FormatException {
    return const RequestFailure('bad_request');
  }
  if (value is! Map<String, dynamic>) {
    return const RequestFailure('bad_request');
  }
  final rawId = value['request_id'];
  final requestId =
      rawId is String && _exactMatch(_requestIdPattern, rawId) ? rawId : null;
  RequestFailure bad() => RequestFailure('bad_request', requestId);
  final op = value['op'];
  if (op is! String || requestId == null) return bad();
  if (op != 'subscribe' && op != 'unsubscribe' && op != 'publish') {
    return RequestFailure('unsupported_op', requestId);
  }
  final expectedFields = op == 'publish'
      ? const {'op', 'request_id', 'topic', 'payload'}
      : const {'op', 'request_id', 'topic'};
  if (value.length != expectedFields.length ||
      !value.keys.every(expectedFields.contains)) {
    return bad();
  }
  final topic = value['topic'];
  if (topic is! String || !_exactMatch(_topicPattern, topic)) return bad();
  String? payload;
  if (op == 'publish') {
    final rawPayload = value['payload'];
    if (rawPayload is! String ||
        rawPayload.isEmpty ||
        rawPayload.length % 4 != 0 ||
        rawPayload.length > ((maxPayloadBytes + 2) ~/ 3) * 4 ||
        !_exactMatch(_payloadPattern, rawPayload)) {
      return bad();
    }
    // base64Decode accepts normalization forms; the round trip deliberately
    // rejects missing padding, URL alphabet, whitespace and nonzero pad bits.
    try {
      final bytes = base64Decode(rawPayload);
      if (bytes.isEmpty ||
          bytes.length > maxPayloadBytes ||
          base64Encode(bytes) != rawPayload) {
        return bad();
      }
    } on FormatException {
      return bad();
    }
    payload = rawPayload;
  }
  return RelayRequest(op, requestId, topic, payload);
}

bool _exactMatch(RegExp pattern, String value) {
  final match = pattern.firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}
