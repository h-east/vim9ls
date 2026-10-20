vim9script

# vim9ls - what a dry run of a script leaves unchecked
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# ":source ++dryrun" does not evaluate the value of a static class variable
# nor the arguments of the enum values.  Checks() adds them to the script as
# static methods that are compiled and never called.

import autoload './parse.vim'
import autoload './selection.vim'

const STATIC = '^\(\s*\%(public\s\+\)\=static\s\+\)\%(var\|const\|final\)\s\+'
  .. '\h\w*\%(\s*:\s*[^=]\{-}\)\=\s*=\s*'

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

# The parsed script "lines" with those methods, as {lines, origin}: "origin"
# has the line of the script for each line.  An enum cannot call its own
# new(), so the methods for its values go to a class after the script that
# has the variables and the new() of the enum; the other lines of that class
# have the origin -1.
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
      for l in Check(indent, checks, $'{c.name} = {m[2]}')
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
  var result: list<string> = []
  var origin: list<number> = []
  for lnum in range(count)
    add(result, lines[lnum])
    add(origin, lnum)
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
