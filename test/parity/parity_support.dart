/// Parity test support: load real Oracle/MySQL sample dumps through the engine
/// and measure how much of each dialect the shared core accepts.
///
/// The datasets live under the repo-root `parity/datasets/` tree and are
/// **git-ignored** (downloaded separately — see `parity/test-data.md`). When a
/// dataset is absent the helpers return null so tests can `skip` instead of
/// failing, keeping CI green without the data.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';

/// Repo-root `parity/datasets` directory, resolved relative to the current
/// working directory (the package root when running `dart test`). Returns null
/// when the datasets have not been downloaded.
Directory? parityDatasetsDir() {
  final candidates = <String>[
    'parity/datasets',
    '../parity/datasets',
  ];
  for (final c in candidates) {
    final d = Directory(c);
    if (d.existsSync()) return d;
  }
  return null;
}

/// Resolves the first existing file among [relativePaths] (each relative to
/// `parity/datasets/`). Returns null when none exist.
File? datasetFile(List<String> relativePaths) {
  final root = parityDatasetsDir();
  if (root == null) return null;
  for (final rel in relativePaths) {
    final f = File('${root.path}/$rel');
    if (f.existsSync()) return f;
  }
  return null;
}

/// Outcome of loading a SQL script statement-by-statement.
class LoadReport {
  int total = 0;
  int ok = 0;
  final List<String> failures = <String>[];

  /// Count of distinct failure "kinds" (first line of each error), so a parity
  /// run surfaces *what* the engine rejected, not just a count.
  final Map<String, int> failureKinds = <String, int>{};

  int get failed => total - ok;
  double get passRate => total == 0 ? 0 : ok / total;

  void record(String statement, Object? error) {
    total++;
    if (error == null) {
      ok++;
      return;
    }
    final kind = _errorKind(error);
    failureKinds[kind] = (failureKinds[kind] ?? 0) + 1;
    if (failures.length < 25) {
      final snippet = statement.length > 80
          ? '${statement.substring(0, 80)}…'
          : statement;
      failures.add('$kind  «${snippet.replaceAll('\n', ' ')}»');
    }
  }

  String summary(String label) {
    final b = StringBuffer()
      ..writeln('── parity load: $label ──')
      ..writeln('  statements : $total')
      ..writeln('  succeeded  : $ok (${(passRate * 100).toStringAsFixed(1)}%)')
      ..writeln('  failed     : $failed');
    if (failureKinds.isNotEmpty) {
      b.writeln('  top rejections:');
      final sorted = failureKinds.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sorted.take(8)) {
        b.writeln('    ${e.value.toString().padLeft(4)}×  ${e.key}');
      }
    }
    return b.toString();
  }
}

String _errorKind(Object error) {
  var msg = error.toString();
  final nl = msg.indexOf('\n');
  if (nl >= 0) msg = msg.substring(0, nl);
  if (msg.length > 120) msg = '${msg.substring(0, 120)}…';
  return msg.trim();
}

/// Executes every statement in [script] against [db], tallying success and
/// failure into a [LoadReport]. Errors are swallowed (recorded) so one
/// unsupported statement does not abort the whole load — a parity run wants the
/// full picture. Pass [stopOnError] to fail fast instead.
Future<LoadReport> loadScript(
  Database db,
  String script, {
  bool stopOnError = false,
}) async {
  final report = LoadReport();
  for (final stmt in splitSqlStatements(script)) {
    if (stmt.trim().isEmpty) continue;
    try {
      await db.execute(stmt);
      report.record(stmt, null);
    } catch (e) {
      report.record(stmt, e);
      if (stopOnError) rethrow;
    }
  }
  return report;
}

/// Splits a SQL dump into individual statements.
///
/// Handles the quirks found in real Oracle/MySQL sample dumps:
///   * `--` and `#` line comments, `/* … */` block comments (incl. MySQL's
///     `/*! … */` version-gated directives — stripped wholesale).
///   * single/double/backtick quoted literals with `\` and doubled-quote
///     escapes (so a `;` inside a string is not a statement boundary).
///   * `DELIMITER` redefinition (used around triggers/procedures).
List<String> splitSqlStatements(String input) {
  final statements = <String>[];
  final buf = StringBuffer();
  var delimiter = ';';
  var atLineStart = true;
  var i = 0;
  final n = input.length;

  bool startsWith(String needle, int pos) {
    if (pos + needle.length > n) return false;
    for (var k = 0; k < needle.length; k++) {
      if (input[pos + k] != needle[k]) return false;
    }
    return true;
  }

  while (i < n) {
    final c = input[i];

    // DELIMITER directive (line-oriented, MySQL dumps).
    if (atLineStart &&
        (startsWith('DELIMITER ', i) || startsWith('delimiter ', i))) {
      var j = i + 'DELIMITER '.length;
      final start = j;
      while (j < n && input[j] != '\n' && input[j] != '\r') {
        j++;
      }
      final newDelim = input.substring(start, j).trim();
      if (newDelim.isNotEmpty) delimiter = newDelim;
      i = j;
      atLineStart = false;
      continue;
    }

    // Line comments.
    if (c == '-' && i + 1 < n && input[i + 1] == '-') {
      while (i < n && input[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '#') {
      while (i < n && input[i] != '\n') {
        i++;
      }
      continue;
    }

    // Block comments (including /*! … */).
    if (c == '/' && i + 1 < n && input[i + 1] == '*') {
      i += 2;
      while (i + 1 < n && !(input[i] == '*' && input[i + 1] == '/')) {
        i++;
      }
      i += 2;
      atLineStart = false;
      continue;
    }

    // Quoted literals / identifiers.
    if (c == "'" || c == '"' || c == '`') {
      final quote = c;
      buf.write(c);
      i++;
      while (i < n) {
        final d = input[i];
        if (d == r'\' && i + 1 < n) {
          buf.write(d);
          buf.write(input[i + 1]);
          i += 2;
          continue;
        }
        buf.write(d);
        i++;
        if (d == quote) {
          if (i < n && input[i] == quote) {
            buf.write(input[i]);
            i++;
            continue;
          }
          break;
        }
      }
      atLineStart = false;
      continue;
    }

    // Statement delimiter.
    if (startsWith(delimiter, i)) {
      final stmt = buf.toString().trim();
      if (stmt.isNotEmpty) statements.add(stmt);
      buf.clear();
      i += delimiter.length;
      atLineStart = false;
      continue;
    }

    buf.write(c);
    atLineStart = c == '\n';
    i++;
  }

  final tail = buf.toString().trim();
  if (tail.isNotEmpty) statements.add(tail);
  return statements;
}

/// Strips SQL*Plus / sqlplus client directives from an Oracle script so only
/// executable SQL reaches the engine. Removes `rem` comments and whole lines
/// that begin with a client-only command (`SET`, `PROMPT`, `SPOOL`, `DEFINE`,
/// `WHENEVER`, `CONNECT`, `COLUMN`, `@`, `SHOW`) plus a lone `/` run-buffer
/// terminator. These are interpreted by SQL*Plus, never sent to the server.
String stripSqlPlusLines(String script) {
  const directives = <String>[
    'rem', 'prompt', 'set ', 'spool', 'define', 'undefine', 'whenever',
    'connect', 'column ', 'show ', 'ttitle', 'btitle', 'accept', 'pause',
  ];
  final kept = <String>[];
  for (final raw in script.split('\n')) {
    final line = raw.trimLeft();
    final lower = line.toLowerCase();
    if (line == '/' || lower == 'rem') continue;
    if (lower.startsWith('@')) continue;
    if (directives.any(lower.startsWith)) continue;
    kept.add(raw);
  }
  return kept.join('\n');
}

/// Names of base tables the engine currently holds, via `sqlite_master`
/// (the SQLite-core catalog the engine is rooted on).
Future<Set<String>> tableNames(Database db) async {
  try {
    final r = await db.execute(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    return r.rows.map((row) => '${row.first}'.toLowerCase()).toSet();
  } catch (_) {
    return <String>{};
  }
}
