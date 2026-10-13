vim9script

# vim9ls - a script with nothing but its definitions
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# Unless util.DRYRUN is set, the checker sources this in place of the
# script, so that nothing the script does runs: what remains are
# "vim9script", the imports, the functions, classes, interfaces, enums and
# type aliases, and the declarations of the script variables without their
# values.  Everything else is blanked, every line staying where it was; a
# definition inside a block stays, the block does not.  A declaration gets
# its declared type or "any", a "const" or "final" becomes a "var", which
# needs no value, and a static class variable loses its value the same way.
# A function or a class defined a second time, in the other branch of an
# ":if" for one, gets a name of its own.  An enum stays as it is: its values
# are made, by its constructor, when the script is sourced.

import autoload './parse.vim'

const BLOCKS = [parse.KIND_FUNCTION, parse.KIND_CLASS, parse.KIND_INTERFACE,
  parse.KIND_ENUM]

# The declaration of "s", a script variable, on the line "line".  A ":let"
# stays one, for Vim to report it.
def Declaration(line: string, s: dict<any>): string
  var lead = matchstr(line, '^\s*\%(export\s\+\)\=')
  if line =~ '^\s*let\>'
    return lead .. 'let ' .. s.name
  endif
  return lead .. 'var ' .. s.name .. ': ' .. (s.detail == '' ? 'any' : s.detail)
enddef

# "line" declares a static class variable "s"; the same without its value.
def StaticDeclaration(line: string, s: dict<any>): string
  var m = matchlist(line,
    '^\(\s*\%(public\s\+\)\=static\s\+\)\%(var\|const\|final\)\s.\{-}=')
  if m->empty()
    return line
  endif
  return m[1] .. 'var ' .. s.name .. ': ' .. (s.detail == '' ? 'any' : s.detail)
enddef

# "line" with the name "name" after its "def", "function", "class" and the
# like replaced by "other".
def Rename(line: string, name: string, other: string): string
  return substitute(line, '\V\<' .. escape(name, '\') .. '\>', other, '')
enddef

# The lines of the parsed script "lines" with its definitions only, see above.
export def Lines(parsed: dict<any>, lines: list<string>): list<string>
  var out = lines->mapnew((_, _) => '')
  var count = len(lines)
  var seen: dict<bool> = {}
  var declared: dict<list<string>> = {}
  for s in parsed.symbols
    if s.line >= count
      continue
    endif
    if index(BLOCKS, s.kind) >= 0 && s.detail != ':command'
      for lnum in range(s.line, min([s.end_line, count - 1]))
        out[lnum] = lines[lnum]
      endfor
      if seen->has_key(s.name)
        out[s.line] = Rename(out[s.line], s.name,
          s.name .. '_vim9ls' .. (s.line + 1))
      endif
      seen[s.name] = true
      if s.kind == parse.KIND_CLASS || s.kind == parse.KIND_ENUM
        for c in s.children
          if c.kind == parse.KIND_FIELD && c.line < count
              && lines[c.line] =~ '^\s*\%(public\s\+\)\=static\s'
            out[c.line] = StaticDeclaration(lines[c.line], c)
          endif
        endfor
      endif
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
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
