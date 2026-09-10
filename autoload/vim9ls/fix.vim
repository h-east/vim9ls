vim9script

# vim9ls - quick fixes for what the parser reports
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './util.vim'
import autoload './parse.vim'
import autoload './refs.vim'
import autoload './diag.vim'

# The line to put the end of the block that starts at "start" on: the first
# line after it that is not indented deeper, or the number of lines when
# there is none.
def EndOf(lines: list<string>, start: number): number
  var depth = strdisplaywidth(matchstr(lines[start], '^\s*'))
  for lnum in range(start + 1, len(lines) - 1)
    if lines[lnum] =~ '\S'
        && strdisplaywidth(matchstr(lines[lnum], '^\s*')) <= depth
      return lnum
    endif
  endfor
  return len(lines)
enddef

# The edit that inserts "text" as a line before line "lnum", or after the
# last line when "lnum" is past the end.
def InsertLine(lines: list<string>, lnum: number, text: string,
    encoding: string): dict<any>
  if lnum < len(lines)
    return {range: util.Range(lines, lnum, 0, lnum, 0, encoding),
      newText: text .. "\n"}
  endif
  var last = len(lines) - 1
  var at = strlen(lines[last])
  return {range: util.Range(lines, last, at, last, at, encoding),
    newText: "\n" .. text}
enddef

# The range of line "lnum" with its line break, so that removing it leaves
# no empty line; for the last line the break before it goes instead.
def LineRange(lines: list<string>, lnum: number, encoding: string): dict<any>
  if lnum + 1 < len(lines)
    return util.Range(lines, lnum, 0, lnum + 1, 0, encoding)
  endif
  if lnum == 0
    return util.Range(lines, 0, 0, 0, strlen(lines[0]), encoding)
  endif
  return util.Range(lines, lnum - 1, strlen(lines[lnum - 1]), lnum,
    strlen(lines[lnum]), encoding)
enddef

# The fix for a ":let" under Vim9 rules: "var" when it declares the variable,
# nothing when the variable is there already or is not one to declare.
def LetFix(parsed: dict<any>, lines: list<string>, d: dict<any>,
    encoding: string): dict<any>
  var line = lines[d.line]
  var rest = line[d.end_col :]
  var name = matchstr(rest, '^\s*\zs\%([sgbwtlv]:\|[&$@]\)\=\h\w*')
  var declares = name =~ '^\%(s:\)\=\h\w*$'
  if declares
    var token = {text: name, col: 0, end: strlen(name), prev: ' ',
      in_string: false}
    var found = refs.Resolve(parsed, token, d.line)
    declares = found == null_dict || found.line >= d.line
  endif
  if declares
    return {title: 'Replace :let with :var', edit: {range: util.Range(lines,
      d.line, d.col, d.line, d.end_col, encoding), newText: 'var'}}
  endif
  var stop = d.end_col + strlen(matchstr(rest, '^\s*'))
  return {title: 'Drop :let, the variable is there', edit: {range:
    util.Range(lines, d.line, d.col, d.line, stop, encoding), newText: ''}}
enddef

# The quick fixes for the parser's diagnostics on lines "first" to "last"
# of the document at "uri", as LSP CodeAction items.
export def Actions(parsed: dict<any>, lines: list<string>, uri: string,
    first: number, last: number, encoding: string): list<dict<any>>
  var out: list<dict<any>> = []
  for d in parsed.diags
    if d.line < first || d.line > last
      continue
    endif
    var fix: dict<any> = null_dict
    var missing = matchstr(d.message, 'Missing :\zs.*')
    var stray = matchstr(d.message,
      '^\%(E\d\+: \)\=:\zs\w\+\ze \%(without\|not\)')
    if d.message =~ '^E1126:'
      fix = LetFix(parsed, lines, d, encoding)
    elseif missing != ''
      var indent = matchstr(lines[d.line], '^\s*')
      fix = {title: 'Insert ' .. missing, edit: InsertLine(lines,
        EndOf(lines, d.line), indent .. missing, encoding)}
    elseif stray =~ '^end'
      fix = {title: 'Remove the ' .. stray .. ' without a start',
        edit: {range: LineRange(lines, d.line, encoding), newText: ''}}
    endif
    if fix == null_dict
      continue
    endif
    add(out, {
      title: fix.title,
      kind: 'quickfix',
      diagnostics: diag.Diagnostics([d], lines, encoding),
      edit: {changes: {[uri]: [fix.edit]}},
    })
  endfor
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
