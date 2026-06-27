// Thin C shim over libtree-sitter's API.
//
// The tree-sitter C API passes and returns `TSNode` *by value* (a small
// struct), which is painful to bind to from Haskell's FFI. Rather than wrestle
// with struct-by-value marshalling, we keep all of the node handling on the C
// side: this shim parses a source string, runs a highlight query over it,
// evaluates the query's predicates (so that e.g. `#match?`-gated captures
// behave correctly), and hands back a flat array of spans that Haskell can read
// with plain Storable peeks.

#include <regex.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <tree_sitter/api.h>

typedef struct {
  uint32_t start_byte;
  uint32_t end_byte;
  uint32_t capture_index;
  uint32_t pattern_index;
} TSHLSpan;

// --- a tiny growable char buffer, used when translating regexes -------------

typedef struct {
  char *data;
  size_t len;
  size_t cap;
} Buf;

static void buf_init(Buf *b) {
  b->cap = 32;
  b->len = 0;
  b->data = malloc(b->cap);
  if (b->data)
    b->data[0] = '\0';
}

static void buf_puts(Buf *b, const char *s) {
  if (!b->data)
    return;
  size_t n = strlen(s);
  while (b->len + n + 1 > b->cap) {
    b->cap *= 2;
    char *grown = realloc(b->data, b->cap);
    if (!grown) {
      free(b->data);
      b->data = NULL;
      return;
    }
    b->data = grown;
  }
  memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = '\0';
}

static void buf_putc(Buf *b, char c) {
  char s[2] = {c, '\0'};
  buf_puts(b, s);
}

// Translate the subset of PCRE/Rust regex syntax that shows up in tree-sitter
// highlight queries (\d \w \s and their negations) into POSIX ERE. Crucially,
// character-class escapes have to be rewritten differently inside a bracket
// expression ([...]) than outside it, e.g. "^[A-Z][A-Z\d_]*$" must become
// "^[A-Z][A-Z[:digit:]_]*$". The caller owns the returned buffer.
static char *translate_regex(const char *src, uint32_t len) {
  Buf b;
  buf_init(&b);
  int in_class = 0;
  for (uint32_t i = 0; i < len; i++) {
    char c = src[i];
    if (c == '\\' && i + 1 < len) {
      char n = src[i + 1];
      const char *rep = NULL;
      if (in_class) {
        switch (n) {
        case 'd':
          rep = "[:digit:]";
          break;
        case 'w':
          rep = "[:alnum:]_";
          break;
        case 's':
          rep = "[:space:]";
          break;
        }
      } else {
        switch (n) {
        case 'd':
          rep = "[[:digit:]]";
          break;
        case 'D':
          rep = "[^[:digit:]]";
          break;
        case 'w':
          rep = "[[:alnum:]_]";
          break;
        case 'W':
          rep = "[^[:alnum:]_]";
          break;
        case 's':
          rep = "[[:space:]]";
          break;
        case 'S':
          rep = "[^[:space:]]";
          break;
        }
      }
      if (rep) {
        buf_puts(&b, rep);
      } else {
        buf_putc(&b, '\\');
        buf_putc(&b, n);
      }
      i++;
      continue;
    }
    if (c == '[')
      in_class = 1;
    else if (c == ']')
      in_class = 0;
    buf_putc(&b, c);
  }
  return b.data;
}

// Return a pointer into `source` (and its length) for the first capture in
// `match` whose capture id is `cap_id`. Returns NULL if not present.
static const char *capture_text(const TSQueryMatch *match, uint32_t cap_id,
                                const char *source, uint32_t *out_len) {
  for (uint16_t k = 0; k < match->capture_count; k++) {
    TSQueryCapture c = match->captures[k];
    if (c.index == cap_id) {
      uint32_t s = ts_node_start_byte(c.node);
      uint32_t e = ts_node_end_byte(c.node);
      *out_len = e - s;
      return source + s;
    }
  }
  *out_len = 0;
  return NULL;
}

// Resolve a predicate-step argument to a byte string: either a literal (String
// step) or the text of a captured node (Capture step).
static const char *step_text(const TSQuery *query, const TSQueryMatch *match,
                             const char *source, TSQueryPredicateStep step,
                             uint32_t *out_len) {
  if (step.type == TSQueryPredicateStepTypeCapture) {
    return capture_text(match, step.value_id, source, out_len);
  }
  return ts_query_string_value_for_id(query, step.value_id, out_len);
}

static int bytes_eq(const char *a, uint32_t alen, const char *b,
                    uint32_t blen) {
  return a && b && alen == blen && memcmp(a, b, alen) == 0;
}

// Evaluate every filtering predicate attached to the match's pattern. Returns 1
// if the match should contribute its captures, 0 if a predicate rejected it.
// Unknown / non-filtering predicates and directives (#set!, #is?, ...) are
// ignored.
static int match_passes(const TSQuery *query, const TSQueryMatch *match,
                        const char *source) {
  uint32_t step_count;
  const TSQueryPredicateStep *steps =
      ts_query_predicates_for_pattern(query, match->pattern_index, &step_count);

  uint32_t i = 0;
  while (i < step_count) {
    // steps[i] names the predicate; args follow until a Done step.
    uint32_t name_len;
    const char *name =
        ts_query_string_value_for_id(query, steps[i].value_id, &name_len);

    int is_eq = 0, is_match = 0, is_anyof = 0, negate = 0;
    if (bytes_eq(name, name_len, "eq?", 3))
      is_eq = 1;
    else if (bytes_eq(name, name_len, "not-eq?", 7)) {
      is_eq = 1;
      negate = 1;
    } else if (bytes_eq(name, name_len, "match?", 6))
      is_match = 1;
    else if (bytes_eq(name, name_len, "not-match?", 10)) {
      is_match = 1;
      negate = 1;
    } else if (bytes_eq(name, name_len, "any-of?", 7))
      is_anyof = 1;
    else if (bytes_eq(name, name_len, "not-any-of?", 11)) {
      is_anyof = 1;
      negate = 1;
    }

    // Find the argument range [i+1, end) up to the Done step.
    uint32_t a = i + 1;
    uint32_t end = a;
    while (end < step_count && steps[end].type != TSQueryPredicateStepTypeDone)
      end++;

    int passed = 1; // default: non-filtering predicate, always "passes"

    if (is_eq && end - a >= 2) {
      uint32_t l0, l1;
      const char *t0 = step_text(query, match, source, steps[a], &l0);
      const char *t1 = step_text(query, match, source, steps[a + 1], &l1);
      int eq = bytes_eq(t0, l0, t1, l1);
      passed = negate ? !eq : eq;
    } else if (is_match && end - a >= 2) {
      uint32_t cl, rl;
      const char *captext = step_text(query, match, source, steps[a], &cl);
      const char *rawre = step_text(query, match, source, steps[a + 1], &rl);
      char *pattern = translate_regex(rawre, rl);
      // Copy the capture text into a NUL-terminated buffer for regexec.
      char *subject = malloc(cl + 1);
      int matched = 0;
      if (pattern && subject && captext) {
        memcpy(subject, captext, cl);
        subject[cl] = '\0';
        regex_t re;
        if (regcomp(&re, pattern, REG_EXTENDED | REG_NOSUB) == 0) {
          matched = (regexec(&re, subject, 0, NULL, 0) == 0);
          regfree(&re);
        }
      }
      free(pattern);
      free(subject);
      passed = negate ? !matched : matched;
    } else if (is_anyof && end - a >= 1) {
      uint32_t cl;
      const char *captext = step_text(query, match, source, steps[a], &cl);
      int found = 0;
      for (uint32_t k = a + 1; k < end; k++) {
        uint32_t sl;
        const char *s = step_text(query, match, source, steps[k], &sl);
        if (bytes_eq(captext, cl, s, sl)) {
          found = 1;
          break;
        }
      }
      passed = negate ? !found : found;
    }

    if (!passed)
      return 0;
    i = end + 1; // skip the Done step
  }
  return 1;
}

// Parse `source` with `language`, run `query` over the tree, evaluate
// predicates, and return a freshly malloc'd array of spans (one per surviving
// capture). The caller must free it with ts_hl_free. The span count is written
// to *out_count. Returns NULL on allocation/parse failure (with *out_count 0).
TSHLSpan *ts_hl_collect(const TSLanguage *language, const TSQuery *query,
                        const char *source, uint32_t source_len,
                        uint32_t *out_count) {
  *out_count = 0;

  TSParser *parser = ts_parser_new();
  if (!ts_parser_set_language(parser, language)) {
    ts_parser_delete(parser);
    return NULL;
  }

  TSTree *tree = ts_parser_parse_string(parser, NULL, source, source_len);
  if (!tree) {
    ts_parser_delete(parser);
    return NULL;
  }

  TSNode root = ts_tree_root_node(tree);
  TSQueryCursor *cursor = ts_query_cursor_new();
  ts_query_cursor_exec(cursor, query, root);

  size_t cap = 256;
  size_t n = 0;
  TSHLSpan *spans = malloc(cap * sizeof(TSHLSpan));

  TSQueryMatch match;
  while (spans && ts_query_cursor_next_match(cursor, &match)) {
    if (!match_passes(query, &match, source))
      continue;
    for (uint16_t k = 0; k < match.capture_count; k++) {
      TSQueryCapture c = match.captures[k];
      if (n == cap) {
        cap *= 2;
        TSHLSpan *grown = realloc(spans, cap * sizeof(TSHLSpan));
        if (!grown) {
          free(spans);
          spans = NULL;
          break;
        }
        spans = grown;
      }
      spans[n].start_byte = ts_node_start_byte(c.node);
      spans[n].end_byte = ts_node_end_byte(c.node);
      spans[n].capture_index = c.index;
      spans[n].pattern_index = match.pattern_index;
      n++;
    }
  }

  ts_query_cursor_delete(cursor);
  ts_tree_delete(tree);
  ts_parser_delete(parser);

  if (!spans)
    return NULL;
  *out_count = (uint32_t)n;
  return spans;
}

void ts_hl_free(TSHLSpan *spans) { free(spans); }
