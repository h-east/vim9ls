vim9script

# vim9ls - where a name is defined and where it is used
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './parse.vim'

# What a name is made of, "<SID>" aside.
export const NAME = '[[:alnum:]_:#]'

# The name without its script prefix.
export def Core(name: string): string
  return Split(name)[1]
enddef

# The parts of "line" that are code: not a string and not a comment.  Each
# part is [start, end) in bytes.  The strings come along separately, since a
# function name may be spelled inside one.
export def CodeSpans(line: string, vim9: bool): dict<list<list<number>>>
  var code: list<list<number>> = []
  var strings: list<list<number>> = []
  # A legacy comment takes the whole line; elsewhere a double quote opens a
  # string.
  if !vim9 && line =~ '^\s*"'
    return {code: code, strings: strings}
  endif
  var len = strlen(line)
  var at = 0
  while at < len
    # The next thing that is not code: a quote, or "#" that starts a comment.
    var m = matchstrpos(line, vim9 ? '''\|"\|\%(^\|\s\)\zs#' : '''\|"', at)
    if m[1] < 0 || m[0] == '#'
      var stop = m[1] < 0 ? len : m[1]
      if stop > at
        add(code, [at, stop])
      endif
      break
    endif
    if m[1] > at
      add(code, [at, m[1]])
    endif
    # Two single quotes in a row stand for one; a backslash escapes a double
    # quote.  Without the closing quote the string runs to the end.
    var s = matchstrpos(line, m[0] == "'" ? "'\\%(''\\|[^']\\)*'"
      : '"\%(\\.\|[^"\\]\)*"', m[1])
    if s[1] != m[1]
      add(strings, [m[1] + 1, len])
      break
    endif
    add(strings, [m[1] + 1, s[2] - 1])
    at = s[2]
  endwhile
  return {code: code, strings: strings}
enddef

# The names used in "line", each with where it is and what is in front of
# it.  Numbers are left out.  A name inside a string is only reported when
# the string holds nothing else, which is how a function is named in a
# string.
export def Tokens(line: string, vim9: bool): list<dict<any>>
  var spans = CodeSpans(line, vim9)
  var tokens: list<dict<any>> = []
  for [seg_start, seg_end] in spans.code
    var pos = seg_start
    while pos < seg_end
      var m = matchstrpos(line, '\%(<SID>\)\=' .. NAME .. '\+', pos)
      if m[1] < 0 || m[1] >= seg_end
        break
      endif
      var col = m[1]
      var stop_col = min([m[2], seg_end])
      var text = line[col : stop_col - 1]
      pos = stop_col
      if text !~ '^\%(<SID>\)\=\h'
        continue
      endif
      var prev = col == 0 ? '' : line[col - 1]
      add(tokens, {text: text, col: col, end: stop_col, prev: prev,
        in_string: false})
    endwhile
  endfor
  for [seg_start, seg_end] in spans.strings
    var text = line[seg_start : seg_end - 1]
    if text =~ '^\*\=\%(<SID>\|[sg]:\)\=\h' .. NAME .. '*$'
      var col = seg_start + (text[0] == '*' ? 1 : 0)
      add(tokens, {text: text[col - seg_start :], col: col, end: seg_end,
        prev: '', in_string: true})
    endif
  endfor
  return tokens
enddef

# The name without its script prefix, and the prefix.
def Split(name: string): list<string>
  if name =~ '^<SID>'
    return ['s:', name[5 :]]
  endif
  var scope = matchstr(name, '^[sgbwtlv]:')
  return [scope, name[strlen(scope) :]]
enddef

const MEMBER_KINDS = [parse.KIND_FIELD, parse.KIND_METHOD,
  parse.KIND_ENUM_MEMBER]

# Whether the token is a use of "symbol": the same name and, for a member,
# after a dot.  Under Vim9 rules the "s:" prefix may be spelled or left out;
# in legacy script "Foo" is a global function and "s:Foo" another.
def Matches(token: dict<any>, symbol: dict<any>, vim9: bool): bool
  var [tscope, tname] = Split(token.text)
  var [sscope, sname] = Split(symbol.name)
  if tname !=# sname
    return false
  endif
  var member = index(MEMBER_KINDS, symbol.kind) >= 0
  if member != (token.prev == '.')
    return false
  endif
  if token.in_string && symbol.kind != parse.KIND_FUNCTION
      && symbol.kind != parse.KIND_METHOD
    return false
  endif
  if vim9 && (sscope == '' || sscope == 's:')
    return tscope == '' || tscope == 's:'
  endif
  return tscope == sscope
enddef

# Every symbol with the lines its name is visible in: a member and a
# top-level name everywhere, anything else inside the function that holds it.
def Scoped(symbols: list<dict<any>>, first: number, last: number,
    out: list<dict<any>>)
  for s in symbols
    var in_function = s.kind == parse.KIND_FUNCTION
      || s.kind == parse.KIND_METHOD
    add(out, {symbol: s, first: first, last: last})
    var child_first = in_function ? s.line : first
    var child_last = in_function ? s.end_line : last
    Scoped(s.children, child_first, child_last, out)
  endfor
enddef

# Every symbol with its scope, by the name without its script prefix, for
# looking many names up in one parse.
export def Index(parsed: dict<any>): dict<list<dict<any>>>
  var scoped: list<dict<any>> = []
  Scoped(parsed.symbols, 0, 1000000000, scoped)
  var index: dict<list<dict<any>>> = {}
  for entry in scoped
    var core = Core(entry.symbol.name)
    if !index->has_key(core)
      index[core] = []
    endif
    add(index[core], entry)
  endfor
  return index
enddef

# The symbol a token at "lnum" stands for in "index", or null_dict.  With
# several to choose from, the one whose scope is the smallest wins.
export def Find(index: dict<list<dict<any>>>, token: dict<any>, lnum: number,
    vim9: bool): dict<any>
  var best: dict<any> = null_dict
  for entry in index->get(Core(token.text), [])
    if !Matches(token, entry.symbol, vim9) || lnum < entry.first
        || lnum > entry.last
      continue
    endif
    if best == null_dict || entry.last - entry.first < best.last - best.first
      best = entry
    endif
  endfor
  return best == null_dict ? null_dict : best.symbol
enddef

# Find() for one token, with the index made on the spot.  In a Vim9 script
# "s:Name" and "Name" are the same, also in a legacy function of it.
export def Resolve(parsed: dict<any>, token: dict<any>,
    lnum: number): dict<any>
  return Find(Index(parsed), token, lnum,
    parsed.vim9 || parse.InVim9At(parsed, lnum))
enddef

# The token at byte "col" in "line", or the one just before it.
export def TokenAt(line: string, col: number, vim9: bool): dict<any>
  for token in Tokens(line, vim9)
    if token.col <= col && col < token.end
      return token
    endif
  endfor
  for token in Tokens(line, vim9)
    if token.end == col
      return token
    endif
  endfor
  return null_dict
enddef

# Where "symbol" is used in "lines": the spans of the name proper, without
# the script prefix, so that they can be renamed as one.  The declaration is
# the first entry when "declaration" is true.
export def References(parsed: dict<any>, lines: list<string>,
    symbol: dict<any>, declaration: bool): list<dict<number>>
  var out: list<dict<number>> = []
  var [sscope, _] = Split(symbol.name)
  var decl_col = symbol.name_col + strlen(sscope)
  if declaration
    out->add({line: symbol.line, col: decl_col, end: symbol.name_end})
  endif
  var core = Core(symbol.name)
  var vim9_at = parse.Vim9Lines(parsed, len(lines))
  var index = Index(parsed)
  for lnum in range(len(lines))
    # Only a line that holds the name at all needs reading.
    if stridx(lines[lnum], core) < 0
      continue
    endif
    var vim9 = vim9_at[lnum]
    var same = parsed.vim9 || vim9
    for token in Tokens(lines[lnum], vim9)
      if Matches(token, symbol, same)
          && Find(index, token, lnum, same) is symbol
        var skip = strlen(token.text) - strlen(Core(token.text))
        var col = token.col + skip
        if !(lnum == symbol.line && col == decl_col)
          out->add({line: lnum, col: col, end: token.end})
        endif
      endif
    endfor
  endfor
  return out
enddef

# Where a name of another script, "target" as {path, symbol, autoload}, is
# used in "lines", the script at "path": after the alias of an import of that
# file, or as the autoload name spelled out.  The spans are of the name
# proper: after the alias or the last "#".
export def UsesOf(parsed: dict<any>, lines: list<string>, path: string,
    target: dict<any>): list<dict<number>>
  var name = matchstr(target.symbol.name, '[^#]*$')
  var aliases: list<string> = []
  for s in parse.AllSymbols(parsed.symbols)
    if s.kind == parse.KIND_MODULE && ImportFile(path, s.detail,
        s->get('autoload', false)) ==# target.path
      add(aliases, s.name)
    endif
  endfor
  var out: list<dict<number>> = []
  var vim9_at = parse.Vim9Lines(parsed, len(lines))
  for lnum in range(len(lines))
    var line = lines[lnum]
    if stridx(line, name) < 0
      continue
    endif
    for token in Tokens(line, vim9_at[lnum])
      if target.autoload != '' && token.text ==# target.autoload
        out->add({line: lnum, col: token.end - strlen(name), end: token.end})
      elseif token.prev == '.' && token.text ==# name && token.col >= 2
          && index(aliases,
            matchstr(line[: token.col - 2], NAME .. '\+$')) >= 0
        out->add({line: lnum, col: token.col, end: token.end})
      endif
    endfor
  endfor
  return out
enddef

# The file an import statement names, when it can be found from "path", the
# script that holds the import.  An autoload import is looked for in the
# autoload directories above the script and in $VIMRUNTIME.
export def ImportFile(path: string, spec: string, autoload: bool): string
  if !autoload
    var file = spec =~ '^\.\.\=/' ? fnamemodify(path, ':h') .. '/' .. spec
      : spec
    return filereadable(file) ? fnamemodify(file, ':p') : ''
  endif
  var rel = spec =~ '\.vim$' ? spec : spec .. '.vim'
  return AutoloadFile(path, rel)
enddef

# "rel" under an autoload directory that applies to the script "path".
export def AutoloadFile(path: string, rel: string): string
  var dir = fnamemodify(path, ':p:h')
  var dirs: list<string> = []
  while true
    add(dirs, dir .. '/autoload')
    var up = fnamemodify(dir, ':h')
    if up == dir
      break
    endif
    dir = up
  endwhile
  add(dirs, $VIMRUNTIME .. '/autoload')
  for d in dirs
    var file = d .. '/' .. rel
    if filereadable(file)
      return fnamemodify(file, ':p')
    endif
  endfor
  return ''
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
