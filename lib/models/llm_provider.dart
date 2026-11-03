/// Supported LLM providers / API shapes.
enum LlmProvider {
  /// OpenAI-compatible chat-completions endpoint.
  openAiCompatible,

  /// Google Gemini REST API.
  googleGemini,

  /// Anthropic Messages API.
  anthropic,
}

extension LlmProviderX on LlmProvider {
  String get label {
    switch (this) {
      case LlmProvider.openAiCompatible:
        return 'OpenAI Compatible';
      case LlmProvider.googleGemini:
        return 'Google Gemini';
      case LlmProvider.anthropic:
        return 'Anthropic';
    }
  }

  String get name => toString().split('.').last;

  /// Default base URL (everything before `/chat/completions`, `/messages`,
  /// or `/models/...`).
  String get defaultBaseUrl {
    switch (this) {
      case LlmProvider.openAiCompatible:
        return 'https://api.openai.com/v1';
      case LlmProvider.googleGemini:
        return 'https://generativelanguage.googleapis.com/v1beta';
      case LlmProvider.anthropic:
        return 'https://api.anthropic.com/v1';
    }
  }

  String get defaultModel {
    switch (this) {
      case LlmProvider.openAiCompatible:
        return 'gpt-4o-mini';
      case LlmProvider.googleGemini:
        return 'gemini-2.0-flash';
      case LlmProvider.anthropic:
        return 'claude-3-5-sonnet-20241022';
    }
  }

  static LlmProvider fromName(String? name) {
    return LlmProvider.values.firstWhere(
      (p) => p.name == name,
      orElse: () => LlmProvider.openAiCompatible,
    );
  }
}
