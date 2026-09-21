vim9script

# vim9ls - document symbols
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './util.vim'

# The parsed symbols as LSP DocumentSymbol items, positions in "encoding".
export def DocumentSymbols(symbols: list<dict<any>>, lines: list<string>,
    encoding: string): list<dict<any>>
  var out: list<dict<any>> = []
  for s in symbols
    # A parameter is not part of the outline.
    if s->get('param', false)
      continue
    endif
    var end_line = s.end_line
    var item = {
      name: s.name,
      kind: s.kind,
      range: util.Range(lines, s.line, s.col, end_line,
        strlen(lines->get(end_line, '')), encoding),
      selectionRange: util.Range(lines, s.line, s.name_col, s.line,
        s.name_end, encoding),
    }
    if s.detail != ''
      item.detail = s.detail
    endif
    if !s.children->empty()
      item.children = DocumentSymbols(s.children, lines, encoding)
    endif
    add(out, item)
  endfor
  return out
enddef

# The symbols of one script whose name holds "query", as LSP
# SymbolInformation items.  "container" is the symbol they are inside of.
export def WorkspaceSymbols(symbols: list<dict<any>>, lines: list<string>,
    uri: string, query: string, encoding: string,
    container = ''): list<dict<any>>
  var out: list<dict<any>> = []
  for s in symbols
    if s->get('param', false)
      continue
    endif
    if stridx(tolower(s.name), tolower(query)) >= 0
      var item = {
        name: s.name,
        kind: s.kind,
        location: {uri: uri, range: util.Range(lines, s.line, s.name_col,
          s.line, s.name_end, encoding)},
      }
      if container != ''
        item.containerName = container
      endif
      add(out, item)
    endif
    if !s.children->empty()
      out->extend(WorkspaceSymbols(s.children, lines, uri, query, encoding,
        s.name))
    endif
  endfor
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
