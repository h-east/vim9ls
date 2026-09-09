vim9script

# vim9ls - the script level of a Vim9 script as a function
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# ":source ++dryrun" defines what a script defines and compiles its
# functions, but skips the statements at the script level.  To have Vim
# compile those as well, they are made the body of a function that the
# checker appends to the script: what the dry run has already read
# (functions, classes, imports, type aliases, "vim9script" and what comes
# before it) is blanked, and a declaration becomes an assignment to the
# script variable the dry run declared.  The body has one line for each
# line of the script.

import autoload './parse.vim'

const BLOCKS = [parse.KIND_FUNCTION, parse.KIND_METHOD, parse.KIND_CLASS,
  parse.KIND_INTERFACE, parse.KIND_ENUM]

# "line" is a declaration; the same line as an assignment.  A "const" or
# "final" is made a local variable instead, an assignment to it would be an
# error.  A declaration without a value has nothing to check.
def Assignment(line: string): string
  var m = matchlist(line,
    '^\(\s*\)\%(export\s\+\)\=\(var\|const\|final\)\s\+\(.\{-}\)\s*\(=.*\)$')
  if m->empty()
    return ''
  endif
  var names = substitute(m[3], ':\s.*', '', '')
  if m[2] == 'var'
    return m[1] .. names .. ' ' .. m[4]
  endif
  return m[1] .. 'var ' .. names .. '_dryrun ' .. m[4]
enddef

# The lines of a parsed Vim9 script as the body of a function, see above.
export def Lines(parsed: dict<any>, lines: list<string>): list<string>
  var out = copy(lines)
  var done: dict<bool> = {}
  for s in parsed.symbols
    if index(BLOCKS, s.kind) >= 0 && s.detail != ':command'
      for lnum in range(s.line, min([s.end_line, len(out) - 1]))
        out[lnum] = ''
      endfor
    elseif s.kind == parse.KIND_MODULE
      out[s.line] = ''
    elseif (s.kind == parse.KIND_VARIABLE || s.kind == parse.KIND_CONSTANT)
        && !done->has_key(s.line)
      done[s.line] = true
      out[s.line] = Assignment(out[s.line])
    endif
  endfor
  var started = false
  for lnum in range(len(out))
    var line = out[lnum]
    if !started
      # Up to "vim9script": comments in the legacy style at most.
      out[lnum] = ''
      started = line =~ '^\s*vim9script\>'
    elseif line =~ '^\s*fini\%[sh]\>'
      out[lnum] = 'return'
    elseif line =~ '^\s*\%(export\s\+\)\=type\s\+\u'
        || line =~ '^\s*\%(defc\%[ompile]\|disa\%[ssemble]\)\>'
        || line =~ '^\s*\%(scripte\%[ncoding]\|scriptv\%[ersion]\)\>'
      out[lnum] = ''
    endif
  endfor
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
