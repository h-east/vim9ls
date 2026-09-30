vim9script

# vim9ls - names that nothing defines
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# A call of a function that is not defined, and a "v:" variable Vim does not
# have.  Only what is certain is reported: a builtin is asked of Vim, a
# function of the script is looked for in the script, an autoload function
# in its file.  A global function may be defined anywhere and is left alone.
# Under Vim9 rules Vim reports these itself when the checker compiles the
# code, see checker.vim; what is left here is an autoload function, which Vim
# looks up only when it is called.

import autoload './parse.vim'
import autoload './refs.vim'
import autoload './doc.vim'

# Commands whose argument is not code: a pattern, keys, an option value, a
# menu name or the name and parameters of a function.
const SKIPPED = {syntax: 1, highlight: 1, match: 1, '2match': 1, '3match': 1,
  normal: 1, set: 1, setlocal: 1, setglobal: 1, def: 1, function: 1,
  substitute: 1, smagic: 1, snomagic: 1, global: 1, vglobal: 1, sort: 1,
  vimgrep: 1, vimgrepadd: 1, lvimgrep: 1, lvimgrepadd: 1, menutranslate: 1}
# The mappings, abbreviations and menus, which take keys.
const KEYS_COMMAND = '^\l.*\%(map\|abbrev\|abbreviate\|menu\)$'

# The word a line starts with, past the colons and modifiers.
def FirstWord(line: string): string
  var rest = substitute(line, '^\s*\%(:\s*\)*', '', '')
  while true
    var word = matchstr(rest, '^\h\w*')
    if word == '' || !parse.IsModifier(word)
      return word
    endif
    rest = substitute(rest, '^\h\w*!\=\s*', '', '')
  endwhile
  return ''
enddef

# The parameters of the legacy lambdas on "line": "{a, b -> ...}".
def LambdaParams(line: string): list<string>
  var names: list<string> = []
  for arglist in line->matchstrpos('{\s*\zs\h[^{}-]*\ze->')[0]->split(',')
    var name = matchstr(arglist, '^\s*\zs\h\w*')
    if name != ''
      add(names, name)
    endif
  endfor
  return names
enddef

# The names in "line" that a "(" follows, and the "v:" variables, each as
# refs.Tokens() has them; not the ones in a string or a comment.
def Candidates(line: string, vim9: bool): list<dict<any>>
  var out: list<dict<any>> = []
  var code = refs.CodeSpans(line, vim9).code
  var pos = 0
  while true
    var m = matchstrpos(line, '\%(<SID>\)\=' .. refs.NAME .. '\+\ze(\|v:\w\+',
      pos)
    if m[1] < 0
      break
    endif
    pos = m[2]
    if m[0] !~ '^\%(<SID>\)\=\h'
      continue
    endif
    for [seg_start, seg_end] in code
      if seg_start <= m[1] && m[2] <= seg_end
        add(out, {text: m[0], col: m[1], end: m[2],
          prev: m[1] == 0 ? '' : line[m[1] - 1], in_string: false})
        break
      endif
    endfor
  endwhile
  return out
enddef

# The number of arguments of the call whose "(" is at byte "open" of "line",
# -1 when the call does not end in it.
def ArgCount(line: string, open: number, vim9: bool): number
  if strpart(line, open + 1) =~ '^\s*)'
    return 0
  endif
  var depth = 0
  var commas = 0
  for [seg_start, seg_end] in refs.CodeSpans(line, vim9).code
    if seg_end <= open
      continue
    endif
    for pos in range(max([seg_start, open]), seg_end - 1)
      var c = strpart(line, pos, 1)
      if c == '(' || c == '[' || c == '{'
        depth += 1
      elseif c == ')' || c == ']' || c == '}'
        depth -= 1
        if depth == 0
          return commas + 1
        endif
      elseif c == ',' && depth == 1
        commas += 1
      endif
    endfor
  endfor
  return -1
enddef

# The calls in the keys of the mappings, abbreviations and menus of Vim9
# lines that can only be calls, for the checker to look up: {name, line,
# col, end_col, scope, argc}.  "scope" is where the keys find the name:
# "sid" the script (<SID>), "script" the script and then everywhere
# (<ScriptCmd>), "global" everywhere but the script (":call").  "argc" is -1
# when the arguments are not counted.
export def KeyCalls(parsed: dict<any>, lines: list<string>): list<dict<any>>
  var out: list<dict<any>> = []
  var vim9_at = parse.Vim9Lines(parsed, len(lines))
  var heredoc: dict<bool> = {}
  for lnum in parsed.heredoc_lines
    heredoc[lnum] = true
  endfor
  var keys = false
  for lnum in range(len(lines))
    var line = lines[lnum]
    if heredoc->has_key(lnum)
      keys = false
      continue
    endif
    if line !~ '^\s*\\'
      keys = parse.CommandOf(FirstWord(line)) =~# KEYS_COMMAND
    endif
    if !keys || !vim9_at[lnum] || stridx(line, '(') < 0
      continue
    endif
    for token in Candidates(line, true)
      if strpart(line, token.end, 1) != '(' || token.prev == '.'
          || token.text =~ '[#:]'
        continue
      endif
      var before = strpart(line, 0, token.col)
      var scope = token.text =~ '^<SID>' ? 'sid'
        : before =~? '<ScriptCmd>\%(call\s\+\)\=$' ? 'script'
        : before =~ '\<call\s\+$' ? 'global' : ''
      if scope != ''
        # The arguments may go on in the continuation lines.
        var text = line
        var argc = ArgCount(text, token.end, true)
        var next = lnum + 1
        while argc < 0 && next < len(lines) && lines[next] =~ '^\s*\\'
          text ..= substitute(lines[next], '^\s*\\', '', '')
          argc = ArgCount(text, token.end, true)
          next += 1
        endwhile
        add(out, {name: token.text, line: lnum, col: token.col,
          end_col: token.end, scope: scope, argc: argc})
      endif
    endfor
  endfor
  return out
enddef

# The undefined names in "lines", as the parser's diagnostics.  "Autoload"
# tells whether a legacy autoload function is defined in its file: 1 when it
# is, 0 when the file is there without it, -1 when there is no file.
export def Undefined(parsed: dict<any>, lines: list<string>,
    Autoload: func(string): number): list<dict<any>>
  var out: list<dict<any>> = []
  var vim9_at = parse.Vim9Lines(parsed, len(lines))
  var index = refs.Index(parsed)
  var heredoc: dict<bool> = {}
  for lnum in parsed.heredoc_lines
    heredoc[lnum] = true
  endfor
  var builtin: dict<bool> = {}

  def Report(lnum: number, token: dict<any>, message: string)
    add(out, {line: lnum, col: token.col, end_col: token.end,
      message: message, severity: parse.SEVERITY_ERROR})
  enddef

  # Whether the statement the line is part of is left alone, and whether it
  # takes keys.
  var skipping = false
  var keys = false
  for lnum in range(len(lines))
    var line = lines[lnum]
    # A continuation line goes with the statement before it.  The arguments
    # of a user command need not be an expression either; in legacy script
    # a statement cannot start with a call, a capitalized word there is one.
    if line !~ '^\s*\\'
      var word = FirstWord(line)
      var cmd = parse.CommandOf(word)
      skipping = SKIPPED->has_key(cmd) || (!vim9_at[lnum] && word =~ '^\u')
      keys = cmd =~# KEYS_COMMAND
    endif
    # Only a call or a "v:" name is looked at, most lines have neither.
    if skipping || heredoc->has_key(lnum)
        || (stridx(line, '(') < 0 && stridx(line, 'v:') < 0)
      continue
    endif
    var vim9 = vim9_at[lnum]
    # Under Vim9 rules "s:Name" and "Name" are the same, see refs.Resolve().
    var same = parsed.vim9 || vim9
    var params = !vim9 && stridx(line, '->') >= 0 ? LambdaParams(line) : []
    for token in Candidates(line, vim9)
      var name = token.text
      # Vim reports the rest when it compiles the code.
      if vim9 && name !~ '#'
        continue
      endif
      if name =~ '^v:'
        # "v:val" and "v:key" exist while map() and filter() run.
        if !exists(name) && name != 'v:val' && name != 'v:key'
          Report(lnum, token, 'E121: Undefined variable: ' .. name)
        endif
        continue
      endif
      # "func(" is a type, and after a backslash the name is in a pattern.
      if strpart(line, token.end, 1) != '(' || token.prev == '.'
          || token.prev == '\'
          || name == 'func' || index(params, name) >= 0
        continue
      endif
      # In keys a name followed by "(" is a call only when it can only be one.
      if keys && name !~ '^<SID>' && name !~ '#'
          && strpart(line, 0, token.col) !~ '\<call\s\+$'
        continue
      endif
      var unknown = false
      if name =~ '#'
        unknown = Autoload(name) == 0
      elseif name =~ '^<SID>' || name =~ '^s:'
        unknown = refs.Find(index, token, lnum, same) == null_dict
      elseif name =~ ':'
        continue
      elseif name =~ '^[a-z]'
        # A builtin this Vim was built without still has its help entry.
        if !builtin->has_key(name)
          builtin[name] = exists('*' .. name) == 1
            || doc.HasTag(name .. '()')
        endif
        unknown = !builtin[name]
      endif
      if unknown
        Report(lnum, token, 'E117: Unknown function: ' .. name)
      endif
    endfor
  endfor
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
