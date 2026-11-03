import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:type_the_clipboard/models/llm_provider.dart';
import 'package:type_the_clipboard/services/settings_service.dart';

/// A short, user-facing LLM failure.
///
/// The full server response is written to the debug console by
/// [LlmService]; only [message] should ever reach the UI.
class LlmException implements Exception {
  final String message;
  final String? details;

  const LlmException(this.message, {this.details});

  @override
  String toString() => message;
}

/// Thrown when the caller cancels an in-flight request.
class LlmCancelledException implements Exception {
  const LlmCancelledException();

  @override
  String toString() => 'Cancelled';
}

/// Thin wrapper around several common LLM APIs.
///
/// The configured URL is treated as a **base URL** (e.g.
/// `https://api.openai.com/v1`). A full endpoint such as
/// `.../v1/chat/completions` or `.../v1` + `/chat/completions` is also
/// accepted and normalised, so users can paste either form in Settings.
class LlmService {
  static const Duration _timeout = Duration(seconds: 90);

  /// Default knowledgeable assistant used when the user has no custom prompt.
  static const String defaultSystemPrompt =
      'You are a helpful, knowledgeable assistant. You answer from the text '
      'or screenshot you are given.';

  /// Default task when none is supplied: the classic rephrase/correct flow.
  static const String defaultTask =
      'Rephrase or correct the text. Keep the meaning and tone.';

  final SettingsService _settings;

  LlmService(this._settings);

  bool get isConfigured => _settings.hasLlmConfig;

  /// System prompt with a guaranteed "text only" instruction appended.
  ///
  /// The user's own system prompt (Settings) is honoured when present and
  /// only extended with the task/output rules.
  String get _systemPrompt {
    final custom = _settings.llmSystemPrompt.trim();
    final base = custom.isEmpty ? defaultSystemPrompt : custom;
    return '$base\n\n'
        'The user input contains TASK, optional SOURCE TEXT, optional '
        'PREVIOUS RESULT and optional FOLLOW-UP REMARKS, and may include a '
        'screenshot of the selection.\n'
        '- Perform TASK on the source text (use the screenshot only as '
        'context for what the text is about).\n'
        '- If FOLLOW-UP REMARKS are present, apply them to the previous '
        'result instead of starting over.\n'
        '- Reply with the final replacement text only: no explanations, no '
        'preamble, no markdown fences and no surrounding quotes.';
  }

  /// Convenience wrapper for the default rephrase task.
  Future<String> rephrase(
    String text, {
    String? instruction,
    String? previousResult,
    String? remarks,
    Uint8List? image,
    Completer<void>? cancel,
  }) {
    return call(
      text,
      task: instruction,
      previousResult: previousResult,
      remarks: remarks,
      image: image,
      cancel: cancel,
    );
  }

  /// Runs [task] against [text].
  ///
  /// [remarks] lets the user refine a previous [previousResult]; both are
  /// folded into the prompt so the model keeps context across rounds.
  /// [image] is an optional screenshot (PNG) sent as visual context.
  /// Throws [LlmCancelledException] if [cancel] completes first.
  Future<String> call(
    String text, {
    String? task,
    String? previousResult,
    String? remarks,
    Uint8List? image,
    Completer<void>? cancel,
  }) async {
    if (!_settings.hasLlmConfig) {
      throw const LlmException(
        'LLM not configured. Check provider, URL, key and model in Settings.',
      );
    }

    final effectiveTask =
        (task != null && task.trim().isNotEmpty) ? task.trim() : defaultTask;

    final buffer = StringBuffer();
    buffer.writeln('TASK:');
    buffer.writeln(effectiveTask);
    if (text.trim().isNotEmpty) {
      buffer.writeln();
      buffer.writeln('SOURCE TEXT:');
      buffer.writeln(text);
    }
    if (previousResult != null && previousResult.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('PREVIOUS RESULT:');
      buffer.writeln(previousResult);
    }
    if (remarks != null && remarks.trim().isNotEmpty) {
      buffer.writeln();
      buffer.writeln('FOLLOW-UP REMARKS (apply these to the result):');
      buffer.writeln(remarks.trim());
    }

    final system = _systemPrompt;
    final user = buffer.toString();

    final Future<String> request;
    switch (_settings.llmProvider) {
      case LlmProvider.openAiCompatible:
        request = _openAiCompatible(system, user, image);
      case LlmProvider.googleGemini:
        request = _googleGemini(system, user, image);
      case LlmProvider.anthropic:
        request = _anthropic(system, user, image);
    }

    final result = await _guard(request, cancel);
    return _stripWrapping(result);
  }

  /// Races [request] against [cancel] and the request timeout.
  Future<String> _guard(
    Future<String> request,
    Completer<void>? cancel,
  ) async {
    final completer = Completer<String>();
    unawaited(
      request.then(
        (value) {
          if (!completer.isCompleted) completer.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
        },
      ),
    );
    cancel?.future.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(const LlmCancelledException());
      }
    });
    return completer.future.timeout(
      _timeout,
      onTimeout: () => throw const LlmException(
        'LLM request timed out after 90 seconds.',
      ),
    );
  }

  /// Normalises the user-supplied URL into a base URL for [suffix].
  ///
  /// - Strips trailing slashes.
  /// - Removes a trailing endpoint path that the caller will append again
  ///   (e.g. `.../v1/chat/completions` + `chat/completions`).
  Uri _endpoint(String suffix) {
    var base = _settings.llmUrl.trim().replaceAll(RegExp(r'/+$'), '');
    for (final known in [
      '/chat/completions',
      '/messages',
      '/completions',
    ]) {
      if (base.toLowerCase().endsWith(known)) {
        base = base.substring(0, base.length - known.length);
        break;
      }
    }
    return Uri.parse('$base/${suffix.replaceFirst(RegExp(r'^/+'), '')}');
  }

  String get _model {
    final model = _settings.llmModel.trim();
    return model.isEmpty ? _settings.llmProvider.defaultModel : model;
  }

  /// Decodes the response body as UTF-8 (the `http` package defaults to
  /// latin-1 when the server omits a charset, which garbles non-ASCII text).
  Map<String, dynamic> _decode(http.Response response) {
    final decoded = utf8.decode(response.bodyBytes);
    return jsonDecode(decoded) as Map<String, dynamic>;
  }

  /// Turns a non-200 response into a short [LlmException] while logging the
  /// full body to the debug console.
  LlmException _error(
    String provider,
    int status,
    Uri url,
    String body,
  ) {
    debugPrint('[LlmService] $provider $status at $url');
    debugPrint('[LlmService] body: $body');

    final serverMessage = _serverMessage(body);
    final message = serverMessage.isNotEmpty
        ? '$provider $status: $serverMessage'
        : '$provider request failed ($status). See debug console for details.';
    return LlmException(_truncate(message, 180), details: body);
  }

  static String _serverMessage(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        final error = json['error'];
        if (error is Map && error['message'] != null) {
          return error['message'].toString();
        }
        if (error is String) return error;
        if (json['message'] != null) return json['message'].toString();
      }
      if (json is List && json.isNotEmpty) {
        final first = json.first;
        if (first is Map && first['message'] != null) {
          return first['message'].toString();
        }
      }
    } catch (_) {
      // Not JSON; fall through to the raw body.
    }
    return body.trim();
  }

  /// Keeps messages readable after the first sentence.
  static String _truncate(String value, int max) {
    final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= max) return clean;
    final cut = clean.substring(0, max);
    final lastSpace = cut.lastIndexOf(' ');
    return '${lastSpace > max ~/ 2 ? cut.substring(0, lastSpace) : cut}...';
  }

  /// Removes a wrapping code fence or matched quotes the model may add.
  static String _stripWrapping(String value) {
    var text = value.trim();
    if (text.startsWith('```') && text.endsWith('```') && text.length > 6) {
      text = text.substring(3, text.length - 3);
      final newline = text.indexOf('\n');
      if (newline >= 0 && !text.substring(0, newline).contains(' ')) {
        text = text.substring(newline + 1);
      }
      text = text.trim();
    }
    for (final quote in ['"', "'", '\u201c']) {
      final close = quote == '\u201c' ? '\u201d' : quote;
      if (text.length > 1 && text.startsWith(quote) && text.endsWith(close)) {
        final inner = text.substring(1, text.length - 1);
        if (!inner.contains(quote) && !inner.contains(close)) {
          text = inner.trim();
        }
      }
    }
    return text;
  }

  Future<String> _openAiCompatible(
    String system,
    String user,
    Uint8List? image,
  ) async {
    final url = _endpoint('chat/completions');

    final response = await http
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            if (_settings.llmApiKey.isNotEmpty)
              'Authorization': 'Bearer ${_settings.llmApiKey}',
          },
          body: jsonEncode({
            'model': _model,
            'messages': [
              if (system.isNotEmpty) {'role': 'system', 'content': system},
              {
                'role': 'user',
                'content': image == null
                    ? user
                    : [
                        {'type': 'text', 'text': user},
                        {
                          'type': 'image_url',
                          'image_url': {
                            'url': 'data:image/png;base64,'
                                '${base64Encode(image)}',
                          },
                        },
                      ],
              },
            ],
            'temperature': 0.7,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw _error(
        'LLM',
        response.statusCode,
        url,
        utf8.decode(response.bodyBytes),
      );
    }

    final data = _decode(response);
    final choices = data['choices'] as List<dynamic>? ?? [];
    if (choices.isEmpty) {
      throw const LlmException('The model returned an empty response.');
    }
    return (choices.first['message']?['content'] ?? '').toString().trim();
  }

  Future<String> _googleGemini(
    String system,
    String user,
    Uint8List? image,
  ) async {
    final url = _endpoint(
      'models/$_model:generateContent?key=${_settings.llmApiKey}',
    );

    final response = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': user},
                  if (image != null)
                    {
                      'inline_data': {
                        'mime_type': 'image/png',
                        'data': base64Encode(image),
                      },
                    },
                ],
              },
            ],
            if (system.isNotEmpty)
              'systemInstruction': {
                'parts': [
                  {'text': system},
                ],
              },
            'generationConfig': {'temperature': 0.7},
          }),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw _error(
        'Gemini',
        response.statusCode,
        url,
        utf8.decode(response.bodyBytes),
      );
    }

    final data = _decode(response);
    final candidates = data['candidates'] as List<dynamic>? ?? [];
    if (candidates.isEmpty) {
      throw const LlmException('Gemini returned no candidates.');
    }
    final parts = candidates.first['content']?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      throw const LlmException('Gemini returned no content.');
    }
    return (parts.first['text'] ?? '').toString().trim();
  }

  Future<String> _anthropic(
    String system,
    String user,
    Uint8List? image,
  ) async {
    final url = _endpoint('messages');

    final response = await http
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': _settings.llmApiKey,
            'anthropic-version': '2023-06-01',
          },
          body: jsonEncode({
            'model': _model,
            'max_tokens': 1024,
            'temperature': 0.7,
            if (system.isNotEmpty) 'system': system,
            'messages': [
              {
                'role': 'user',
                'content': image == null
                    ? user
                    : [
                        {
                          'type': 'image',
                          'source': {
                            'type': 'base64',
                            'media_type': 'image/png',
                            'data': base64Encode(image),
                          },
                        },
                        {'type': 'text', 'text': user},
                      ],
              },
            ],
          }),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw _error(
        'Anthropic',
        response.statusCode,
        url,
        utf8.decode(response.bodyBytes),
      );
    }

    final data = _decode(response);
    final content = data['content'] as List<dynamic>? ?? [];
    if (content.isEmpty) {
      throw const LlmException('Anthropic returned no content.');
    }
    return content
        .where((c) => (c as Map)['type'] == 'text')
        .map((c) => (c as Map)['text']?.toString() ?? '')
        .join('\n')
        .trim();
  }
}
