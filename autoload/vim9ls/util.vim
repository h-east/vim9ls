vim9script

# vim9ls - conversions between Vim and LSP representations
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

# Characters that may appear in a URI path without being escaped.
const UNRESERVED = '[A-Za-z0-9\-._~/]'

def PercentEncode(s: string): string
  var out = ''
  for byte in str2blob([s])->blob2list()
    out ..= printf('%%%02X', byte)
  endfor
  return out
enddef

# An escape stands for one byte, not one character, so the bytes are collected
# first and only then read back as text.
def PercentDecode(s: string): string
  var bytes: list<number> = []
  var i = 0
  var len = strlen(s)
  while i < len
    var c = strpart(s, i, 1)
    if c == '%' && i + 2 < len
      bytes->add(str2nr(strpart(s, i + 1, 2), 16))
      i += 3
    else
      bytes->add(char2nr(c))
      i += 1
    endif
  endwhile
  return list2blob(bytes)->blob2str()->get(0, '')
enddef

# The full path of "path" the way the server spells every path, so that two
# spellings of one file compare equal: simplified, and on MS-Windows with "/"
# for every "\".
export def FullPath(path: string): string
  var full = simplify(fnamemodify(path, ':p'))
  return has('win32') ? substitute(full, '\\', '/', 'g') : full
enddef

export def PathToUri(path: string): string
  var full = FullPath(path)
  # A drive letter needs a leading slash: "C:/x" becomes "/C:/x".
  if has('win32') && full =~ '^\a:'
    full = '/' .. full
  endif
  return 'file://' .. substitute(full, UNRESERVED .. '\@!.',
    (m) => PercentEncode(m[0]), 'g')
enddef

# A URI with any other scheme is returned unchanged: there is no file for it
# to name.
export def UriToPath(uri: string): string
  if uri !~? '^file://'
    return uri
  endif
  var path = PercentDecode(uri[7 : ])
  if has('win32') && path =~ '^/\a:'
    path = path[1 : ]
  endif
  return FullPath(path)
enddef

# LSP counts a position in the encoding agreed on at initialize, the server
# counts bytes; both are zero-based here.  "utf-8" needs no conversion, the
# other two count a composing character on its own.

export def ColToLsp(line: string, col: number, encoding: string): number
  if encoding ==# 'utf-8'
    return col
  endif
  if col >= strlen(line)
    return encoding ==# 'utf-32' ? strcharlen(line) : strutf16len(line, true)
  endif
  var idx = encoding ==# 'utf-32' ? charidx(line, col, true)
    : utf16idx(line, col, true)
  return idx < 0 ? 0 : idx
enddef

export def ColFromLsp(line: string, character: number,
    encoding: string): number
  var last = strlen(line)
  if encoding ==# 'utf-8'
    return character > last ? last : character
  endif
  var idx = encoding ==# 'utf-32' ? byteidxcomp(line, character)
    : byteidxcomp(line, character, true)
  return idx < 0 ? last : idx
enddef

export def Position(lines: list<string>, line: number, col: number,
    encoding: string): dict<number>
  var text = lines->get(line, '')
  return {line: line, character: ColToLsp(text, col, encoding)}
enddef

export def Range(lines: list<string>, line: number, col: number,
    end_line: number, end_col: number, encoding: string): dict<any>
  return {
    start: Position(lines, line, col, encoding),
    end: Position(lines, end_line, end_col, encoding),
  }
enddef

# Goes to the channel log, when there is one ($VIM9LS_LOG or ch_logfile()).
export def Log(msg: string)
  ch_log('vim9ls: ' .. msg)
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
