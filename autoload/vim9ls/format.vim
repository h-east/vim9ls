vim9script

# vim9ls - formatting with the indent script of Vim itself
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './util.vim'

# The indent file of $VIMRUNTIME is what does the work; it is read once.
var ready = false

def Ready()
  if !ready
    filetype indent on
    ready = true
  endif
enddef

# The lines as Vim's indent script leaves them, with the trims the client
# asked for.  "first" and "last" are the lines to indent, both included.
def Formatted(lines: list<string>, first: number, last: number,
    options: dict<any>): list<string>
  Ready()
  var out: list<string>
  var size = options->get('tabSize', 8)
  new
  try
    setline(1, lines)
    &l:tabstop = size
    &l:shiftwidth = size
    &l:expandtab = options->get('insertSpaces', true)
    # The indent script comes with the filetype and reads the options, so
    # they are set before it.
    &l:filetype = 'vim'
    silent! execute printf(':%d,%dnormal! ==', first + 1, last + 1)
    out = getline(1, '$')
  finally
    bwipe!
  endtry

  if options->get('trimTrailingWhitespace', false)
    for i in range(first, last)
      out[i] = substitute(out[i], '\s\+$', '', '')
    endfor
  endif
  # The last line of a document that ends in a newline is an empty one, so
  # the newline at the end is that line being there.
  if last == len(lines) - 1
    if options->get('trimFinalNewlines', false)
      while len(out) > 1 && out[-1] == '' && out[-2] == ''
        remove(out, -1)
      endwhile
    endif
    if options->get('insertFinalNewline', false) && out[-1] != ''
      add(out, '')
    endif
  endif
  return out
enddef

# What to change in "lines" to have them formatted, as LSP TextEdits: one
# for each line that differs, and one for the lines at the end that are
# added or taken away.
export def Edits(lines: list<string>, first: number, last: number,
    options: dict<any>, encoding: string): list<dict<any>>
  if lines->empty()
    return []
  endif
  var formatted = Formatted(lines, first, last, options)
  var out: list<dict<any>> = []
  var common = min([len(lines), len(formatted)])
  for i in range(common)
    if formatted[i] != lines[i]
      add(out, {range: util.Range(lines, i, 0, i, strlen(lines[i]), encoding),
        newText: formatted[i]})
    endif
  endfor
  var end = len(lines) - 1
  if len(formatted) < len(lines)
    # From the end of the last line that stays, so the lines are gone rather
    # than left empty.
    add(out, {range: util.Range(lines, common - 1, strlen(lines[common - 1]),
      end, strlen(lines[end]), encoding), newText: ''})
  elseif len(formatted) > len(lines)
    add(out, {range: util.Range(lines, end, strlen(lines[end]), end,
      strlen(lines[end]), encoding),
      newText: "\n" .. join(formatted[common :], "\n")})
  endif
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
