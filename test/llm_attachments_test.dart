import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:type_the_clipboard/services/llm_service.dart';
import 'package:type_the_clipboard/views/ai_view.dart';

Uint8List _bytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => i % 251));

void main() {
  group('LlmAttachment', () {
    test('screenshot factory uses image/png', () {
      final a = LlmAttachment.screenshot(_bytes(8));
      expect(a.mimeType, 'image/png');
      expect(a.name, 'screenshot.png');
    });

    test('unknown media types fall back to image/png for Anthropic', () {
      final a = LlmAttachment(
        bytes: _bytes(4),
        mimeType: 'image/bmp',
        name: 'x.bmp',
      );
      expect(a.anthropicMediaType, 'image/png');
    });

    test('supported media types are kept for Anthropic', () {
      for (final type in ['image/png', 'image/jpeg', 'image/webp', 'image/gif']) {
        final a = LlmAttachment(bytes: _bytes(4), mimeType: type, name: 'x');
        expect(a.anthropicMediaType, type);
      }
    });
  });

  group('provider content parts', () {
    final png = _bytes(16);

    test('OpenAI returns a plain string without attachments', () {
      final content = LlmService.openAiContentParts('hello', const []);
      expect(content, isA<String>());
      expect(content, 'hello');
    });

    test('OpenAI emits one image_url part per attachment', () {
      final content = LlmService.openAiContentParts('hello', [
        LlmAttachment.screenshot(png),
        LlmAttachment.screenshot(png),
      ]) as List;
      expect(content, hasLength(3));
      expect(content.first, {'type': 'text', 'text': 'hello'});
      final image = content[1] as Map;
      expect(image['type'], 'image_url');
      expect(
        (image['image_url'] as Map)['url'],
        'data:image/png;base64,${base64Encode(png)}',
      );
      expect((content[2] as Map)['type'], 'image_url');
    });

    test('Gemini puts the text first and then inline_data parts', () {
      final parts = LlmService.geminiContentParts('hello', [
        LlmAttachment.screenshot(png),
      ]);
      expect(parts, hasLength(2));
      expect(parts.first, {'text': 'hello'});
      final inline = parts[1]['inline_data'] as Map;
      expect(inline['mime_type'], 'image/png');
      expect(inline['data'], base64Encode(png));
    });

    test('Gemini without attachments has only the text part', () {
      final parts = LlmService.geminiContentParts('hello', const []);
      expect(parts, [
        {'text': 'hello'},
      ]);
    });

    test('Anthropic returns a plain string without attachments', () {
      expect(LlmService.anthropicContentParts('hello', const []), 'hello');
    });

    test('Anthropic emits image blocks before the text block', () {
      final content = LlmService.anthropicContentParts('hello', [
        LlmAttachment.screenshot(png),
      ]) as List;
      expect(content, hasLength(2));
      final image = content.first as Map;
      expect(image['type'], 'image');
      final source = image['source'] as Map;
      expect(source['type'], 'base64');
      expect(source['media_type'], 'image/png');
      expect(source['data'], base64Encode(png));
      expect(content.last, {'type': 'text', 'text': 'hello'});
    });
  });

  group('mergeScreenshotText', () {
    test('returns null when both inputs are empty', () {
      expect(AiViewState.mergeScreenshotText(null, null), isNull);
      expect(AiViewState.mergeScreenshotText('  ', ''), isNull);
    });

    test('returns the captured text when OCR found nothing', () {
      expect(AiViewState.mergeScreenshotText('captured', null), 'captured');
    });

    test('returns the OCR text when nothing was captured', () {
      expect(AiViewState.mergeScreenshotText(null, 'ocr only'), 'ocr only');
    });

    test('appends OCR text under a marker', () {
      final merged = AiViewState.mergeScreenshotText('captured', 'ocr');
      expect(merged, contains('captured'));
      expect(merged, contains('--- TEXT READ FROM THE SCREENSHOT'));
      expect(merged, endsWith('ocr'));
    });

    test('marks the OCR text as potentially inaccurate', () {
    final merged = AiViewState.mergeScreenshotText('captured', 'ocr');
    expect(merged, contains('may contain OCR mistakes'));
  });

  test('does not append OCR that duplicates the selection', () {
      final merged = AiViewState.mergeScreenshotText(
        'Hello World',
        '  hello   world ',
      );
      expect(merged, 'Hello World');
    });

    test('does not append OCR that is a subset of the selection', () {
      final merged = AiViewState.mergeScreenshotText(
        'Line one. Second line here.',
        'second line',
      );
      expect(merged, 'Line one. Second line here.');
    });

    test('appends genuinely new OCR text', () {
      final merged = AiViewState.mergeScreenshotText(
        'Selection only',
        'Different words',
      );
      expect(merged, contains('Selection only'));
      expect(merged, contains('Different words'));
    });
  });
}
