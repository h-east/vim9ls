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
# typed, whether an option is expected, and whether a command is.
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
  }
enddef

# The completion items for the cursor at "col" in "line"; "symbols" is what
# the script defines.
export def Items(line: string, col: number,
    symbols: list<dict<any>>): list<dict<any>>
  var ctx = Context(line, col)
  var prefix = ctx.prefix
  var items: list<dict<any>> = []
  var seen: dict<bool> = {}

  def Add(label: string, kind: number, detail: string = '')
    if seen->has_key(label)
      return
    endif
    seen[label] = true
    var item = {label: label, kind: kind}
    if detail != ''
      item.detail = detail
    endif
    add(items, item)
  enddef

  if ctx.option
    for name in getcompletion(prefix, 'option')
      Add(name, KIND_PROPERTY)
    endfor
    return items
  endif

  if ctx.command
    for name in getcompletion(prefix, 'command')
      Add(name, KIND_KEYWORD)
    endfor
  endif
  if prefix =~ '^v:'
    for name in getcompletion(prefix, 'var')
      Add(name, KIND_VARIABLE)
    endfor
  endif
  for symbol in parse.AllSymbols(symbols)
    if symbol.name[: strlen(prefix) - 1] ==# prefix || prefix == ''
      Add(symbol.name, SYMBOL_KINDS->get(symbol.kind, KIND_VARIABLE),
        symbol.detail)
    endif
  endfor
  for name in getcompletion(prefix, 'function')
    Add(substitute(name, '($', '', ''), KIND_FUNCTION)
  endfor
  return items
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
