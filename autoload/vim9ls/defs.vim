vim9script

# vim9ls - a script with nothing but its definitions
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# Unless util.DRYRUN is set, the checker sources this in place of the
# script, so that nothing the script does runs: what remains are
# "vim9script", the imports, the functions, classes, interfaces, enums and
# type aliases, and the declarations of the script variables without their
# values.  Everything else is blanked; a definition inside a block stays,
# the block does not.  A declaration gets its declared type or "any", a
# "const" or "final" becomes a "var", which needs no value.  A function or a
# class defined a second time, in the other branch of an ":if" for one, gets
# a name of its own.
# An enum becomes a class, which makes no values: a static variable stands
# for each value, and the builtin "name", "ordinal" and "values" are
# declared.  The arguments of each value, and the value of a static class
# variable, which its declaration loses, go to a static method that is
# compiled and never called.  These lines are added; Lines() gives the line
# of the script for each line.

import autoload './parse.vim'
import autoload './selection.vim'

const BLOCKS = [parse.KIND_FUNCTION, parse.KIND_CLASS, parse.KIND_INTERFACE,
  parse.KIND_ENUM]

const STATIC = '^\(\s*\%(public\s\+\)\=static\s\+\)\%(var\|const\|final\)\s\+'
  .. '\h\w*\%(\s*:\s*[^=]\{-}\)\=\s*=\s*'

# The declaration of "s", a script variable, on the line "line".  A ":let"
# stays one, for Vim to report it.
def Declaration(line: string, s: dict<any>): string
  var lead = matchstr(line, '^\s*\%(export\s\+\)\=')
  if line =~ '^\s*let\>'
    return lead .. 'let ' .. s.name
  endif
  return lead .. 'var ' .. s.name .. ': ' .. (s.detail == '' ? 'any' : s.detail)
enddef

# "line" with the name "name" after its "def", "function", "class" and the
# like replaced by "other".
def Rename(line: string, name: string, other: string): string
  return substitute(line, '\V\<' .. escape(name, '\') .. '\>', other, '')
enddef

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

# The lines of the parsed script "lines" with its definitions only, see
# above, as {lines, origin}: "origin" has the line of the script for each
# line.
export def Lines(parsed: dict<any>, lines: list<string>): dict<any>
  var out = lines->mapnew((_, _) => '')
  var count = len(lines)
  var seen: dict<bool> = {}
  var declared: dict<list<string>> = {}
  # The lines added after a line of the script, as [text, origin].
  var added: dict<list<list<any>>> = {}
  var Add = (after: number, text: string, from: number) => {
    if !added->has_key(after)
      added[after] = []
    endif
    add(added[after], [text, from])
  }
  var checks = 0
  for s in parsed.symbols
    if s.line >= count
      continue
    endif
    if index(BLOCKS, s.kind) >= 0 && s.detail != ':command'
      var end = min([s.end_line, count - 1])
      for lnum in range(s.line, end)
        out[lnum] = lines[lnum]
      endfor
      var indent = matchstr(lines[s.line], '^\s*') .. '  '
      if s.kind == parse.KIND_ENUM
        out[s.line] = substitute(out[s.line], '\<enum\>', 'class', '')
        out[end] = substitute(out[end], '^\s*\zsendenum\>', 'endclass', '')
        for decl in ['final name: string', 'final ordinal: number',
            $'static final values: list<{s.name}>']
          Add(s.line, indent .. decl, s.line)
        endfor
        if s.children->indexof((_, c) => c.name == 'new') < 0
          Add(s.line, indent .. 'def new()', s.line)
          Add(s.line, indent .. 'enddef', s.line)
        endif
        var rest = s.children->copy()
          ->filter((_, c) => c.kind != parse.KIND_ENUM_MEMBER)
        var values_end = (rest->empty() ? end : rest[0].line) - 1
        for lnum in range(s.line + 1, values_end)
          out[lnum] = ''
        endfor
        # The declarations first: a value may be on the line the methods go
        # after.
        var values = Values(lines, s.line + 1, values_end)
        for v in values
          var decl = $'{indent}static var {v.name}: {s.name}'
          if out[v.line] == ''
            out[v.line] = decl
          else
            Add(v.line, decl, v.line)
          endif
        endfor
        for v in values
          checks += 1
          for l in Check(indent, checks, $'{s.name}.new({v.args})')
            Add(end - 1, l, v.line)
          endfor
        endfor
      endif
      if s.kind == parse.KIND_CLASS || s.kind == parse.KIND_ENUM
        for c in s.children
          if c.kind != parse.KIND_FIELD || c.line >= count
              || lines[c.line] !~ STATIC
            continue
          endif
          var last = selection.StatementAt(lines, c.line)[1]
          var m = matchlist(Joined(lines, c.line, last), STATIC .. '\(.*\)$')
          out[c.line] = matchstr(lines[c.line], STATIC)->matchstr(
            '^\s*\%(public\s\+\)\=static\s\+') .. $'var {c.name}: '
            .. (c.detail == '' ? 'any' : c.detail)
          for lnum in range(c.line + 1, last)
            out[lnum] = ''
          endfor
          checks += 1
          for l in Check(indent, checks, $'{c.name} = {m[2]}')
            Add(end - 1, l, c.line)
          endfor
        endfor
      endif
      if seen->has_key(s.name)
        out[s.line] = Rename(out[s.line], s.name,
          s.name .. '_vim9ls' .. (s.line + 1))
      endif
      seen[s.name] = true
    elseif s.kind == parse.KIND_MODULE
      out[s.line] = lines[s.line]
    elseif parsed.vim9 && !s->has_key('scope_start')
        && (s.kind == parse.KIND_VARIABLE || s.kind == parse.KIND_CONSTANT)
      if !declared->has_key(s.line)
        declared[s.line] = []
      endif
      add(declared[s.line], Declaration(lines[s.line], s))
    endif
  endfor
  for [lnum, decls] in items(declared)
    out[str2nr(lnum)] = join(decls, ' | ')
  endfor
  var heredoc: dict<bool> = {}
  for lnum in parsed.heredoc_lines
    heredoc[lnum] = true
  endfor
  for lnum in range(count)
    if !heredoc->has_key(lnum)
        && (lines[lnum] =~ '^\s*vim9s\%[cript]\>'
          || lines[lnum] =~ '^\s*\%(export\s\+\)\=type\s\+\u')
      out[lnum] = lines[lnum]
    endif
  endfor
  var result: list<string> = []
  var origin: list<number> = []
  for lnum in range(count)
    add(result, out[lnum])
    add(origin, lnum)
    for [text, from] in added->get(lnum, [])
      add(result, text)
      add(origin, from)
    endfor
  endfor
  return {lines: result, origin: origin}
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
