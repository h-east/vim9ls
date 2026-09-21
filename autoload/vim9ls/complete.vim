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
  var before = line[: col - 1]
  if col == 0
    before = ''
  endif
  var prefix = matchstr(before, '[[:alnum:]_:#]*$')
  var head = before[: strlen(before) - strlen(prefix) - 1]
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
  }
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

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
