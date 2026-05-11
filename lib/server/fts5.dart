/// Minimal but real FTS5 query language for the engine's `MATCH` operator.
///
/// Supported syntax (a subset of SQLite's FTS5 query grammar):
///   * Bare token              — token must appear in the document
///   * "phrase here"           — exact adjacent token sequence
///   * prefix*                 — any token starting with `prefix`
///   * a AND b   /   a b       — implicit AND between terms
///   * a OR b                  — disjunction
///   * NOT a     /   - a       — negation (binary form `a NOT b` also accepted)
///   * (a OR b) c              — parentheses for grouping
///
/// Tokenization splits on non-word characters and lowercases. Tokens are
/// compared case-insensitively. Phrase matches require tokens to appear
/// at consecutive positions in the document; prefix matches require any
/// document token to start with the given prefix (case-insensitive).
///
/// This file is pure; it doesn't depend on any other engine type, so it
/// can be unit-tested in isolation.
library;

/// Split [text] into lower-cased word tokens. The same tokenizer is used
/// for both indexing and query terms.
List<String> tokenizeFts(String text) {
  final out = <String>[];
  final re = RegExp(r'[A-Za-z0-9_]+');
  for (final m in re.allMatches(text)) {
    out.add(m.group(0)!.toLowerCase());
  }
  return out;
}

/// Match [query] against the contents of a single document string.
///
/// Returns true iff the query expression evaluates to true on the
/// document's token sequence. Empty queries (whitespace only) match
/// every document, mirroring SQLite's behaviour.
bool fts5Match(String document, String query) {
  final node = parseFts5Query(query);
  if (node == null) return true; // empty query
  final tokens = tokenizeFts(document);
  return node.evaluate(tokens);
}

/// Boolean AST node produced by [parseFts5Query]. Public so tests and the
/// (future) inverted-index path can introspect compiled queries.
abstract class Fts5Node {
  bool evaluate(List<String> tokens);
}

class _TermNode extends Fts5Node {
  final String term;
  _TermNode(this.term);
  @override
  bool evaluate(List<String> tokens) => tokens.contains(term);
}

class _PrefixNode extends Fts5Node {
  final String prefix;
  _PrefixNode(this.prefix);
  @override
  bool evaluate(List<String> tokens) => tokens.any((t) => t.startsWith(prefix));
}

class _PhraseNode extends Fts5Node {
  final List<String> phrase;
  _PhraseNode(this.phrase);
  @override
  bool evaluate(List<String> tokens) {
    if (phrase.isEmpty) return true;
    outer:
    for (var i = 0; i + phrase.length <= tokens.length; i++) {
      for (var j = 0; j < phrase.length; j++) {
        if (tokens[i + j] != phrase[j]) continue outer;
      }
      return true;
    }
    return false;
  }
}

class _AndNode extends Fts5Node {
  final List<Fts5Node> children;
  _AndNode(this.children);
  @override
  bool evaluate(List<String> tokens) =>
      children.every((c) => c.evaluate(tokens));
}

class _OrNode extends Fts5Node {
  final List<Fts5Node> children;
  _OrNode(this.children);
  @override
  bool evaluate(List<String> tokens) => children.any((c) => c.evaluate(tokens));
}

class _NotNode extends Fts5Node {
  final Fts5Node child;
  _NotNode(this.child);
  @override
  bool evaluate(List<String> tokens) => !child.evaluate(tokens);
}

/// Parse [query]. Returns null when the query is empty or whitespace.
Fts5Node? parseFts5Query(String query) {
  final p = _QueryParser(query);
  p._skipWs();
  if (p._eof) return null;
  final node = p._parseOr();
  p._skipWs();
  if (!p._eof) {
    throw FormatException(
        'Unexpected character "${p._src[p._pos]}" at offset ${p._pos} '
        'in FTS5 query: $query');
  }
  return node;
}

class _QueryParser {
  final String _src;
  int _pos = 0;
  _QueryParser(this._src);

  bool get _eof => _pos >= _src.length;

  void _skipWs() {
    while (!_eof && _src.codeUnitAt(_pos) <= 0x20) {
      _pos++;
    }
  }

  /// Tries to consume the keyword [kw] as a standalone word. Case-insensitive.
  bool _matchKeyword(String kw) {
    _skipWs();
    if (_pos + kw.length > _src.length) return false;
    final slice = _src.substring(_pos, _pos + kw.length);
    if (slice.toUpperCase() != kw) return false;
    // Must be followed by EOF or non-word.
    final after = _pos + kw.length;
    if (after < _src.length) {
      final c = _src.codeUnitAt(after);
      final isWord = (c >= 0x30 && c <= 0x39) || // 0-9
          (c >= 0x41 && c <= 0x5a) || // A-Z
          (c >= 0x61 && c <= 0x7a) || // a-z
          c == 0x5f; // _
      if (isWord) return false;
    }
    _pos = after;
    return true;
  }

  Fts5Node _parseOr() {
    final parts = <Fts5Node>[_parseAnd()];
    while (true) {
      final save = _pos;
      if (_matchKeyword('OR')) {
        parts.add(_parseAnd());
      } else {
        _pos = save;
        break;
      }
    }
    return parts.length == 1 ? parts.single : _OrNode(parts);
  }

  Fts5Node _parseAnd() {
    final parts = <Fts5Node>[];
    while (true) {
      _skipWs();
      if (_eof) break;
      // OR / closing paren ends the AND chain.
      final save = _pos;
      if (_matchKeyword('OR')) {
        _pos = save;
        break;
      }
      if (_src[_pos] == ')') break;
      // `a NOT b` -> a AND (NOT b)
      if (_matchKeyword('AND')) continue; // implicit
      if (_matchKeyword('NOT')) {
        parts.add(_NotNode(_parseFactor()));
        continue;
      }
      parts.add(_parseFactor());
    }
    if (parts.isEmpty) {
      throw const FormatException('Empty AND clause in FTS5 query');
    }
    return parts.length == 1 ? parts.single : _AndNode(parts);
  }

  Fts5Node _parseFactor() {
    _skipWs();
    if (_eof) throw const FormatException('Unexpected end of FTS5 query');
    final c = _src[_pos];
    if (c == '(') {
      _pos++;
      final inner = _parseOr();
      _skipWs();
      if (_eof || _src[_pos] != ')') {
        throw FormatException(
            'Expected ")" at offset $_pos in FTS5 query: $_src');
      }
      _pos++;
      return inner;
    }
    if (c == '-') {
      _pos++;
      return _NotNode(_parseFactor());
    }
    if (c == '"') {
      return _parsePhrase();
    }
    return _parseTermOrPrefix();
  }

  Fts5Node _parsePhrase() {
    // Consume opening quote.
    _pos++;
    final buf = StringBuffer();
    while (!_eof && _src[_pos] != '"') {
      buf.write(_src[_pos]);
      _pos++;
    }
    if (_eof) {
      throw FormatException('Unterminated phrase in FTS5 query: $_src');
    }
    _pos++; // closing quote
    return _PhraseNode(tokenizeFts(buf.toString()));
  }

  Fts5Node _parseTermOrPrefix() {
    final start = _pos;
    while (!_eof) {
      final ch = _src.codeUnitAt(_pos);
      final isWord = (ch >= 0x30 && ch <= 0x39) ||
          (ch >= 0x41 && ch <= 0x5a) ||
          (ch >= 0x61 && ch <= 0x7a) ||
          ch == 0x5f;
      if (!isWord) break;
      _pos++;
    }
    if (_pos == start) {
      throw FormatException(
          'Unexpected character "${_src[_pos]}" at offset $_pos '
          'in FTS5 query: $_src');
    }
    final raw = _src.substring(start, _pos).toLowerCase();
    if (!_eof && _src[_pos] == '*') {
      _pos++;
      return _PrefixNode(raw);
    }
    return _TermNode(raw);
  }
}

// ---------------------------------------------------------------------------
// Ranking
// ---------------------------------------------------------------------------

/// Per-document term-frequency score useful as a relevance signal in
/// `ORDER BY`. The result is the sum over query terms of their raw
/// occurrence counts in [document] (after the same tokenization used by
/// [fts5Match]). Phrases count as 1 per non-overlapping occurrence;
/// prefix terms count occurrences of every matching token. Documents
/// that don't match the query at all score 0.
double fts5TermFrequency(String document, String query) {
  final node = parseFts5Query(query);
  if (node == null) return 0.0;
  final tokens = tokenizeFts(document);
  return _scoreNode(node, tokens);
}

/// BM25-style score for [document] vs [query]. With only a single
/// document of context (no corpus), the inverse-document-frequency
/// term collapses to a constant, so this is effectively the saturated
/// term-frequency form of BM25:
///
///   score = sum_t (tf_t * (k1 + 1)) / (tf_t + k1 * (1 - b + b * dl/avgdl))
///
/// where `dl` is this document's token count and `avgdl` is taken as
/// the document's own length when no corpus is available (so the
/// length-normalisation factor reduces to `k1 + 1`). Suitable for
/// `ORDER BY bm25(body, 'query') DESC`. SQLite's `bm25()` returns
/// negative scores so smaller-is-better; this function returns positive
/// scores so the more familiar `DESC` ordering yields best matches first.
double fts5Bm25(String document, String query,
    {double k1 = 1.2, double b = 0.75}) {
  final node = parseFts5Query(query);
  if (node == null) return 0.0;
  final tokens = tokenizeFts(document);
  if (tokens.isEmpty) return 0.0;
  if (!node.evaluate(tokens)) return 0.0;
  // Single-doc context: dl == avgdl, so the length normalisation cancels.
  // Each TF contribution becomes tf * (k1+1) / (tf + k1).
  final tf = _scoreNode(node, tokens);
  if (tf <= 0) return 0.0;
  return tf * (k1 + 1) / (tf + k1);
}

double _scoreNode(Fts5Node node, List<String> tokens) {
  if (node is _TermNode) {
    return tokens.where((t) => t == node.term).length.toDouble();
  }
  if (node is _PrefixNode) {
    return tokens.where((t) => t.startsWith(node.prefix)).length.toDouble();
  }
  if (node is _PhraseNode) {
    if (node.phrase.isEmpty) return 0.0;
    var count = 0;
    for (var i = 0; i + node.phrase.length <= tokens.length;) {
      var ok = true;
      for (var j = 0; j < node.phrase.length; j++) {
        if (tokens[i + j] != node.phrase[j]) {
          ok = false;
          break;
        }
      }
      if (ok) {
        count++;
        i += node.phrase.length; // non-overlapping
      } else {
        i++;
      }
    }
    return count.toDouble();
  }
  if (node is _AndNode) {
    // Every child must match; total score is the sum.
    var total = 0.0;
    for (final c in node.children) {
      final s = _scoreNode(c, tokens);
      if (s == 0 && !c.evaluate(tokens)) return 0.0;
      total += s;
    }
    return total;
  }
  if (node is _OrNode) {
    var total = 0.0;
    for (final c in node.children) {
      total += _scoreNode(c, tokens);
    }
    return total;
  }
  if (node is _NotNode) {
    // NOT contributes nothing to the score but acts as a hard filter.
    return node.evaluate(tokens) ? 0.0 : 0.0;
  }
  return 0.0;
}
