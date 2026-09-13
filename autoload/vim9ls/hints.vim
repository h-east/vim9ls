vim9script

# vim9ls - inlay hints: the type of a "var" that leaves it to the initializer
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import './parse.vim'
import './refs.vim'
import './infer.vim'

# How many lines an initializer may go on for.
const MORE_LINES = 30

# The parameters of a "def" line "(a: number, b = 1): string" as [name,
# type] pairs, "any" for a parameter without a type, and the return type,
# "void" without one.  A header that goes on over lines is cut at its end.
def Header(detail: string): dict<any>
  var params: list<list<string>> = []
  var depth = 0
  var start = 1
  var stop = -1
  for i in range(strlen(detail))
    var c = detail[i]
    if c == '(' || c == '[' || c == '{' || c == '<'
      depth += 1
    elseif c == ')' || c == ']' || c == '}' || c == '>'
      depth -= 1
      if depth == 0
        stop = i
        break
      endif
    elseif c == ',' && depth == 1
      add(params, [detail[start : i - 1]])
      start = i + 1
    endif
  endfor
  if stop < 0
    return {params: [], returns: 'any'}
  endif
  if stop > start
    add(params, [detail[start : stop - 1]])
  endif
  for p in params
    var name = matchstr(p[0], '^\s*\%(\.\.\.\)\=\zs\h\w*')
    var type = matchstr(p[0], '^\s*\%(\.\.\.\)\=\h\w*\s*:\s*\zs[^=]*')->trim()
    p[0] = name
    add(p, type == '' ? 'any' : type)
  endfor
  var returns = matchstr(detail[stop + 1 :], '^\s*:\s*\zs.*')->trim()
  return {params: params->filter((_, p) => p[0] != ''),
    returns: returns == '' ? 'void' : returns}
enddef

# The type of function symbol "s" as a value: "func(number, any): string".
def FuncType(s: dict<any>): string
  if s->get('legacy', false)
    return 'func'
  endif
  var header = Header(s.detail)
  return 'func(' .. header.params->mapnew((_, p) => p[1])->join(', ') .. ')'
    .. (header.returns == 'void' ? '' : ': ' .. header.returns)
enddef

# The type of variable symbol "s": as declared, else as inferred before.
def VarType(s: dict<any>): string
  return s.detail != '' ? s.detail : s->get('inferred', 'any')
enddef

def IsVariable(s: dict<any>): bool
  return s.kind == parse.KIND_VARIABLE || s.kind == parse.KIND_CONSTANT
    || s.kind == parse.KIND_FIELD
enddef

def IsFunction(s: dict<any>): bool
  return s.kind == parse.KIND_FUNCTION || s.kind == parse.KIND_METHOD
enddef

# The variables seen at line "lnum" in "symbols", the children of one
# container, with their types: the ones declared above the line, still in
# scope.
def Visible(symbols: list<dict<any>>, lnum: number): dict<string>
  var vars: dict<string> = {}
  for s in symbols
    if IsVariable(s) && !s->get('param', false) && s.line < lnum
        && s->get('scope_end', lnum) >= lnum
      vars[s.name] = VarType(s)
    endif
  endfor
  return vars
enddef

# Where the code of "line" ends: before a comment, after the last string.
def CodeEnd(line: string, vim9: bool): number
  var spans = refs.CodeSpans(line, vim9)
  var stop = 0
  for [_, seg_end] in spans.code + spans.strings
    stop = max([stop, seg_end])
  endfor
  return stop
enddef

# How many brackets "text" leaves open, counted outside its strings.
def Open(text: string, vim9: bool): number
  var depth = 0
  for [seg_start, seg_end] in refs.CodeSpans(text, vim9).code
    for i in range(seg_start, seg_end - 1)
      if text[i] =~ '[[({]'
        depth += 1
      elseif text[i] =~ '[\])}]'
        depth -= 1
      endif
    endfor
  endfor
  return depth
enddef

# The initializer of the variable at "s", "var name = ...", from the "=" to
# its end, which may be lines further down.  Empty when there is none.
def Initializer(s: dict<any>, lines: list<string>, vim9_at: list<bool>): string
  var line = lines[s.line]
  var vim9 = vim9_at[s.line]
  var eq = matchend(line, '^\s*=\s*', s.name_end)
  if eq < 0 || line[eq] == '='
    return ''
  endif
  var text = line[eq : CodeEnd(line, vim9) - 1]
  var lnum = s.line
  while lnum + 1 < len(lines) && lnum < s.line + MORE_LINES
    var next = lines[lnum + 1]
    var code = next[: CodeEnd(next, vim9_at[lnum + 1]) - 1]->trim()
    if Open(text, vim9) <= 0
        && text !~ '\%(\.\.\|->\|=>\|[-+*/%?:,]\|&&\|||\)$'
        && code !~ '^\%(->\|\.\.\|[?:+*/%-]\|&&\|||\)'
      break
    endif
    text ..= ' ' .. code
    lnum += 1
  endwhile
  return text
enddef

# The hints for the variables in "symbols" and their functions; "scope" is
# the chain of function symbols around them, "top" the script-level symbols.
def Collect(symbols: list<dict<any>>, scope: list<dict<any>>,
    ctx: dict<any>, lines: list<string>, vim9_at: list<bool>,
    first: number, last: number, out: list<dict<any>>)
  for s in symbols
    if IsFunction(s)
      Collect(s.children, scope + [s], ctx, lines, vim9_at, first, last, out)
    elseif IsVariable(s) && !s->get('param', false) && s.detail == ''
        && vim9_at[s.line]
      var text = Initializer(s, lines, vim9_at)
      if text == ''
        continue
      endif
      # What the function can see: the script's variables, its parameters
      # and its own variables above, the innermost last.
      var vars = Visible(ctx.top, s.line)
      for f in scope
        for p in Header(f.detail).params
          vars[p[0]] = p[1]
        endfor
        extend(vars, Visible(f.children, s.line))
      endfor
      var type = infer.TypeOf(text, {vars: vars, funcs: ctx.funcs})
      s.inferred = type
      if type != 'any' && first <= s.line && s.line <= last
        add(out, {line: s.line, col: s.name_end, label: ': ' .. type})
      endif
    endif
  endfor
enddef

# The type hints for the "var"s of lines "first" to "last" of a parsed
# script that leave the type to the initializer, as {line, col, label}; the
# hint goes after the name.  A type that cannot be told gives no hint.
export def TypeHints(parsed: dict<any>, lines: list<string>, first: number,
    last: number): list<dict<any>>
  var funcs: dict<string> = {}
  for s in parse.AllSymbols(parsed.symbols)
    if IsFunction(s)
      funcs[s.name] = FuncType(s)
    endif
  endfor
  var out: list<dict<any>> = []
  Collect(parsed.symbols, [], {top: parsed.symbols, funcs: funcs}, lines,
    parse.Vim9Lines(parsed, len(lines)), first, last, out)
  return out
enddef
