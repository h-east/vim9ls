vim9script

# vim9ls - completion candidates
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './parse.vim'

# LSP CompletionItemKind values.
const KIND_FUNCTION = 3
const KIND_VARIABLE = 6
const KIND_CLASS = 7
const KIND_INTERFACE = 8
const KIND_MODULE = 9
const KIND_PROPERTY = 10
const KIND_ENUM = 13
const KIND_KEYWORD = 14
const KIND_ENUM_MEMBER = 20
const KIND_CONSTANT = 21

const SYMBOL_KINDS = {
  [parse.KIND_MODULE]: KIND_MODULE,
  [parse.KIND_CLASS]: KIND_CLASS,
  [parse.KIND_METHOD]: KIND_FUNCTION,
  [parse.KIND_FIELD]: KIND_PROPERTY,
  [parse.KIND_ENUM]: KIND_ENUM,
  [parse.KIND_INTERFACE]: KIND_INTERFACE,
  [parse.KIND_FUNCTION]: KIND_FUNCTION,
  [parse.KIND_VARIABLE]: KIND_VARIABLE,
  [parse.KIND_CONSTANT]: KIND_CONSTANT,
  [parse.KIND_ENUM_MEMBER]: KIND_ENUM_MEMBER,
}

# Where the cursor is in "line", as far as completion cares: the word being
# typed, whether an option is expected, whether a command is, and the name
# before a "." when the word is a member of it.
export def Context(line: string, col: number): dict<any>
  var before = strpart(line, 0, col)
  var prefix = matchstr(before, '[[:alnum:]_:#]*$')
  var head = strpart(before, 0, strlen(before) - strlen(prefix))
  if prefix != '' && strlen(prefix) == strlen(before)
    head = ''
  endif
  var statement = '^\s*\%(:\s*\)*\%(\h\w*!\=\s\+\)*'
  return {
    prefix: prefix,
    option: head =~ '&\%([lg]:\)\=$'
      || head =~ statement
        .. '\%(se\%[tlocal]\|setg\%[lobal]\)\s\+\%(\S\+\s\+\)*$',
    command: head =~ '^\s*\%(:\s*\)*$',
    owner: matchstr(head, '\h\w*\ze\.$'),
    method: head =~ '->$',
  }
enddef

# Commands taking an expression or a name the script defines, for which
# getcompletiontype() gives no type.
const SCRIPT_ARGS = {def: 1, function: 1, class: 1, enum: 1, interface: 1,
  type: 1, import: 1, throw: 1, eval: 1, defer: 1, lockvar: 1, unlockvar: 1}

# Whether the cursor at "col" in "line" is in the argument of a command that
# takes no expression, which only the client completes right: file names, the
# current value of an option.
export def InCommandArg(line: string, col: number): bool
  # The last of the commands bars separate; "||" is an operator.
  var stmt = split(strpart(line, 0, col), '\%(\\\||\)\@<!||\@!', true)[-1]
  var rest = substitute(stmt,
    '^\s*\%(:\s*\)*\%([-+0-9.$%,;]\|''.\)*\s*', '', '')
  var word = matchstr(rest, '^\h\w*')
  while word != '' && parse.IsModifier(word)
    rest = substitute(strpart(rest, strlen(word)), '^!\=\s*', '', '')
    word = matchstr(rest, '^\h\w*')
  endwhile
  var after = substitute(strpart(rest, strlen(word)), '^!', '', '')
  # A Vim9 assignment, "x = 1", starts like a command with an argument.
  if word == '' || after !~ '^\s'
      || after =~ '^\s*\%([-+*/%.]\|\.\.\)\==\%(\s\|$\)'
    return false
  endif
  var cmd = parse.CommandOf(word)
  if cmd == ''
    # A user command, which only the client may know.
    return word =~ '^\u'
  endif
  return !SCRIPT_ARGS->has_key(cmd)
    && index(['expression', 'function', 'var'], getcompletiontype(stmt)) < 0
enddef

# The completion items for "symbols", those whose name starts with "prefix".
export def ItemsOf(symbols: list<dict<any>>, prefix: string): list<dict<any>>
  var items: list<dict<any>> = []
  var seen: dict<bool> = {}
  for s in symbols
    if seen->has_key(s.name)
        || (prefix != '' && s.name[: strlen(prefix) - 1] != prefix)
      continue
    endif
    seen[s.name] = true
    var item = {label: s.name, kind: SYMBOL_KINDS->get(s.kind, KIND_VARIABLE)}
    if s.detail != ''
      item.detail = s.detail
    endif
    add(items, item)
  endfor
  return items
enddef

# The completion items for the cursor at "col" in "line"; "symbols" is what
# the script defines.
export def Items(line: string, col: number,
    symbols: list<dict<any>>): list<dict<any>>
  var ctx = Context(line, col)
  var prefix = ctx.prefix
  var items: list<dict<any>> = []
  var seen: dict<bool> = {}

  # "tag" is the help entry of a builtin, fetched by completionItem/resolve.
  def Add(label: string, kind: number, detail: string = '', tag: string = '')
    if seen->has_key(label)
      return
    endif
    seen[label] = true
    var item = {label: label, kind: kind}
    if detail != ''
      item.detail = detail
    endif
    if tag != ''
      item.data = {tag: tag}
    endif
    add(items, item)
  enddef

  if ctx.option
    for name in getcompletion(prefix, 'option')
      Add(name, KIND_PROPERTY, '', "'" .. name .. "'")
    endfor
    return items
  endif

  if ctx.command
    for name in getcompletion(prefix, 'command')
      Add(name, KIND_KEYWORD, '', ':' .. name)
    endfor
  endif
  if prefix =~ '^v:'
    for name in getcompletion(prefix, 'var')
      Add(name, KIND_VARIABLE, '', name)
    endfor
  endif
  for symbol in parse.AllSymbols(symbols)
    if symbol.name[: strlen(prefix) - 1] == prefix || prefix == ''
      Add(symbol.name, SYMBOL_KINDS->get(symbol.kind, KIND_VARIABLE),
        symbol.detail)
    endif
  endfor
  for name in getcompletion(prefix, 'function')
    var fn = substitute(name, '($', '', '')
    Add(fn, KIND_FUNCTION, '', fn .. '()')
  endfor
  return items
enddef

# Whether each builtin can be called with "->", filled in as asked.  A user
# function of the server's own Vim is not one of the client's.
var is_method: dict<bool> = {}

# Whether function "s" of the script takes an argument, which "->" fills.
def TakesArgument(s: dict<any>): bool
  return s.detail =~ '\.\.\.'
    || s.children->indexof((_, c) => c->get('param', false)) >= 0
enddef

# The completion items after "->" that start with "prefix": the builtins that
# can be called as a method, and the functions taking an argument and the
# Funcref variables in "symbols".
export def MethodItems(prefix: string,
    symbols: list<dict<any>>): list<dict<any>>
  var items: list<dict<any>> = []
  var seen: dict<bool> = {}
  for s in parse.AllSymbols(symbols)
    if seen->has_key(s.name)
        || (prefix != '' && s.name[: strlen(prefix) - 1] != prefix)
      continue
    endif
    if (s.kind == parse.KIND_FUNCTION && s.detail != ':command'
          && TakesArgument(s))
        || ((s.kind == parse.KIND_VARIABLE || s.kind == parse.KIND_CONSTANT)
          && s.detail =~ '^func\>')
      seen[s.name] = true
      var item = {label: s.name, kind: SYMBOL_KINDS[s.kind]}
      if s.detail != ''
        item.detail = s.detail
      endif
      add(items, item)
    endif
  endfor
  for name in getcompletion(prefix, 'function')
    var fn = substitute(name, '($', '', '')
    if seen->has_key(fn)
      continue
    endif
    if !is_method->has_key(fn)
      var info = getinfo('function', fn)
      is_method[fn] = info->get('kind', '') == 'builtin'
        && info->get('method', 0) > 0
    endif
    if is_method[fn]
      seen[fn] = true
      add(items, {label: fn, kind: KIND_FUNCTION, data: {tag: fn .. '()'}})
    endif
  endfor
  return items
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
