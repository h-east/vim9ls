vim9script

# vim9ls - quick fixes for the diagnostics
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './util.vim'
import autoload './parse.vim'
import autoload './refs.vim'

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

# The fix for the ":let" from byte "col" to "end_col" of line "lnum", under
# Vim9 rules: "var" when it declares the variable, nothing when the variable
# is there already or is not one to declare.
def LetFix(parsed: dict<any>, lines: list<string>, lnum: number, col: number,
    end_col: number, encoding: string): dict<any>
  var rest = lines[lnum][end_col :]
  var name = matchstr(rest, '^\s*\zs\%([sgbwtlv]:\|[&$@]\)\=\h\w*')
  var declares = name =~ '^\%(s:\)\=\h\w*$'
  if declares
    var token = {text: name, col: 0, end: strlen(name), prev: ' ',
      in_string: false}
    var found = refs.Resolve(parsed, token, lnum)
    declares = found == null_dict || found.line >= lnum
  endif
  if declares
    return {title: 'Replace :let with :var', edit: {range: util.Range(lines,
      lnum, col, lnum, end_col, encoding), newText: 'var'}}
  endif
  var stop = end_col + strlen(matchstr(rest, '^\s*'))
  return {title: 'Drop :let, the variable is there', edit: {range:
    util.Range(lines, lnum, col, lnum, stop, encoding), newText: ''}}
enddef

# The quick fixes for "diagnostics", the ones the client sends along, of the
# document at "uri", as LSP CodeAction items.  What a fix needs is in the
# "data" of a diagnostic, see diag.FixData(); one without it has no fix.
export def Actions(parsed: dict<any>, lines: list<string>, uri: string,
    diagnostics: list<any>, encoding: string): list<dict<any>>
  var out: list<dict<any>> = []
  for d in diagnostics
    var data = type(d) == v:t_dict ? d->get('data', null) : null
    var lnum = type(data) == v:t_dict
      ? d->get('range', {})->get('start', {})->get('line', -1) : -1
    if lnum < 0 || lnum >= len(lines)
      continue
    endif
    var fix: dict<any> = null_dict
    var kind = data->get('fix', '')
    if kind == 'let'
      # The document may have changed since the diagnostic was sent.
      if lines[lnum][data.col : data.end - 1] == 'let'
        fix = LetFix(parsed, lines, lnum, data.col, data.end, encoding)
      endif
    elseif kind == 'insert'
      var indent = matchstr(lines[lnum], '^\s*')
      fix = {title: 'Insert ' .. data.text, edit: InsertLine(lines,
        EndOf(lines, lnum), indent .. data.text, encoding)}
    elseif kind == 'remove'
      fix = {title: 'Remove the ' .. data.what .. ' without a start',
        edit: {range: LineRange(lines, lnum, encoding), newText: ''}}
    endif
    # Vim may report the same error twice, worded two ways.
    if fix == null_dict || out->indexof((_, a) => a.title == fix.title
        && a.edit.changes[uri][0] == fix.edit) >= 0
      continue
    endif
    add(out, {
      title: fix.title,
      kind: 'quickfix',
      diagnostics: [d],
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
