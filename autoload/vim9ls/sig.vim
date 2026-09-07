vim9script

# vim9ls - the call the cursor is in, for signature help
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './refs.vim'

# The innermost call that is still open at byte "col" of "line": the name
# of the function, the character in front of the name, whether it is a
# method call ("x->F(" makes "x" the first argument) and which argument the
# cursor is in.  null_dict when the cursor is not inside a call.
export def Call(line: string, col: number, vim9: bool): dict<any>
  var frames: list<dict<any>> = []
  for [seg_start, seg_end] in refs.CodeSpans(line, vim9).code
    var stop = min([seg_end, col]) - 1
    if stop < seg_start
      break
    endif
    for pos in range(seg_start, stop)
      var c = line[pos]
      if c == '('
        add(frames, {open: pos, commas: 0})
      elseif c == ')' && !frames->empty()
        remove(frames, -1)
      elseif c == ',' && !frames->empty()
        frames[-1].commas += 1
      endif
    endfor
  endfor
  # A "(" that opens a list, a lambda or a grouping is not a call.
  while !frames->empty()
    var frame = frames[-1]
    var name = matchstr(line[: frame.open - 1], refs.NAME .. '\+$')
    if name != '' && name =~ '^\h'
      var name_col = frame.open - strlen(name)
      var before = name_col == 0 ? '' : line[: name_col - 1]
      return {
        name: name,
        col: name_col,
        prev: name_col == 0 ? '' : line[name_col - 1],
        method: before =~ '->$',
        active: frame.commas,
      }
    endif
    remove(frames, -1)
  endwhile
  return null_dict
enddef

# The spans of the parameters in a signature label, as [start, end) byte
# pairs.  Help spells a parameter "{name}"; a script function separates them
# with commas at the top level.
export def Parameters(label: string): list<list<number>>
  var out: list<list<number>> = []
  # Help style: nothing between the parentheses but "{name}", "[, " and "]".
  if label =~ ')$'
      && matchstr(label, '(\zs.*\ze)$') =~ '^\%(\s\|,\|\[\|\]\|{[^}]*}\)*$'
    var pos = 0
    while true
      var m = matchstrpos(label, '{[^}]*}', pos)
      if m[1] < 0
        break
      endif
      add(out, [m[1], m[2]])
      pos = m[2]
    endwhile
    return out
  endif
  var open = stridx(label, '(')
  if open < 0
    return out
  endif
  var depth = 0
  var pos = open + 1
  var begin = -1
  while pos < strlen(label)
    var c = label[pos]
    if begin < 0 && c !~ '\s' && c != ')'
      begin = pos
    endif
    if c =~ '[(\[{<]'
      depth += 1
    elseif c =~ '[)\]}>]'
      if depth == 0
        if begin >= 0
          add(out, [begin, pos])
        endif
        break
      endif
      depth -= 1
    elseif c == ',' && depth == 0
      add(out, [begin, pos])
      begin = -1
    endif
    pos += 1
  endwhile
  return out
enddef

# The LSP SignatureHelp for "label", with the cursor in argument "active".
# Trailing spaces of a parameter span are not part of it.
export def Help(label: string, active: number,
    documentation: string = ''): dict<any>
  var params = Parameters(label)
    ->mapnew((_, p) => ({label: [p[0],
      p[1] - strlen(matchstr(label[p[0] : p[1] - 1], '\s*$'))]}))
  var signature: dict<any> = {label: label, parameters: params}
  if documentation != ''
    signature.documentation = {kind: 'plaintext', value: documentation}
  endif
  return {
    signatures: [signature],
    activeSignature: 0,
    activeParameter: params->empty() ? 0 : min([active, len(params) - 1]),
  }
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
