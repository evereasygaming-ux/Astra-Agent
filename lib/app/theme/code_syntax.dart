import 'package:flutter/material.dart';

class CodeSyntax {
  static const Color foreground = Color(0xFFE2E4F0);
  static const Color keyword = Color(0xFFC69CFF);
  static const Color string = Color(0xFF8EE6B0);
  static const Color number = Color(0xFFFFC477);
  static const Color comment = Color(0xFF85879C);
  static const Color type = Color(0xFF67DDF4);
  static const Color function = Color(0xFF83A5FF);

  static const Set<String> _keywords = {
    'as',
    'async',
    'await',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'def',
    'default',
    'defer',
    'do',
    'else',
    'enum',
    'export',
    'extends',
    'false',
    'final',
    'finally',
    'for',
    'from',
    'func',
    'function',
    'go',
    'if',
    'implements',
    'import',
    'in',
    'interface',
    'let',
    'match',
    'new',
    'nil',
    'null',
    'package',
    'private',
    'protected',
    'public',
    'return',
    'self',
    'static',
    'struct',
    'super',
    'switch',
    'this',
    'throw',
    'throws',
    'trait',
    'true',
    'try',
    'type',
    'var',
    'void',
    'while',
  };

  static const Set<String> _types = {
    'bool',
    'boolean',
    'byte',
    'char',
    'double',
    'dynamic',
    'float',
    'int',
    'List',
    'Map',
    'Object',
    'String',
    'uint',
    'void',
  };

  static final RegExp _tokens = RegExp(
    r"""//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`[^`]*`|\b[A-Za-z_$][A-Za-z0-9_$]*\b|\b\d+(?:\.\d+)?\b""",
    multiLine: true,
  );

  static List<TextSpan> spans(
    String source, {
    required String language,
    TextStyle? baseStyle,
  }) {
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final match in _tokens.allMatches(source)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: source.substring(cursor, match.start)));
      }
      final token = match.group(0)!;
      final color = _tokenColor(token, source, match.end, language);
      spans.add(
        TextSpan(
          text: token,
          style: TextStyle(color: color),
        ),
      );
      cursor = match.end;
    }
    if (cursor < source.length) {
      spans.add(TextSpan(text: source.substring(cursor)));
    }
    if (spans.isEmpty) return [TextSpan(text: source, style: baseStyle)];
    return spans;
  }

  static Color _tokenColor(
    String token,
    String source,
    int end,
    String language,
  ) {
    if (token.startsWith('//') ||
        token.startsWith('/*') ||
        (token.startsWith('#') &&
            const {'python', 'yaml', 'shell', 'ruby'}.contains(language))) {
      return comment;
    }
    if (token.startsWith('"') ||
        token.startsWith("'") ||
        token.startsWith('`')) {
      return string;
    }
    if (RegExp(r'^\d').hasMatch(token)) return number;
    if (_keywords.contains(token)) return keyword;
    if (_types.contains(token) ||
        (token.length > 1 && token[0].toUpperCase() == token[0])) {
      return type;
    }
    var next = end;
    while (next < source.length && source[next].trim().isEmpty) {
      next++;
    }
    if (next < source.length && source[next] == '(') return function;
    return foreground;
  }
}

class SyntaxTextController extends TextEditingController {
  SyntaxTextController({required this.language});

  final String language;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return TextSpan(
      style: style?.copyWith(color: CodeSyntax.foreground),
      children: CodeSyntax.spans(text, language: language),
    );
  }
}

String languageForPath(String path) {
  final extension = path.split('.').last.toLowerCase();
  return switch (extension) {
    'dart' => 'dart',
    'go' => 'go',
    'js' || 'jsx' => 'javascript',
    'ts' || 'tsx' => 'typescript',
    'py' => 'python',
    'kt' || 'kts' => 'kotlin',
    'java' => 'java',
    'rs' => 'rust',
    'json' => 'json',
    'yaml' || 'yml' => 'yaml',
    'sh' || 'bash' => 'shell',
    'html' || 'xml' => 'markup',
    'css' => 'css',
    _ => 'plain',
  };
}
