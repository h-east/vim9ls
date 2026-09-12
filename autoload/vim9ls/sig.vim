vim9script

# vim9ls - the call the cursor is in, for signature help
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './refs.vim'

# How far up a call may have started.
const LOOKBACK = 30

# The innermost call still open at byte "col" of line "lnum": the name of
# the function, its line and column, the character in front of the name,
# whether it is a method call ("x->F(" makes "x" the first argument) and
# which argument the cursor is in.  null_dict when the cursor is not inside
# a call.  "vim9_at" tells for each line whether Vim9 rules apply.
export def CallAt(lines: list<string>, lnum: number, col: number,
    vim9_at: list<bool>): dict<any>
  var frames: list<dict<any>> = []
  # The call may have started on an earlier line; read from each line above
  # in turn until one leaves a "(" open at the cursor.
  for start in range(lnum, max([0, lnum - LOOKBACK]), -1)
    frames = []
    for at in range(start, lnum)
      var line = lines[at]
      var limit = at == lnum ? col : strlen(line)
      for [seg_start, seg_end] in refs.CodeSpans(line, vim9_at[at]).code
        var stop = min([seg_end, limit]) - 1
        if stop < seg_start
          break
        endif
        for pos in range(seg_start, stop)
          var c = line[pos]
          if c == '('
            add(frames, {line: at, open: pos, commas: 0})
          elseif c == ')' && !frames->empty()
            remove(frames, -1)
          elseif c == ',' && !frames->empty()
            frames[-1].commas += 1
          endif
        endfor
      endfor
    endfor
    # A "(" that opens a list, a lambda or a grouping is not a call.
    while !frames->empty()
      var frame = frames[-1]
      var line = lines[frame.line]
      var name = matchstr(line[: frame.open - 1], refs.NAME .. '\+$')
      if name != '' && name =~ '^\h'
        var name_col = frame.open - strlen(name)
        var before = name_col == 0 ? '' : line[: name_col - 1]
        return {
          name: name,
          line: frame.line,
          col: name_col,
          prev: name_col == 0 ? '' : line[name_col - 1],
          method: before =~ '->$',
          active: frame.commas,
        }
      endif
      remove(frames, -1)
    endwhile
  endfor
  return null_dict
enddef

# CallAt() for a single line.
export def Call(line: string, col: number, vim9: bool): dict<any>
  return CallAt([line], 0, col, [vim9])
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

# The names help gives an argument that are a type: with several types such a
# name contradicts the others.
const TYPE_NAMES = ['number', 'string', 'float', 'bool', 'blob', 'list',
  'dict', 'tuple', 'func', 'object', 'class', 'job', 'channel']

# The signature of a builtin from what exists_info() reports, "info", with
# the names the help "label" gives the arguments: "name({a}: type [, {b}:
# type]): type".  The number of arguments and the optional ones come from the
# info, the types of an argument are joined with " | ".  An argument the help
# does not name, or that accepts several types and is named after one of them,
# "{list}" of get(), is named "{argN}".  The last argument gets " ..." when
# there is no maximum or the help writes "..." after it.  Returns {label,
# parameters}, the parameters as [start, end) byte pairs.
export def Typed(label: string, info: dict<any>): dict<any>
  var names = Parameters(label)
    ->mapnew((_, p) => substitute(label[p[0] : p[1] - 1], '\s*\.\.\.$', '',
      ''))
  var args: list<dict<any>> = info->get('args', [])
  var min = info->get('minargs', len(args))
  var max = info->get('maxargs', len(args))
  var count = max < 0 ? len(args) : max
  var more = max < 0
  if label =~ '\.\.\.' && count > len(names)
    count = max([len(names), min])
    more = true
  endif
  var out = label[: stridx(label, '(')]
  var params: list<list<number>> = []
  var optional = 0
  for i in range(count)
    if i > 0
      out ..= i >= min ? ' [, ' : ', '
    elseif i >= min
      out ..= '['
    endif
    if i >= min
      optional += 1
    endif
    var name = names->get(i, '')
    var types = args->get(i, {types: []}).types
    if name == '' || (len(types) > 1
        && index(TYPE_NAMES, matchstr(name, '^{\zs\w*\ze}$')) >= 0)
      name = '{arg' .. (i + 1) .. '}'
    endif
    var begin = strlen(out)
    out ..= name .. (types->empty() ? '' : ': ' .. join(types, ' | '))
    if i == count - 1 && more
      out ..= ' ...'
    endif
    add(params, [begin, strlen(out)])
  endfor
  out ..= repeat(']', optional) .. ')'
  var returns = info->get('returns', '')
  if returns != '' && returns != 'any'
    out ..= ': ' .. returns
  endif
  return {label: out, parameters: params}
enddef

# The LSP SignatureHelp for "label", with the cursor in argument "active".
# The parameter spans are found in the label unless "spans" gives them.
# Trailing spaces of a parameter span are not part of it.
export def Help(label: string, active: number, documentation: string = '',
    spans: any = null): dict<any>
  var params = (spans == null ? Parameters(label) : spans)
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
