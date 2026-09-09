vim9script

# vim9ls - names that nothing defines
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# A call of a function that is not defined, and a "v:" variable Vim does not
# have.  Only what is certain is reported: a builtin is asked of Vim, a
# function of the script is looked for in the script, an autoload function
# in its file.  A global function may be defined anywhere and is left alone.

import autoload './parse.vim'
import autoload './refs.vim'
import autoload './doc.vim'

# Commands whose argument is not code: a pattern, keys, an option value or
# the name and parameters of a function.
const SKIPPED = {syntax: 1, highlight: 1, match: 1, '2match': 1, '3match': 1,
  normal: 1, set: 1, setlocal: 1, setglobal: 1, def: 1, function: 1,
  substitute: 1, smagic: 1, snomagic: 1, global: 1, vglobal: 1, sort: 1,
  vimgrep: 1, vimgrepadd: 1, lvimgrep: 1, lvimgrepadd: 1}

# The command a line starts with, past the colons and modifiers.
def FirstCommand(line: string): string
  var rest = substitute(line, '^\s*\%(:\s*\)*', '', '')
  while true
    var word = matchstr(rest, '^\h\w*')
    if word == '' || !parse.IsModifier(word)
      return parse.CommandOf(word)
    endif
    rest = substitute(rest, '^\h\w*!\=\s*', '', '')
  endwhile
  return ''
enddef

# The parameters of the lambdas on "line": "(a, b) =>" and "{a, b -> ...}".
def LambdaParams(line: string): list<string>
  var names: list<string> = []
  var pos = 0
  while true
    var m = matchstrpos(line, '(\([^()]*\))\%(:\s*[^=]*\)\=\s*=>', pos)
    if m[1] < 0
      break
    endif
    for param in split(matchstr(m[0], '(\zs[^()]*\ze)'), ',')
      var name = matchstr(param, '^\s*\zs\h\w*')
      if name != ''
        add(names, name)
      endif
    endfor
    pos = m[2]
  endwhile
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
  # The parameters of the block lambdas that are open.
  var blocks: list<list<string>> = []

  def Report(lnum: number, token: dict<any>, message: string)
    add(out, {line: lnum, col: token.col, end_col: token.end,
      message: message, severity: parse.SEVERITY_ERROR})
  enddef

  for lnum in range(len(lines))
    var line = lines[lnum]
    if !blocks->empty() && line =~ '^\s*}'
      remove(blocks, -1)
    endif
    var lambda = stridx(line, '=>') >= 0 || stridx(line, '->') >= 0
    if lambda && line =~ '=>\s*{\s*$'
      add(blocks, LambdaParams(line))
    endif
    # Only a call or a "v:" name is looked at, most lines have neither.
    if heredoc->has_key(lnum)
        || (stridx(line, '(') < 0 && stridx(line, 'v:') < 0)
        || SKIPPED->has_key(FirstCommand(line))
      continue
    endif
    var vim9 = vim9_at[lnum]
    # Under Vim9 rules "s:Name" and "Name" are the same, see refs.Resolve().
    var same = parsed.vim9 || vim9
    var params = (lambda ? LambdaParams(line) : []) + flattennew(blocks)
    for token in Candidates(line, vim9)
      var name = token.text
      if name =~ '^v:'
        # "v:val" and "v:key" exist while map() and filter() run.
        if !exists(name) && name != 'v:val' && name != 'v:key'
          Report(lnum, token, vim9
            ? 'E1001: Variable not found: ' .. name[2 :]
            : 'E121: Undefined variable: ' .. name)
        endif
        continue
      endif
      # "func(" is a type, and after a backslash the name is in a pattern.
      if line[token.end] != '(' || token.prev == '.' || token.prev == '\'
          || name == 'func' || index(params, name) >= 0
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
      elseif vim9
        unknown = refs.Find(index, token, lnum, same) == null_dict
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
