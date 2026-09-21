vim9script

# vim9ls - folding ranges
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './parse.vim'

# The start line of a fold stays in view, so a range of one line hides
# nothing.
def Add(out: list<dict<any>>, line: number, end_line: number, kind = '')
  if end_line <= line
    return
  endif
  var item: dict<any> = {startLine: line, endLine: end_line}
  if kind != ''
    item.kind = kind
  endif
  add(out, item)
enddef

# The runs of comment lines, and the runs of imports.  A line of a heredoc
# is text, whatever it starts with.
def TextRanges(parsed: dict<any>, lines: list<string>,
    out: list<dict<any>>)
  var heredoc: dict<bool> = {}
  for lnum in parsed.heredoc_lines
    heredoc[lnum] = true
  endfor
  var comment_at = -1
  var import_at = -1
  for lnum in range(len(lines))
    var line = lines[lnum]
    var is_comment = !heredoc->has_key(lnum) && line =~ '^\s*["#]'
    var is_import = !heredoc->has_key(lnum) && line =~ '^\s*import\>'
    if !is_comment && comment_at >= 0
      Add(out, comment_at, lnum - 1, 'comment')
      comment_at = -1
    elseif is_comment && comment_at < 0
      comment_at = lnum
    endif
    if !is_import && import_at >= 0
      Add(out, import_at, lnum - 1, 'imports')
      import_at = -1
    elseif is_import && import_at < 0
      import_at = lnum
    endif
  endfor
  if comment_at >= 0
    Add(out, comment_at, len(lines) - 1, 'comment')
  endif
  if import_at >= 0
    Add(out, import_at, len(lines) - 1, 'imports')
  endif
enddef

# The folding ranges of a script.  A range ends on the line that closes it,
# so ":enddef" is folded away with the function.
export def Ranges(parsed: dict<any>, lines: list<string>): list<dict<any>>
  var out: list<dict<any>> = []
  for s in parse.AllSymbols(parsed.symbols)
    if !s->get('param', false)
      Add(out, s.line, s.end_line)
    endif
  endfor
  for block in parsed.blocks
    Add(out, block.line, block.end_line)
  endfor
  TextRanges(parsed, lines, out)
  return sort(out, (a, b) => a.startLine == b.startLine
    ? a.endLine - b.endLine : a.startLine - b.startLine)
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
