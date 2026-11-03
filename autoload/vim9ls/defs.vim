vim9script

# vim9ls - what a dry run of a script leaves unchecked
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# ":source ++dryrun" does not evaluate the value of a static class variable
# nor the arguments of the enum values.  Checks() adds them to the script as
# static methods that are compiled and never called.  Nor does it run
# ":execute" and ":source".

import autoload './parse.vim'
import autoload './selection.vim'

const STATIC = '^\s*\%(public\s\+\)\=static\s\+\(var\|const\|final\)\s\+'
  .. '\h\w*\%(\s*:\s*\([^=]\{-}\)\)\=\s*=\s*'

# The lines "first" to "last" of "lines" as one, without their comments.
def Joined(lines: list<string>, first: number, last: number): string
  return lines[first : last]
    ->mapnew((_, l) => trim(substitute(l, '\s#\%(\s.*\)\=$', '', '')))
    ->join(' ')
enddef

# The values of an enum on the lines "first" to "last", as {name, args,
# line}: what is between the commas outside brackets and strings, a name
# with the arguments in brackets after it, if any.
def Values(lines: list<string>, first: number, last: number): list<dict<any>>
  var text = Joined(lines, first, last)
  # Where each line starts in "text", for the line of a value.
  var starts: list<number> = []
  var at = 0
  for lnum in range(first, last)
    add(starts, at)
    at += strlen(Joined(lines, lnum, lnum)) + 1
  endfor
  var items: list<list<any>> = []
  var depth = 0
  var quote = ''
  var start = 0
  var i = 0
  while i < strlen(text)
    var c = strpart(text, i, 1)
    if quote != ''
      if c == '\' && quote == '"'
        i += 1
      elseif c == quote
        quote = ''
      endif
    elseif c == '"' || c == "'"
      quote = c
    elseif c == '(' || c == '['  || c == '{'
      depth += 1
    elseif c == ')' || c == ']'  || c == '}'
      depth -= 1
    elseif c == ',' && depth == 0
      add(items, [start, strpart(text, start, i - start)])
      start = i + 1
    endif
    i += 1
  endwhile
  add(items, [start, strpart(text, start)])
  var values: list<dict<any>> = []
  for [offset, item] in items
    var name = matchstr(item, '^\s*\zs\h\w*')
    if name == ''
      continue
    endif
    var where = offset + match(item, '\h')
    var k = len(starts) - 1
    while k > 0 && starts[k] > where
      k -= 1
    endwhile
    add(values, {name: name, line: first + k,
      args: matchstr(item, '^\s*\h\w*\s*(\zs.*\ze)\s*$')})
  endfor
  return values
enddef

# A static method that is never called, with "statement" for its body.
def Check(indent: string, k: number, statement: string): list<string>
  return [$'{indent}static def _Vim9lsCheck{k}()', $'{indent}  {statement}',
    $'{indent}enddef']
enddef

const NAME = '\%([sgbwtl]:\)\=\h\w*'
const DECLARE = '^\s*\%(\%(let\|var\|const\|final\)\s\+\)\='
const TYPE = '\%(\s*:\s*[^=]\{-1,}\)\='
const COMMENT = '\s*\%(#.*\)\=$'
# A heredoc assigned to a variable: the name, "eval" and the end marker.
const HEREDOC_LET = DECLARE .. '\(' .. NAME .. '\)' .. TYPE
  .. '\s*=<<\%(\s\+trim\)\=\(\s\+eval\)\=\s\+\(\S\+\)'
# Any other value assigned to a variable.
const ASSIGN = DECLARE .. '\(' .. NAME .. '\)' .. TYPE
  .. '\s*=\%([=~<]\)\@!\s*\(.\{-}\)' .. COMMENT
# A list appended to another one.
const APPEND = [
  '^\s*\%(let\s\+\)\=\(' .. NAME .. '\)\s*+=\s*\(' .. NAME .. '\)' .. COMMENT,
  '^\s*\%(call\s\+\)\=extend(\s*\(' .. NAME .. '\)\s*,\s*\(' .. NAME
    .. '\)\s*)' .. COMMENT,
  '^\s*\(' .. NAME .. '\)->extend(\s*\(' .. NAME .. '\)\s*)' .. COMMENT]
# A change to a list by other means.
const CHANGES = '\%(add\|insert\|extend\|map\|filter\|remove\)('
const CHANGE = [
  '\<' .. CHANGES .. '\s*\(' .. NAME .. '\)\s*,',
  '\<\(' .. NAME .. '\)\%(\s*+=\|->' .. CHANGES .. '\)']
const EXECUTE = '^\s*\%(:\s*\)*exe\%[cute]\s\+join(\s*\(' .. NAME
  .. '\)\s*,\s*"\\n"\s*)' .. COMMENT
# A list written to a file and the file name.
const WRITEFILE = '^\s*\%(call\s\+\)\=writefile(\s*\(' .. NAME
  .. '\)\s*,\s*\(.\{-}\)\s*\%(,[^,]*\)\=)' .. COMMENT
# ":source" with a file name, ":execute" with an expression for it.
const SOURCE = '^\s*\%(:\s*\)*so\%[urce]\s\+\(.\{-}\)' .. COMMENT
const SOURCE_EXPR = '^\s*\%(:\s*\)*exe\%[cute]\s\+\([''"]\)so\%[urce]\s*\1'
  .. '\s*\%(\.\.\=\s*\)\=\%(fnameescape(\s*\(.\{-}\)\s*)\|\(.\{-}\)\)'
  .. COMMENT

# For each line at the script level that runs a list with ":execute" or
# ":source", the lines of text of the heredocs the list was made of.  A list
# made of anything else, or of a heredoc that evaluates, gets none.
def Executed(parsed: dict<any>, lines: list<string>): dict<list<number>>
  var heredoc: dict<bool> = {}
  for lnum in parsed.heredoc_lines
    heredoc[lnum] = true
  endfor
  var skip = copy(heredoc)
  for s in parsed.symbols
    if index([parse.KIND_FUNCTION, parse.KIND_METHOD, parse.KIND_CLASS,
        parse.KIND_INTERFACE, parse.KIND_ENUM], s.kind) >= 0
      for lnum in range(s.line, min([s.end_line, len(lines) - 1]))
        skip[lnum] = true
      endfor
    endif
  endfor
  # The lines of text of each list, null when it holds something else.
  var texts: dict<list<number>> = {}
  var files: dict<list<number>> = {}
  var executed: dict<list<number>> = {}
  for lnum in range(len(lines))
    if skip->has_key(lnum)
      continue
    endif
    var line = lines[lnum]
    var m = matchlist(line, HEREDOC_LET)
    if !m->empty()
      var last = lnum + 1
      while last < len(lines) && heredoc->has_key(last)
        last += 1
      endwhile
      texts[m[1]] = m[2] != '' || last == lnum + 1
        || trim(lines[last - 1]) != m[3] ? null_list
        : range(lnum + 1, last - 2)
      continue
    endif
    var appended = false
    for p in APPEND
      m = matchlist(line, p)
      if !m->empty()
        var [to, from] = [texts->get(m[1], []), texts->get(m[2], null_list)]
        texts[m[1]] = to == null || from == null ? null_list : to + from
        appended = true
        break
      endif
    endfor
    if appended
      continue
    endif
    m = matchlist(line, EXECUTE)
    var text = m->empty() ? null_list : texts->get(m[1], null_list)
    if m->empty()
      m = matchlist(line, SOURCE_EXPR)
      var file = m->empty() ? '' : m[2] .. m[3]
      if file == ''
        file = string(matchlist(line, SOURCE)->get(1, ''))
      endif
      text = files->get(file, null_list)
    endif
    if text != null && !text->empty()
      executed[lnum] = text
      continue
    endif
    m = matchlist(line, WRITEFILE)
    if !m->empty()
      files[m[2]] = texts->get(m[1], null_list)
      continue
    endif
    m = matchlist(line, ASSIGN)
    if !m->empty()
      texts[m[1]] = m[2] =~ '^\[\s*\]$' ? [] : null_list
      continue
    endif
    for p in CHANGE
      var at = 0
      while true
        var found = matchlist(line, p, at)
        if found->empty()
          break
        endif
        texts[found[1]] = null_list
        at = matchend(line, p, at)
      endwhile
    endfor
  endfor
  return executed
enddef

# The parsed script "lines" with those methods, and with the heredocs of
# Executed() in place of the line that runs them, as {lines, origin}:
# "origin" has the line of the script for each line.  An enum cannot call
# its own new(), so the methods for its values go to a class after the
# script that has the variables and the new() of the enum; the other lines
# of that class have the origin -1.
export def Checks(parsed: dict<any>, lines: list<string>): dict<any>
  var count = len(lines)
  var added: dict<list<list<any>>> = {}
  var tail: list<list<any>> = []
  var checks = 0
  for s in parsed.symbols
    if s.line >= count
        || (s.kind != parse.KIND_CLASS && s.kind != parse.KIND_ENUM)
      continue
    endif
    var end = min([s.end_line, count - 1])
    var indent = matchstr(lines[s.line], '^\s*') .. '  '
    for c in s.children
      if c.kind != parse.KIND_FIELD || c.line >= count
          || lines[c.line] !~ STATIC
        continue
      endif
      var last = selection.StatementAt(lines, c.line)[1]
      var m = matchlist(Joined(lines, c.line, last), STATIC .. '\(.*\)$')
      checks += 1
      # A constant cannot be assigned to: its value initializes a local
      # variable of the same type.
      var statement = m[1] == 'var' ? $'{c.name} = {m[3]}'
        : m[2] == '' ? $'var _vim9ls_value = {m[3]}'
        : $'var _vim9ls_value: {m[2]} = {m[3]}'
      for l in Check(indent, checks, statement)
        if !added->has_key(end - 1)
          added[end - 1] = []
        endif
        add(added[end - 1], [l, c.line])
      endfor
    endfor
    if s.kind != parse.KIND_ENUM
      continue
    endif
    var copy = 'Vim9lsEnum_' .. s.name
    add(tail, [$'class {copy}', -1])
    var has_new = false
    for c in s.children
      if c.line >= count || (c.kind != parse.KIND_FIELD
          && (c.kind != parse.KIND_METHOD || c.name != 'new'))
          || lines[c.line] =~ STATIC
        continue
      endif
      has_new = has_new || c.kind == parse.KIND_METHOD
      var last = c.kind == parse.KIND_METHOD ? min([c.end_line, count - 1])
        : selection.StatementAt(lines, c.line)[1]
      for lnum in range(c.line, last)
        add(tail, [lines[lnum], -1])
      endfor
    endfor
    if !has_new
      tail += [['  def new()', -1], ['  enddef', -1]]
    endif
    var rest = s.children->copy()
      ->filter((_, c) => c.kind != parse.KIND_ENUM_MEMBER)
    var values_end = (rest->empty() ? end : rest[0].line) - 1
    for v in Values(lines, s.line + 1, values_end)
      checks += 1
      for l in Check('  ', checks, $'{copy}.new({v.args})')
        add(tail, [l, v.line])
      endfor
    endfor
    add(tail, ['endclass', -1])
  endfor
  var executed = Executed(parsed, lines)
  var result: list<string> = []
  var origin: list<number> = []
  for lnum in range(count)
    for from in executed->get(lnum, [lnum])
      add(result, lines[from])
      add(origin, from)
    endfor
    for [text, from] in added->get(lnum, [])
      add(result, text)
      add(origin, from)
    endfor
  endfor
  for [text, from] in tail
    add(result, text)
    add(origin, from)
  endfor
  return {lines: result, origin: origin}
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
