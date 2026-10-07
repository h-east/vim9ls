vim9script

# vim9ls - variables that nothing uses
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# A variable or a parameter of a Vim9 function whose name does not come up
# again after it is declared.  An assignment is a use too.  What is reported
# is a hint, for an editor to fade the name.  A variable of the script is left
# alone, another script may use it.

import autoload './parse.vim'
import autoload './refs.vim'

const VARIABLE_KINDS = [parse.KIND_VARIABLE, parse.KIND_CONSTANT]

# The names used in "line": in the code and in the expressions of an
# interpolated string, or of a heredoc that evaluates.  "heredoc" is 1 for a
# line of a heredoc that evaluates, 0 for one of any other, -1 for code.
def LineTokens(line: string, heredoc: number): list<dict<any>>
  if heredoc < 0
    return refs.Tokens(line, true)
  endif
  var tokens: list<dict<any>> = []
  if heredoc > 0
    for [start, text] in refs.Expressions(line, true)
      for token in refs.Tokens(text, true)
        token.col += start
        token.end += start
        add(tokens, token)
      endfor
    endfor
  endif
  return tokens
enddef

# The variables and parameters in "lines" that are not used, as the parser's
# diagnostics.
export def Unused(parsed: dict<any>, lines: list<string>): list<dict<any>>
  var index = refs.Index(parsed)
  var heredoc: dict<number> = {}
  var evaluates = 0
  var prev = -2
  for lnum in parsed.heredoc_lines
    # A heredoc starts on the line after the "=<<".
    if lnum != prev + 1
      evaluates = lnum > 0
        && lines[lnum - 1] =~ '=<<\s*\%(trim\s\+\)\=eval\s' ? 1 : 0
    endif
    heredoc[lnum] = evaluates
    prev = lnum
  endfor
  var tokens: dict<list<dict<any>>> = {}

  def Used(s: dict<any>, f: dict<any>): bool
    var first = s->get('scope_start', f.line)
    var last = min([s->get('scope_end', f.end_line), len(lines) - 1])
    # Only a name whose scope is inside that of "s" can hide it; a common
    # name has many others, which refs.Find() need not go over.
    var inside: list<dict<any>> = []
    for entry in index->get(s.name, [])
      if first <= entry.first && entry.last <= last
        add(inside, entry)
      endif
    endfor
    var narrow = {[s.name]: inside}
    for lnum in range(first, last)
      if stridx(lines[lnum], s.name) < 0
        continue
      endif
      if !tokens->has_key(lnum)
        tokens[lnum] = LineTokens(lines[lnum], heredoc->get(lnum, -1))
      endif
      for token in tokens[lnum]
        if token.text == s.name && !(lnum == s.line && token.col == s.name_col)
            && refs.Find(narrow, token, lnum, true) is s
          return true
        endif
      endfor
    endfor
    return false
  enddef

  var out: list<dict<any>> = []
  for f in parse.AllSymbols(parsed.symbols)
    # A method of an interface and an abstract one have no body.
    if (f.kind != parse.KIND_FUNCTION && f.kind != parse.KIND_METHOD)
        || f->get('legacy', true) || f.end_line == f.line
      continue
    endif
    for s in f.children
      var param = s->get('param', false)
      # "_" is how Vim9 script names what it does not use; "this.x" in the
      # parameters of new() sets a member.  A variable ":legacy" declares is
      # not one of the function, it has no scope.
      if index(VARIABLE_KINDS, s.kind) < 0 || s.name == '_'
          || (!param && !s->has_key('scope_start'))
          || (param && (s.name == 'this' || (s.name_col > 0
            && strpart(lines[s.line], s.name_col - 1, 1) == '.')))
          || Used(s, f)
        continue
      endif
      add(out, {line: s.line, col: s.name_col, end_col: s.name_end,
        message: (param ? 'Unused parameter: ' : 'Unused variable: ')
          .. s.name,
        severity: parse.SEVERITY_HINT, tags: [parse.TAG_UNNECESSARY]})
    endfor
  endfor
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
