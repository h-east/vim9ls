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
  export: 1, static: 1, public: 1, abstract: 1, protected: 1,
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
const OPENS = {if: 1, while: 1, for: 1, try: 1}
const DECLARES = {var: 1, const: 1, final: 1, let: 1}
const TYPES = {class: KIND_CLASS, interface: KIND_INTERFACE, enum: KIND_ENUM}

# The commands that shape a script; every other command is left alone.
const SHAPING = extend({
  def: 1, function: 1, augroup: 1, import: 1, command: 1, vim9script: 1,
}, MODIFIERS)->extend(OPENS)->extend(CLOSES)->extend(CONTINUES)
  ->extend(DECLARES)->extend(TYPES)

# fullcommand() costs more than a lookup, and the same words come up again
# and again.
var commands: dict<string> = {}

# The command "word" stands for, expanded; empty when it is not one.
def CommandOf(word: string): string
  if !commands->has_key(word)
    commands[word] = fullcommand(word, false)
  endif
  return commands[word]
enddef

# Whether "word" only qualifies the command after it.
export def IsModifier(word: string): bool
  return MODIFIERS->has_key(CommandOf(word))
enddef

# A word followed by one of these is an expression, not a command: an
# assignment, a call, a method chain, or the tail of a continued line.
const EXPRESSION_CHARS = '-+*/%.=:#([])},<>?&|!'

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

# The state of one parse, handed to the functions below.
def NewState(): dict<any>
  return {vim9: false, stack: [], top: [], diags: [], heredoc: ''}
enddef

def Container(st: dict<any>): list<dict<any>>
  for i in range(len(st.stack) - 1, 0, -1)
    if st.stack[i].symbol != null_dict
      return st.stack[i].symbol.children
    endif
  endfor
  return st.top
enddef

# Whether the code here follows Vim9 rules: the innermost function decides,
# then the script.
def InVim9(st: dict<any>): bool
  for i in range(len(st.stack) - 1, 0, -1)
    if st.stack[i].kind == 'def' || st.stack[i].kind == 'class'
      return true
    elseif st.stack[i].kind == 'function'
      return false
    endif
  endfor
  return st.vim9
enddef

def InKind(st: dict<any>, kind: string): bool
  return !st.stack->empty() && st.stack[-1].kind == kind
enddef

def Open(st: dict<any>, kind: string, symbol: dict<any>, lnum: number)
  add(st.stack, {kind: kind, symbol: symbol, line: lnum})
enddef

def Close(st: dict<any>, closer: string, lnum: number, col: number,
    end_col: number)
  var kind = CLOSES[closer]
  if st.stack->empty() || st.stack[-1].kind != kind
    add(st.diags, Diag(lnum, col, end_col, END_WITHOUT_START[closer]))
    return
  endif
  var entry = remove(st.stack, -1)
  if entry.symbol != null_dict
    entry.symbol.end_line = lnum
  endif
enddef

# The parameters of a function as variables of it; a legacy script refers
# to them with "a:".
def AddParams(symbol: dict<any>, arg_text: string, lnum: number,
    name_col: number, legacy: bool)
  var params = matchstrpos(arg_text, '(\zs[^)]*\ze)')
  if params[1] < 0
    return
  endif
  var pos = 0
  while true
    var m = matchstrpos(params[0], '\h\w*', pos)
    if m[1] < 0
      break
    endif
    # Skip a type and a default: what follows ":" or "=" up to ",".
    pos = m[2] + strlen(matchstr(params[0], '^\s*[:=][^,]*', m[2]))
    var param = NewSymbol((legacy ? 'a:' : '') .. m[0], KIND_VARIABLE, lnum,
      name_col + params[1] + m[1], name_col + params[1] + m[1])
    param.param = true
    add(symbol.children, param)
  endwhile
enddef

# The text of "line" after the word at "col": past a "!" and the blanks.
def ArgText(line: string, col: number, word: string): string
  var wlen = strlen(word) + (line[col + strlen(word)] == '!' ? 1 : 0)
  return line[matchend(line, '\s*', col + wlen) :]
enddef

# Handles one statement, "text" from "col" in its line; "word" is its first
# word and "cmd" the command that is, when it is one.
def Statement(st: dict<any>, lnum: number, text: string, col: number,
    is_first: bool, first_word: string, first_cmd: string)
  var rest = text
  var offset = col
  var word = first_word
  var cmd = first_cmd
  var arg_text = ArgText(rest, 0, word)

  # Modifiers, "export" and the class member qualifiers only say something
  # about the command after them.
  while MODIFIERS->has_key(cmd)
    offset += strlen(rest) - strlen(arg_text)
    rest = arg_text
    word = matchstr(rest, '^\h\w*')
    if word == ''
      return
    endif
    cmd = CommandOf(word)
    arg_text = ArgText(rest, 0, word)
  endwhile
  var name_col = offset + strlen(rest) - strlen(arg_text)

  if cmd == ''
    # A word after a modifier that is not a command.
    if is_first && word[0] >= 'a' && word[0] <= 'z' && !InVim9(st)
        && (arg_text == '' || stridx(EXPRESSION_CHARS, arg_text[0]) < 0)
      add(st.diags, Diag(lnum, offset, offset + strlen(word),
        'E492: Not an editor command: ' .. word, SEVERITY_WARNING))
    endif
    return
  endif

  if DECLARES->has_key(cmd)
    if cmd == 'let' && InVim9(st)
      add(st.diags, Diag(lnum, offset, offset + strlen(word),
        'E1126: Cannot use :let in Vim9 script'))
    endif
    # A heredoc holds text, not statements.
    if arg_text =~ '=<<'
      st.heredoc = matchstr(arg_text,
        '=<<\s*\%(\%(trim\|eval\)\s\+\)*\zs\S\+$')
    endif
    var in_class = InKind(st, 'class') || InKind(st, 'enum')
    var kind = in_class ? KIND_FIELD
      : cmd == 'var' || cmd == 'let' ? KIND_VARIABLE : KIND_CONSTANT
    var detail = arg_text !~ ':' ? ''
      : matchstr(arg_text, '^[^=]*:\s*\zs[^=]*\ze\%(\s*=\|$\)')->trim()
    var container = Container(st)
    for name in VariableNames(arg_text)
      if cmd == 'let'
        # ":let" assigns as well as declares; the first one counts.
        if arg_text !~ '='
          continue
        endif
        var seen = false
        for s in container
          if s.name ==# name
            seen = true
            break
          endif
        endfor
        if seen
          continue
        endif
      endif
      add(container, NewSymbol(name, kind, lnum, col,
        name_col + stridx(arg_text, name), detail))
    endfor
  elseif cmd == 'def' || cmd == 'function'
    var name = FunctionName(arg_text)
    if name == ''
      return
    endif
    var in_class = InKind(st, 'class') || InKind(st, 'interface')
      || InKind(st, 'enum')
    var symbol = NewSymbol(name, in_class ? KIND_METHOD : KIND_FUNCTION,
      lnum, col, name_col, matchstr(arg_text, '(.*'))
    symbol.legacy = cmd == 'function'
    add(Container(st), symbol)
    AddParams(symbol, arg_text, lnum, name_col, cmd == 'function')
    # An interface only declares its methods, there is no body to close.
    if !InKind(st, 'interface')
      Open(st, cmd, symbol, lnum)
    endif
  elseif CLOSES->has_key(cmd)
    Close(st, cmd, lnum, offset, offset + strlen(word))
  elseif CONTINUES->has_key(cmd)
    if !InKind(st, CONTINUES[cmd])
      add(st.diags, Diag(lnum, offset, offset + strlen(word),
        END_WITHOUT_START[cmd]))
    endif
  elseif OPENS->has_key(cmd)
    Open(st, cmd, null_dict, lnum)
  elseif TYPES->has_key(cmd)
    var name = matchstr(arg_text, '^\h\w*')
    if name == ''
      return
    endif
    var symbol = NewSymbol(name, TYPES[cmd], lnum, col, name_col,
      matchstr(arg_text, '^\h\w*\s*\zs.*'))
    add(Container(st), symbol)
    Open(st, cmd, symbol, lnum)
  elseif cmd == 'vim9script'
    st.vim9 = true
  elseif cmd == 'augroup'
    if arg_text =~? '^end\>'
      if InKind(st, 'augroup')
        var entry = remove(st.stack, -1)
        entry.symbol.end_line = lnum
      else
        add(st.diags, Diag(lnum, offset, offset + strlen(text) - col,
          ':augroup END without :augroup'))
      endif
    elseif arg_text =~ '^\S'
      var name = matchstr(arg_text, '^\S\+')
      var symbol = NewSymbol(name, KIND_NAMESPACE, lnum, col, name_col)
      add(Container(st), symbol)
      Open(st, 'augroup', symbol, lnum)
    endif
  elseif cmd == 'import'
    var alias = matchstr(arg_text, '\<as\s\+\zs\h\w*$')
    var file = matchstr(arg_text, '\%(autoload\s\+\)\=[''"]\zs[^''"]*')
    var name = alias != '' ? alias : fnamemodify(file, ':t:r')
    if name != ''
      var symbol = NewSymbol(name, KIND_MODULE, lnum, col,
        offset + stridx(rest, name), file)
      symbol.autoload = arg_text =~ '^autoload\s'
      add(Container(st), symbol)
    endif
  elseif cmd == 'command'
    var name = matchstr(arg_text, '^\%(-\S\+\s\+\)*\zs\u\w*')
    if name != ''
      add(Container(st), NewSymbol(name, KIND_FUNCTION, lnum, col,
        offset + stridx(rest, name), ':command'))
    endif
  endif
enddef

export def Parse(lines: list<string>): dict<any>
  var st = NewState()
  for lnum in range(len(lines))
    var line = lines[lnum]
    if st.heredoc != ''
      if line->trim() == st.heredoc
        st.heredoc = ''
      endif
      continue
    endif
    # Only a line that starts with a name can be a statement of interest;
    # this leaves out empty lines, comments, continuations and ranges.
    var m = matchstrpos(line, '^\s*\%(:\s*\)*\zs\h\w*')
    if m[1] < 0
      continue
    endif
    var word = m[0]
    var col = m[1]
    var cmd = CommandOf(word)

    # Most lines are expressions or commands that do not shape the script;
    # they matter only inside an enum, and in legacy script as a typo.
    if !SHAPING->has_key(cmd)
      if cmd != ''
        continue
      endif
      if InKind(st, 'enum')
        if line =~ '^\s*\u\w*\s*\%([,(]\|$\)'
          add(Container(st), NewSymbol(word, KIND_ENUM_MEMBER, lnum, col,
            col))
        endif
      elseif word[0] >= 'a' && word[0] <= 'z' && !InVim9(st)
        var arg_text = ArgText(line, col, word)
        if arg_text == '' || stridx(EXPRESSION_CHARS, arg_text[0]) < 0
          add(st.diags, Diag(lnum, col, col + strlen(word),
            'E492: Not an editor command: ' .. word, SEVERITY_WARNING))
        endif
      endif
      continue
    endif

    if stridx(line, '|') < 0
      Statement(st, lnum, line[col :], col, true, word, cmd)
      continue
    endif
    # A bar separates commands; one inside a string is taken along, which
    # is rare enough in the statements looked at here.
    var pos = col
    var is_first = true
    for part in split(line[col :], '\s\+|\s\+', true)
      var pword = matchstr(part, '^\h\w*')
      if pword != ''
        Statement(st, lnum, part, pos, is_first, pword, CommandOf(pword))
      endif
      is_first = false
      pos += strlen(part)
      pos += strlen(matchstr(line[pos :], '^\s\+|\s\+'))
    endfor
  endfor

  for entry in st.stack
    var line = lines[entry.line]
    var col = strlen(matchstr(line, '^\s*\%(:\s*\)*'))
    add(st.diags, Diag(entry.line, col, strlen(line),
      MISSING_END[entry.kind]))
    if entry.symbol != null_dict
      entry.symbol.end_line = len(lines) - 1
    endif
  endfor

  return {vim9: st.vim9, symbols: st.top, diags: st.diags}
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

# For each of "count" lines, whether Vim9 rules apply there: the innermost
# function decides, then the script.
export def Vim9Lines(parsed: dict<any>, count: number): list<bool>
  var out = repeat([parsed.vim9], count)
  # Parents come before their children, so an inner function overrides.
  for s in AllSymbols(parsed.symbols)
    if s.kind == KIND_FUNCTION || s.kind == KIND_METHOD
      var vim9 = !s->get('legacy', false)
      for lnum in range(s.line, min([s.end_line, count - 1]))
        out[lnum] = vim9
      endfor
    endif
  endfor
  return out
enddef

# Whether Vim9 rules apply at line "lnum" of a parsed script.
export def InVim9At(parsed: dict<any>, lnum: number): bool
  var result: bool = parsed.vim9
  var innermost = -1
  for s in AllSymbols(parsed.symbols)
    if (s.kind == KIND_FUNCTION || s.kind == KIND_METHOD)
        && s.line <= lnum && lnum <= s.end_line && s.line > innermost
      innermost = s.line
      result = !s->get('legacy', false)
    endif
  endfor
  return result
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
