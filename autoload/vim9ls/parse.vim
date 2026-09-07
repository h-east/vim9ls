vim9script

# vim9ls - a line-oriented reading of a Vim script
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# What the server needs is the shape of a script, not its meaning: which
# functions, variables, classes and groups it defines, where each block starts
# and ends, and where the blocks do not add up.  Every line is read on its
# own; expressions are left alone.  Vim itself resolves the command names,
# through fullcommand(), so abbreviations come out right.

# LSP SymbolKind values.
export const KIND_MODULE = 2
export const KIND_NAMESPACE = 3
export const KIND_CLASS = 5
export const KIND_METHOD = 6
export const KIND_FIELD = 8
export const KIND_ENUM = 10
export const KIND_INTERFACE = 11
export const KIND_FUNCTION = 12
export const KIND_VARIABLE = 13
export const KIND_CONSTANT = 14
export const KIND_ENUM_MEMBER = 22

# LSP DiagnosticSeverity values.
export const SEVERITY_ERROR = 1
export const SEVERITY_WARNING = 2

# Commands that only qualify the command after them.
const MODIFIERS = {
  aboveleft: 1, belowright: 1, botright: 1, browse: 1, confirm: 1, hide: 1,
  horizontal: 1, keepalt: 1, keepjumps: 1, keepmarks: 1, keeppatterns: 1,
  legacy: 1, lockmarks: 1, noautocmd: 1, noswapfile: 1, sandbox: 1,
  silent: 1, tab: 1, topleft: 1, unsilent: 1, verbose: 1, vertical: 1,
  vim9cmd: 1,
}

# The error Vim gives for each way of getting a block wrong.
const MISSING_END = {
  def: 'E1057: Missing :enddef', function: 'E126: Missing :endfunction',
  if: 'E171: Missing :endif', while: 'E170: Missing :endwhile',
  for: 'E170: Missing :endfor', try: 'E600: Missing :endtry',
  class: 'Missing :endclass', enum: 'E1420: Missing :endenum',
  interface: 'Missing :endinterface', augroup: 'Missing :augroup END',
}
const END_WITHOUT_START = {
  enddef: 'E193: :enddef not inside a function',
  endfunction: 'E193: :endfunction not inside a function',
  endif: 'E580: :endif without :if', endwhile: 'E588: :endwhile without :while',
  endfor: 'E588: :endfor without :for', endtry: 'E602: :endtry without :try',
  endclass: ':endclass without :class', endenum: ':endenum without :enum',
  endinterface: ':endinterface without :interface',
  else: 'E581: :else without :if', elseif: 'E582: :elseif without :if',
  catch: 'E603: :catch without :try', finally: 'E606: :finally without :try',
}
const CLOSES = {
  enddef: 'def', endfunction: 'function', endif: 'if', endwhile: 'while',
  endfor: 'for', endtry: 'try', endclass: 'class', endenum: 'enum',
  endinterface: 'interface',
}
const CONTINUES = {else: 'if', elseif: 'if', catch: 'try', finally: 'try'}

# Whether "word" only qualifies the command after it.
export def IsModifier(word: string): bool
  var cmd = fullcommand(word, false)
  return MODIFIERS->has_key(cmd)
    || index(['export', 'static', 'public', 'abstract', 'protected'], cmd) >= 0
enddef

# A statement that starts like this is an expression, not a command: an
# assignment, a call, a method chain, or the tail of a continued line.
const EXPRESSION_START = '^\%(\.\.\|->\|[-+*/%.=:#(\[\])},<>?&|!]\)'

# "col" is where the statement starts, "name_col" where the name does.
def NewSymbol(name: string, kind: number, line: number, col: number,
    name_col: number, detail: string = ''): dict<any>
  return {
    name: name, kind: kind, detail: detail,
    line: line, col: col, end_line: line,
    name_col: name_col, name_end: name_col + strlen(name),
    children: [],
  }
enddef

def Diag(line: number, col: number, end_col: number, message: string,
    severity: number = SEVERITY_ERROR): dict<any>
  return {line: line, col: col, end_col: end_col, message: message,
    severity: severity}
enddef

# The name defined by "def"/"function" arguments, or an empty string for a
# listing.
def FunctionName(arg_text: string): string
  return matchstr(arg_text, '^\%(<SID>\|[sgbwtl]:\)\=\h[[:alnum:]_#.]*')
enddef

# The variables a "var"/"let"/"const"/"final" statement declares.
def VariableNames(arg_text: string): list<string>
  if arg_text =~ '^\['
    return matchstr(arg_text, '^\[\zs[^]]*')->split('[,;]')
      ->map((_, s) => matchstr(s, '^\s*\zs\%([sgbwtl]:\)\=\h\w*'))
      ->filter((_, s) => s != '')
  endif
  var name = matchstr(arg_text, '^\%([sgbwtl]:\)\=\h\w*')
  return name == '' ? [] : [name]
enddef

export def Parse(lines: list<string>): dict<any>
  var is_vim9 = false
  var stack: list<dict<any>> = []
  var top: list<dict<any>> = []
  var diags: list<dict<any>> = []
  var heredoc = ''

  def Container(): list<dict<any>>
    for i in range(len(stack) - 1, 0, -1)
      if stack[i].symbol != null_dict
        return stack[i].symbol.children
      endif
    endfor
    return top
  enddef

  # Whether the code here follows Vim9 rules: the innermost function
  # decides, then the script.
  def InVim9(): bool
    for i in range(len(stack) - 1, 0, -1)
      if stack[i].kind == 'def' || stack[i].kind == 'class'
        return true
      elseif stack[i].kind == 'function'
        return false
      endif
    endfor
    return is_vim9
  enddef

  def InKind(kind: string): bool
    return !stack->empty() && stack[-1].kind == kind
  enddef

  def Open(kind: string, symbol: dict<any>, lnum: number)
    add(stack, {kind: kind, symbol: symbol, line: lnum})
  enddef

  def Close(closer: string, lnum: number, col: number, end_col: number)
    var kind = CLOSES[closer]
    if stack->empty() || stack[-1].kind != kind
      add(diags, Diag(lnum, col, end_col, END_WITHOUT_START[closer]))
      return
    endif
    var entry = remove(stack, -1)
    if entry.symbol != null_dict
      entry.symbol.end_line = lnum
    endif
  enddef

  # Handles one statement; "col" is where it starts in the line.
  def Statement(lnum: number, text: string, col: number, is_first: bool)
    var rest = text
    var offset = col
    var word = ''
    var cmd = ''
    var arg_text = ''

    # Modifiers, "export" and the class member qualifiers only say
    # something about the command after them.
    while true
      var m = matchlist(rest, '^\(\h\w*\)\(!\=\)\s*\(.*\)$')
      if m->empty()
        return
      endif
      word = m[1]
      cmd = fullcommand(word, false)
      arg_text = m[3]
      if !IsModifier(word)
        break
      endif
      offset += strlen(rest) - strlen(arg_text)
      rest = arg_text
    endwhile
    var name_col = offset + strlen(word) + (rest[strlen(word)] == '!' ? 1 : 0)
    name_col += strlen(matchstr(rest[name_col - offset : ], '^\s*'))

    if cmd == 'vim9script'
      is_vim9 = true
    elseif cmd == 'def' || cmd == 'function'
      var name = FunctionName(arg_text)
      if name == ''
        return
      endif
      var in_class = InKind('class') || InKind('interface') || InKind('enum')
      var symbol = NewSymbol(name, in_class ? KIND_METHOD : KIND_FUNCTION,
        lnum, col, name_col, matchstr(arg_text, '(.*'))
      add(Container(), symbol)
      # An interface only declares its methods, there is no body to close.
      if !InKind('interface')
        Open(cmd, symbol, lnum)
      endif
    elseif CLOSES->has_key(cmd)
      Close(cmd, lnum, offset, offset + strlen(word))
    elseif CONTINUES->has_key(cmd)
      if !InKind(CONTINUES[cmd])
        add(diags, Diag(lnum, offset, offset + strlen(word),
          END_WITHOUT_START[cmd]))
      endif
    elseif index(['if', 'while', 'for', 'try'], cmd) >= 0
      Open(cmd, null_dict, lnum)
    elseif cmd == 'class' || cmd == 'interface' || cmd == 'enum'
      var name = matchstr(arg_text, '^\h\w*')
      if name == ''
        return
      endif
      var kind = cmd == 'class' ? KIND_CLASS
        : cmd == 'enum' ? KIND_ENUM : KIND_INTERFACE
      var symbol = NewSymbol(name, kind, lnum, col, name_col,
        matchstr(arg_text, '^\h\w*\s*\zs.*'))
      add(Container(), symbol)
      Open(cmd, symbol, lnum)
    elseif cmd == 'augroup'
      if arg_text =~? '^end\>'
        if InKind('augroup')
          var entry = remove(stack, -1)
          entry.symbol.end_line = lnum
        else
          add(diags, Diag(lnum, offset, offset + strlen(text) - col,
            ':augroup END without :augroup'))
        endif
      elseif arg_text =~ '^\S'
        var name = matchstr(arg_text, '^\S\+')
        var symbol = NewSymbol(name, KIND_NAMESPACE, lnum, col, name_col)
        add(Container(), symbol)
        Open('augroup', symbol, lnum)
      endif
    elseif cmd == 'var' || cmd == 'const' || cmd == 'final' || cmd == 'let'
      if cmd == 'let' && InVim9()
        add(diags, Diag(lnum, offset, offset + strlen(word),
          'E1126: Cannot use :let in Vim9 script'))
      endif
      # A heredoc holds text, not statements.
      var marker = matchstr(arg_text, '=<<\s*\%(\%(trim\|eval\)\s\+\)*\zs\S\+$')
      if marker != ''
        heredoc = marker
      endif
      var in_class = InKind('class') || InKind('enum')
      var kind = in_class ? KIND_FIELD
        : cmd == 'var' || cmd == 'let' ? KIND_VARIABLE : KIND_CONSTANT
      var detail = matchstr(arg_text, '^[^=]*:\s*\zs[^=]*\ze\%(\s*=\|$\)')
        ->trim()
      for name in VariableNames(arg_text)
        if cmd == 'let' && arg_text !~ '='
          continue
        endif
        var container = Container()
        if container->indexof((_, s) => s.name == name) >= 0
          continue
        endif
        var symbol = NewSymbol(name, kind, lnum, col,
          name_col + stridx(arg_text, name), detail)
        add(container, symbol)
      endfor
    elseif cmd == 'import'
      var alias = matchstr(arg_text, '\<as\s\+\zs\h\w*$')
      var file = matchstr(arg_text, '\%(autoload\s\+\)\=[''"]\zs[^''"]*')
      var name = alias != '' ? alias : fnamemodify(file, ':t:r')
      if name != ''
        var symbol = NewSymbol(name, KIND_MODULE, lnum, col,
          offset + stridx(rest, name), file)
        add(Container(), symbol)
      endif
    elseif cmd == 'command'
      var name = matchstr(arg_text, '^\%(-\S\+\s\+\)*\zs\u\w*')
      if name != ''
        add(Container(), NewSymbol(name, KIND_FUNCTION, lnum, col,
          offset + stridx(rest, name), ':command'))
      endif
    elseif cmd == '' && InKind('enum') && text =~ '^\u\w*\s*\%([,(]\|$\)'
      var name = matchstr(text, '^\u\w*')
      add(Container(), NewSymbol(name, KIND_ENUM_MEMBER, lnum, col, col))
    elseif cmd == '' && is_first && word =~ '^\l'
        && arg_text !~ EXPRESSION_START && !(InVim9() && arg_text == '')
      add(diags, Diag(lnum, offset, offset + strlen(word),
        'E492: Not an editor command: ' .. word, SEVERITY_WARNING))
    endif
  enddef

  for lnum in range(len(lines))
    var line = lines[lnum]
    if heredoc != ''
      if line->trim() == heredoc
        heredoc = ''
      endif
      continue
    endif
    var comment = InVim9() ? '^\s*#' : '^\s*"'
    if line =~ '^\s*$' || line =~ comment || line =~ '^\s*\\'
      continue
    endif
    var col = strlen(matchstr(line, '^\s*\%(:\s*\)*'))
    # A bar separates commands; one inside a string is taken along, which
    # is rare enough in the statements looked at here.
    var pos = col
    var is_first = true
    for part in split(line[col :], '\s\+|\s\+', true)
      Statement(lnum, part, pos, is_first)
      is_first = false
      pos += strlen(part)
      pos += strlen(matchstr(line[pos :], '^\s\+|\s\+'))
    endfor
  endfor

  for entry in stack
    var line = lines[entry.line]
    var col = strlen(matchstr(line, '^\s*\%(:\s*\)*'))
    add(diags, Diag(entry.line, col, strlen(line), MISSING_END[entry.kind]))
    if entry.symbol != null_dict
      entry.symbol.end_line = len(lines) - 1
    endif
  endfor

  return {vim9: is_vim9, symbols: top, diags: diags}
enddef

# Every symbol in the tree, flattened.
export def AllSymbols(symbols: list<dict<any>>): list<dict<any>>
  var out: list<dict<any>> = []
  for symbol in symbols
    add(out, symbol)
    extend(out, AllSymbols(symbol.children))
  endfor
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
