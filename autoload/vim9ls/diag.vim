vim9script

# vim9ls - diagnostics
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './util.vim'

# What the parser found wrong, as LSP Diagnostic items.
export def Diagnostics(diags: list<dict<any>>, lines: list<string>,
    encoding: string): list<dict<any>>
  var out: list<dict<any>> = []
  for d in diags
    add(out, {
      range: util.Range(lines, d.line, d.col, d.line, d.end_col, encoding),
      severity: d.severity,
      source: 'vim9ls',
      message: d.message,
    })
  endfor
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
