vim9script

# vim9ls - the ranges a selection grows through
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>

import autoload './parse.vim'
import autoload './util.vim'

const CLOSER = {'(': ')', '[': ']', '{': '}'}
# The characters that shape a line: quotes, comments and brackets.
const STRUCTURE = '[''"#()[\]{}]'
# A line that starts with an operator carries on the line above it, and one
# that ends with an operator reaches the line below it.  Both are for Vim9
# script, where a legacy ":%s" or ":.,$d" cannot be taken for one; legacy
# script reaches back with a "\" at the start of a line instead.  OPSTART
# and TRAILEND are the characters to look for before the patterns.
const CONTINUES = '^\s*\%(->\|\.\.\|&&\|||\|??\|==\|!=\|=\~\|!\~'
  .. '\|[<>]=\|[-+*/%.,?<>]\|:\%(\s\|$\)\|[)\]}]\)'
const OPSTART = '-+*/%.,?<>&|=!:)]}'
const TRAILEND = '-+*%.,?([{='
const TRAILPAIR = '\%(&&\|||\|->\)$'
const WORD = '[[:alnum:]_]'
# A name with its scope or its autoload path, and a member of an object.
const NAME = '[[:alnum:]_:#.]'

def Indent(line: string): number
  return line =~ '^\s*$' ? 0 : strlen(matchstr(line, '^\s*'))
enddef

# A range that begins past the last character of a line, or ends among the
# blanks that a line starts with, cannot be selected as it stands; it is
# moved to the text it holds.
def Trim(lines: list<string>, spot: list<number>): list<number>
  var [line, col, end_line, end_col] = spot
  while line < end_line && strpart(lines[line], col) =~ '^\s*$'
    line += 1
    col = Indent(lines[line])
  endwhile
  while end_line > line && strpart(lines[end_line], 0, end_col) =~ '^\s*$'
    end_line -= 1
    end_col = strlen(lines[end_line])
  endwhile
  return [line, col, end_line, end_col]
enddef

# Whether the first position is at or in front of the second one.
def Ahead(line: number, col: number, other: number, other_col: number): bool
  return line < other || (line == other && col <= other_col)
enddef

# Past the closing quote of the string that opens at "at", or the end of the
# line when it has none.
def StringEnd(line: string, at: number, quote: string): number
  var last = strlen(line)
  var pat = quote == '"' ? '["\\]' : "'"
  var i = at + 1
  while i < last
    var m = matchstrpos(line, pat, i)
    if m[1] < 0
      break
    endif
    if m[0] == '\'
      i = m[1] + 2
      continue
    endif
    # Two quotes in a row stand for one inside a literal string.
    if quote == "'" && strpart(line, m[1] + 1, 1) == "'"
      i = m[1] + 2
      continue
    endif
    return m[1] + 1
  endwhile
  return last
enddef

# Where the strings, the comments and the bracket pairs of the document are,
# and where each statement begins and ends.  One pass over the text, so that
# the cost is the same wherever the request points.
def Scan(lines: list<string>, parsed: dict<any>): dict<any>
  var heredoc: dict<bool> = {}
  for lnum in parsed.heredoc_lines
    heredoc[lnum] = true
  endfor
  var quoted: dict<list<list<number>>> = {}
  var comment: dict<number> = {}
  # Only a bracket that finds its match makes a pair.  "by_open" has them
  # again under the place they open at, for a name that stands in front.
  var pairs: list<list<number>> = []
  var by_open: dict<list<number>> = {}
  var open: list<list<any>> = []
  # Whether each line reaches the one below it, and the first character of
  # each line, which the statements are worked out from.
  var carries: list<bool> = []
  var heads: list<string> = []
  var branch_at: list<bool> = []
  var vim9_at = parse.Vim9Lines(parsed, len(lines))
  for lnum in range(len(lines))
    var line = lines[lnum]
    var bare = trim(line, " \t")
    var head = strpart(bare, 0, 1)
    add(heads, head)
    # A bracket of a line that ends without reaching this one can no longer
    # find its match.  One opened further up still can: the lines of a
    # block end where they will.
    if lnum > 0 && !carries[lnum - 1] && head != '\'
      while !open->empty() && open[-1][0] == lnum - 1
        remove(open, -1)
      endwhile
    endif
    add(branch_at, stridx('ecf', head) >= 0
      && bare =~ '^\%(else\|elseif\|catch\|finally\)\>')
    if heredoc->has_key(lnum)
      add(carries, false)
      continue
    endif
    var vim9 = vim9_at[lnum]
    var last = strlen(line)
    var i = 0
    while i < last
      var m = matchstrpos(line, STRUCTURE, i)
      if m[1] < 0
        break
      endif
      var c = m[0]
      var at = m[1]
      i = at + 1
      # In Vim9 script "#" opens a comment where it stands on its own and
      # '"' is a string; in legacy script a comment starts with '"' and only
      # a whole line can be a "#" one.
      if c == '#'
        if vim9 ? (at == 0 || strpart(line, at - 1, 1) =~ '\s')
            : strpart(line, 0, at) =~ '^\s*$'
          comment[lnum] = at
          break
        endif
        continue
      endif
      if c == '"' && !vim9 && strpart(line, 0, at) =~ '^\s*$'
        comment[lnum] = at
        break
      endif
      if c == '"' || c == "'"
        var stop = StringEnd(line, at, c)
        if !quoted->has_key(lnum)
          quoted[lnum] = []
        endif
        add(quoted[lnum], [at, stop])
        i = stop
        continue
      endif
      if CLOSER->has_key(c)
        add(open, [lnum, at, c])
      elseif !open->empty() && CLOSER[open[-1][2]] == c
        var start = remove(open, -1)
        var pair = [start[0], start[1], lnum, at]
        add(pairs, pair)
        by_open[$'{start[0]}:{start[1]}'] = pair
      endif
    endwhile
    var text = comment->has_key(lnum)
      ? trim(strpart(line, 0, comment[lnum]), " \t") : bare
    var tail = strpart(text, strlen(text) - 1, 1)
    # A comment or an empty line inside a list or a call leaves it as it
    # stands, so it reaches as far as the line above it does.
    add(carries, text == '' ? (lnum > 0 && carries[lnum - 1])
      : vim9 && (stridx(TRAILEND, tail) >= 0
        || (stridx('&|>', tail) >= 0 && text =~ TRAILPAIR)))
  endfor
  # The line each statement begins on, and the one it ends on.  The test is
  # spelled out here: a call and a match for every line of the document cost
  # more than the rest of the scan.
  var begins: list<number> = []
  for lnum in range(len(lines))
    var cont = lnum > 0 && (carries[lnum - 1] || heads[lnum] == '\'
      || (vim9_at[lnum] && stridx(OPSTART, heads[lnum]) >= 0
        && lines[lnum] =~ CONTINUES))
    add(begins, cont ? begins[lnum - 1] : lnum)
  endfor
  var ends = repeat([len(lines) - 1], len(lines))
  for lnum in range(len(lines) - 2, 0, -1)
    if begins[lnum + 1] == begins[lnum]
      ends[lnum] = ends[lnum + 1]
    else
      ends[lnum] = lnum
    endif
  endfor
  var blocks: list<list<number>> = []
  for s in parse.AllSymbols(parsed.symbols)
    if !s->get('param', false)
      add(blocks, [s.line, s.end_line])
    endif
  endfor
  for block in parsed.blocks
    add(blocks, [block.line, block.end_line])
  endfor
  # Each line that begins another branch of a block, ":else" and the like,
  # with the narrowest block it stands in.
  var order = range(len(blocks))
  sort(order, (a, b) => blocks[a][0] == blocks[b][0]
    ? blocks[b][1] - blocks[a][1] : blocks[a][0] - blocks[b][0])
  var branches: list<list<number>> = []
  var stack: list<number> = []
  var next = 0
  for lnum in range(len(lines))
    while next < len(order) && blocks[order[next]][0] <= lnum
      add(stack, order[next])
      next += 1
    endwhile
    while !stack->empty() && blocks[stack[-1]][1] < lnum
      remove(stack, -1)
    endwhile
    if branch_at[lnum] && !stack->empty()
      add(branches, [lnum, stack[-1]])
    endif
  endfor
  return {quoted: quoted, comment: comment, pairs: pairs, by_open: by_open,
    begins: begins, ends: ends, blocks: blocks, branches: branches}
enddef

# The run of characters that match "pat" around byte "col", or an empty list
# where there is none.
def Run(line: string, col: number, pat: string): list<number>
  var last = strlen(line)
  var at = col
  if at >= last || strpart(line, at, 1) !~ pat
    if at <= 0 || strpart(line, at - 1, 1) !~ pat
      return []
    endif
    at -= 1
  endif
  var begin = at
  while begin > 0 && strpart(line, begin - 1, 1) =~ pat
    begin -= 1
  endwhile
  var stop = at + 1
  while stop < last && strpart(line, stop, 1) =~ pat
    stop += 1
  endwhile
  return [begin, stop]
enddef

# The statement at "lnum", from the line it begins on to the one it ends on.
def Statement(lines: list<string>, scan: dict<any>,
    lnum: number): list<number>
  var first = scan.begins[lnum]
  var last = scan.ends[lnum]
  return [first, Indent(lines[first]), last, strlen(lines[last])]
enddef

# The blocks and the scopes of the scan that hold "lnum", innermost first,
# as places in "scan.blocks".
def Blocks(scan: dict<any>, lnum: number): list<number>
  var blocks: list<list<number>> = scan.blocks
  var out: list<number> = []
  for i in range(len(blocks))
    if blocks[i][0] <= lnum && lnum <= blocks[i][1]
      add(out, i)
    endif
  endfor
  return sort(out, (a, b) => (blocks[a][1] - blocks[a][0])
    - (blocks[b][1] - blocks[b][0]))
enddef

# What block "i" holds around "lnum", the branch of an ":if" or a ":try"
# rather than all of it, without the lines that open and close it.
def Body(scan: dict<any>, i: number, lnum: number): list<number>
  var top = scan.blocks[i][0] + 1
  var bot = scan.blocks[i][1] - 1
  for b in scan.branches
    if b[1] != i
      continue
    endif
    if b[0] <= lnum
      top = b[0] + 1
    elseif b[0] <= bot
      bot = b[0] - 1
      break
    endif
  endfor
  return [top, bot]
enddef

# The ranges to grow through at one position, innermost first, as the lines
# and byte columns of the document.
def Spots(lines: list<string>, scan: dict<any>, lnum: number,
    col: number): list<list<number>>
  var out: list<list<number>> = []
  var line = lines[lnum]
  for pat in [WORD, NAME]
    var run = Run(line, col, pat)
    if run->empty()
      continue
    endif
    add(out, [lnum, run[0], lnum, run[1]])
    # The call or the index the name heads, with the cursor in front of the
    # bracket rather than inside it.
    var p = scan.by_open->get($'{lnum}:{run[1]}', [])
    if !p->empty()
      add(out, [lnum, run[0], p[2], p[3] + 1])
    endif
  endfor
  for span in scan.quoted->get(lnum, [])
    if span[0] <= col && col < span[1]
      # The text between the quotes, then the string itself.
      add(out, [lnum, span[0] + 1, lnum, max([span[0] + 1, span[1] - 1])])
      add(out, [lnum, span[0], lnum, span[1]])
    endif
  endfor
  var at = scan.comment->get(lnum, -1)
  if at >= 0 && col >= at
    add(out, [lnum, at, lnum, strlen(line)])
  endif
  var inside: list<list<number>> = []
  for p in scan.pairs
    # Most of the pairs of a document are nowhere near the position.
    if p[0] > lnum || p[2] < lnum
      continue
    endif
    if (p[0] < lnum || p[1] <= col) && (p[2] > lnum || col <= p[3] + 1)
      add(inside, p)
    endif
  endfor
  sort(inside, (a, b) => a[0] == b[0] ? b[1] - a[1] : b[0] - a[0])
  for p in inside
    add(out, Trim(lines, [p[0], p[1] + 1, p[2], p[3]]))
    add(out, [p[0], p[1], p[2], p[3] + 1])
    # A call or an index goes with the name in front of the bracket.
    var name = Run(lines[p[0]], p[1] - 1, NAME)
    if !name->empty() && name[1] == p[1]
      add(out, [p[0], name[0], p[2], p[3] + 1])
    endif
  endfor
  add(out, Statement(lines, scan, lnum))
  for i in Blocks(scan, lnum)
    var [first, last] = scan.blocks[i]
    var [top, bot] = Body(scan, i, lnum)
    if bot >= top
      add(out, [top, Indent(lines[top]), bot, strlen(lines[bot])])
    endif
    add(out, [first, Indent(lines[first]), last, strlen(lines[last])])
  endfor
  var end = len(lines) - 1
  add(out, [0, 0, end, strlen(lines[end])])
  return out
enddef

# The chain the protocol asks for: the innermost range, with the wider ones
# hanging off "parent".  A range that does not hold the position, or does
# not hold the one before it, drops out.
def Nest(lines: list<string>, spots: list<list<number>>, lnum: number,
    col: number, encoding: string): dict<any>
  var kept: list<list<number>> = []
  for s in spots
    if !Ahead(s[0], s[1], lnum, col) || !Ahead(lnum, col, s[2], s[3])
      continue
    endif
    if !kept->empty()
      var inner = kept[-1]
      if !Ahead(s[0], s[1], inner[0], inner[1])
          || !Ahead(inner[2], inner[3], s[2], s[3])
          || (s[0] == inner[0] && s[1] == inner[1]
            && s[2] == inner[2] && s[3] == inner[3])
        continue
      endif
    endif
    add(kept, s)
  endfor
  var chain: dict<any> = {}
  for s in reverse(kept)
    var item: dict<any> = {range: util.Range(lines, s[0], s[1], s[2], s[3],
      encoding)}
    if !chain->empty()
      item.parent = chain
    endif
    chain = item
  endfor
  return chain
enddef

# One chain for each position the client asks about.
export def Ranges(parsed: dict<any>, lines: list<string>,
    positions: list<dict<any>>, encoding: string): list<dict<any>>
  if lines->empty()
    return []
  endif
  # The scan is kept with the parse, which the caller makes anew once the
  # document changes.
  if !parsed->has_key('selection_scan')
    parsed.selection_scan = Scan(lines, parsed)
  endif
  var scan = parsed.selection_scan
  var out: list<dict<any>> = []
  for pos in positions
    var lnum = min([max([pos->get('line', 0), 0]), len(lines) - 1])
    var col = util.ColFromLsp(lines[lnum], pos->get('character', 0), encoding)
    add(out, Nest(lines, Spots(lines, scan, lnum, col), lnum, col, encoding))
  endfor
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
