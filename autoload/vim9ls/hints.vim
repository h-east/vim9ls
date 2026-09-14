vim9script

# vim9ls - inlay hints: the type of a "var" that leaves it to the
# initializer, the parameter names at a call
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import './parse.vim'
import './refs.vim'
import './infer.vim'

# How many lines an initializer or a call may go on for.
const MORE_LINES = 30

# The kinds of the protocol.
export const KIND_TYPE = 1
export const KIND_PARAMETER = 2

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
        add(out, {line: s.line, col: s.name_end, label: ': ' .. type,
          kind: KIND_TYPE})
      endif
    endif
  endfor
enddef

# The type hints for the "var"s of lines "first" to "last" of a parsed
# script that leave the type to the initializer, as {line, col, label,
# kind}; the hint goes after the name.  A type that cannot be told gives no
# hint.
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

# The arguments of the call whose "(" is at byte "col" of line "lnum": where
# each starts, {line, col, text}, "text" being the argument up to the end of
# its line.  Empty when the ")" is not found within the lines allowed.
def Arguments(lines: list<string>, lnum: number, col: number,
    vim9_at: list<bool>): list<dict<any>>
  var args: list<dict<any>> = []
  var depth = 0
  var expect = true
  for at in range(lnum, min([lnum + MORE_LINES, len(lines) - 1]))
    var line = lines[at]
    var spans = refs.CodeSpans(line, vim9_at[at])
    var stop = CodeEnd(line, vim9_at[at])
    var pos = at == lnum ? col : 0
    while pos < stop
      # The inside of a string is not code; its quotes are.
      var skipped = false
      for [s_start, s_end] in spans.strings
        if s_start <= pos && pos < s_end
          pos = s_end
          skipped = true
          break
        endif
      endfor
      if skipped
        continue
      endif
      var c = line[pos]
      if depth == 1 && expect && c !~ '[[:space:],]'
        if c == ')'
          return args
        endif
        add(args, {line: at, col: pos, text: line[pos : stop - 1]})
        expect = false
      endif
      if c =~ '[[({]'
        depth += 1
      elseif c =~ '[\])}]'
        depth -= 1
        if depth == 0
          return args
        endif
      elseif c == ',' && depth == 1
        expect = true
      endif
      pos += 1
    endwhile
  endfor
  return []
enddef

# The parameter name hints for the calls that start on lines "first" to
# "last", as {line, col, label, kind}; the hint goes in front of the
# argument.  "Params" gives, for the name of a function, the names of its
# parameters and which of them the value before "->" fills, {names,
# method}; an empty Dict for a function it does not know.  An empty name
# gives no hint, nor does an argument that is the name itself.
export def ParamHints(parsed: dict<any>, lines: list<string>, first: number,
    last: number, Params: func(string): dict<any>): list<dict<any>>
  var vim9_at = parse.Vim9Lines(parsed, len(lines))
  var out: list<dict<any>> = []
  for lnum in range(first, min([last, len(lines) - 1]))
    var line = lines[lnum]
    # A function header is not a call.
    if matchstr(line, '^\s*\%(\%(export\|static\)\s\+\)*\zs\h\w*')
        =~ '^\%(def\|fu\%[nction]\)$'
      continue
    endif
    for token in refs.Tokens(line, vim9_at[lnum])
      # A call by name: not a member, whose parameters are not known here.
      if token.in_string || line[token.end] != '(' || token.prev == '.'
        continue
      endif
      var params = Params(token.text)
      if params->empty()
        continue
      endif
      var names: list<string> = params.names
      # The value before "->" fills one argument, the others shift past it.
      var filled = line[: token.col - 1] =~ '->$' ? params.method - 1 : -1
      var i = 0
      for arg in Arguments(lines, lnum, token.end, vim9_at)
        if i == filled
          i += 1
        endif
        var name = names->get(i, '')
        i += 1
        var text = matchstr(arg.text, '^[^,)]*')->trim()
        if name == '' || text == name
          continue
        endif
        add(out, {line: arg.line, col: arg.col, label: name .. ':',
          kind: KIND_PARAMETER})
      endfor
    endfor
  endfor
  return out
enddef
