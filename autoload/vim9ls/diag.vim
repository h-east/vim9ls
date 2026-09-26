vim9script

# vim9ls - diagnostics
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './util.vim'

# What a quick fix needs of the diagnostic "message" on "line", kept in its
# "data" for textDocument/codeAction; null_dict when there is no fix.  "col"
# is where the parser found the command, -1 for what Vim reported.
export def FixData(message: string, line: string, col: number): dict<any>
  if message =~ '^E1126:'
    var start = col >= 0 ? col : match(line, '\<let\>')
    return start < 0 ? null_dict : {fix: 'let', col: start, end: start + 3}
  endif
  var missing = matchstr(message, 'Missing :\zs.*')
  if missing != ''
    # Vim reports a missing end where the block stops, the parser on the line
    # that starts it, below which the end goes.
    return col < 0 ? null_dict : {fix: 'insert', text: missing}
  endif
  var unused = matchstr(message, '^Unused parameter: \zs\h\w*$')
  if unused != ''
    return col < 0 ? null_dict
      : {fix: 'underscore', col: col, end: col + strlen(unused), name: unused}
  endif
  var stray = matchstr(message,
    '^\%(E\d\+: \)\=:\zsend\w*\ze \%(without\|not\)')
  return stray == '' ? null_dict : {fix: 'remove', what: stray}
enddef

# What the parser found wrong, as LSP Diagnostic items.
export def Diagnostics(diags: list<dict<any>>, lines: list<string>,
    encoding: string): list<dict<any>>
  var out: list<dict<any>> = []
  for d in diags
    var item: dict<any> = {
      range: util.Range(lines, d.line, d.col, d.line, d.end_col, encoding),
      severity: d.severity,
      source: 'vim9ls',
      message: d.message,
    }
    if d->has_key('tags')
      item.tags = d.tags
    endif
    var data = FixData(d.message, lines[d.line], d.col)
    if data != null_dict
      item.data = data
    endif
    add(out, item)
  endfor
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
