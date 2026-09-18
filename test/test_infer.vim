vim9script

import autoload '../autoload/vim9ls/infer.vim'

# The variables and functions the expressions below use.
const CTX = {
  vars: {n: 'number', f: 'float', s: 'string', b: 'bool', l: 'list<number>',
    ls: 'list<string>', d: 'dict<number>', dd: 'dict<dict<number>>',
    bl: 'blob', t: 'tuple<number, string>'},
  funcs: {U: 'func(number): string', 'foo#Bar': 'func(): number',
    's:Local': 'func(number, string): bool'},
}

# [type, expression] pairs, the type being what the compiler gives.
const LITERALS = [
  ['number', '1'],
  ['number', '0x1F'],
  ['float', '1.5'],
  ['float', '1.5e3'],
  ['string', '"x"'],
  ['string', "'it''s'"],
  ['blob', '0z01'],
  ['bool', 'true'],
  ['special', 'null'],
  ['list<any>', 'null_list'],
  ['string', 'null_string'],
  ['string', '$HOME'],
  ['string', '@a'],
  ['bool', 'v:true'],
  ['special', 'v:none'],
  ['any', ''],
  ['any', 'unknown'],
]

const CONTAINERS = [
  ['list<number>', '[1, 2]'],
  ['list<any>', '[1, "a"]'],
  ['list<any>', '[1, 2.0]'],
  ['list<any>', '[]'],
  ['list<list<number>>', '[[1], [2]]'],
  ['list<list<any>>', '[[1], ["a"]]'],
  ['dict<number>', '{a: 1}'],
  ['dict<any>', '{a: 1, b: "x"}'],
  ['dict<any>', '{}'],
  ['dict<string>', "{'a': 'x', [s]: 'y'}"],
  ['tuple<number, string>', '(1, "a")'],
  ['tuple<number>', '(1,)'],
  ['number', '(1)'],
  ['number', '((n))'],
]

const OPERATORS = [
  ['number', '1 + 2'],
  ['float', '1 + 2.0'],
  ['float', 'f * 2'],
  ['number', '7 / 2'],
  ['number', '7 % 2'],
  ['number', '-n'],
  ['float', '-f'],
  ['bool', '!n'],
  ['string', '"a" .. 1'],
  ['string', '"a" .. "b" .. n'],
  ['bool', 'n == 1'],
  ['bool', 'n is 1'],
  ['bool', 'b && b'],
  ['bool', 'b || n'],
  ['bool', 'n > 1'],
  ['list<number>', 'l + l'],
  ['list<any>', 'l + ls'],
  ['list<any>', '[1] + [2.0]'],
  ['blob', 'bl + bl'],
  ['number', 'b ? 1 : 2'],
  ['any', 'b ? 1 : 2.0'],
  ['any', 'b ? 1 : "x"'],
  ['list<any>', 'b ? l : ls'],
  ['list<number>', 'b ? [1] : [2]'],
  ['number', 'b ? (1) : 2'],
  ['number', 'n ?? 2'],
  ['any', 'n ?? "x"'],
  ['any', 'b ?? 1'],
  ['number', '<number>s'],
  ['list<number>', '<list<number>>l'],
]

const INDEXING = [
  ['number', 'l[0]'],
  ['string', 'ls[0]'],
  ['string', 'ls[0][0]'],
  ['number', 'd.a'],
  ['number', 'd["a"]'],
  ['dict<number>', 'dd.a'],
  ['number', 'dd.a.b'],
  ['number', 'dd["a"]["b"]'],
  ['string', 's[0]'],
  ['string', 's[n]'],
  ['string', 's[1 : 2]'],
  ['list<number>', 'l[1 : 2]'],
  ['list<number>', 'l[n : ]'],
  ['list<number>', 'l[: 1]'],
  ['list<list<number>>', '[l[1 : 2], l]'],
  ['number', 'bl[0]'],
  ['blob', 'bl[0 : 1]'],
  ['any', 't[0]'],
  ['number', 'l[0] + 1'],
  ['bool', 'l[0] == 1'],
  ['number', '-l[0]'],
  ['any', 'd.a.b'],
  ['object<Shape>', 'new Shape(1, 2)'],
  ['object<Shape>', 'Shape.new()'],
  ['any', 'shape.Area()'],
]

# The functions of the script by their declared type.
const CALLS = [
  ['string', 'U(1)'],
  ['number', 'foo#Bar()'],
  ['bool', 's:Local(n, s)'],
  ['func(number): string', 'U'],
  ['any', 'Unknown(1)'],
  ['any', 'Unknown'],
  ['func(any): any', '(x) => x'],
  ['func(number): number', '(x: number) => x + 1'],
  ['func(any): string', '(x): string => "a"'],
  ['func(any, any): string', '(x, y) => x .. y'],
  ['func(): number', '() => 1'],
  ['func(list<number>, any): number', '(a: list<number>, b) => a[0]'],
]

# A builtin is asked of Vim with getinfo().
const BUILTINS = [
  ['number', 'len(l)'],
  ['number', 'U(1)->len()'],
  ['list<string>', 'sort(ls)'],
  ['list<string>', 'ls->sort()'],
  ['list<string>', 'ls->reverse()'],
  ['list<any>', 'copy(ls)'],
  ['list<number>', 'range(3)'],
  ['list<string>', 'keys(d)'],
  ['list<any>', 'items(d)[0]'],
  ['number', 'n->string()->len()'],
  ['string', 'ls->join()'],
  ['list<any>', 'l->mapnew((_, v) => "x")'],
  ['list<number>', 'filter(l, (_, v) => v > 1)'],
  ['number', 'max(l)'],
  ['number', 'str2nr(s)'],
  ['bool', 'len(s) > 1'],
  ['number', 'exists("x") ? 1 : 0'],
  ['number', '&tw'],
  ['string', '&l:shell'],
  ['number', 'v:count'],
  # A type the argument list cannot pass falls back to the plain result.
  ['number', 'len(null)'],
]

def Check(cases: list<list<string>>)
  for [expected, expr] in cases
    assert_equal(expected, infer.TypeOf(expr, CTX), expr)
  endfor
enddef

def g:Test_infer_literals()
  Check(LITERALS)
enddef

def g:Test_infer_containers()
  Check(CONTAINERS)
enddef

def g:Test_infer_operators()
  Check(OPERATORS)
enddef

def g:Test_infer_index_and_member()
  Check(INDEXING)
enddef

def g:Test_infer_calls()
  Check(CALLS)
  if exists('*getinfo')
    Check(BUILTINS)
  else
    assert_equal('any', infer.TypeOf('len(l)', CTX))
  endif
enddef

# What the compiler infers for "expr" with the variables of CTX declared: the
# expression is assigned to a variable of type "job" and the E1012 message
# names the type.  "any" when there is no error, "" when the compiler cannot
# compile the expression at all.
def CompilerType(expr: string): string
  var lines = ['vim9script']
  for [name, type] in items(CTX.vars)
    add(lines, printf('var %s: %s', name, type))
  endfor
  extend(lines, ['def U(x: number): string', '  return ""', 'enddef',
    'def Probe()', '  var Target: job = ' .. expr, 'enddef', 'defcompile'])
  writefile(lines, 'Xinfer_probe.vim')
  var msg = ''
  try
    source Xinfer_probe.vim
  catch
    msg = v:exception
  endtry
  delete('Xinfer_probe.vim')
  if msg == ''
    return 'any'
  endif
  return matchstr(msg, 'E1012: Type mismatch; expected job but got \zs.*')
enddef

# The tables above hold what the compiler gave once; this Vim may differ.
def g:Test_infer_against_compiler()
  if !exists('*getinfo')
    throw 'Skipped: getinfo() is needed for the builtins'
  endif
  var lang = v:lang
  language messages C
  for [expected, expr] in LITERALS + CONTAINERS + OPERATORS + INDEXING
      + CALLS + BUILTINS
    # The functions the probe cannot define, a name it does not define, or
    # what the compiler rejects.
    if expr =~ 'foo#Bar\|s:Local'
      continue
    endif
    var compiled = CompilerType(expr)
    if compiled == ''
      continue
    endif
    assert_equal(compiled, infer.TypeOf(expr, CTX), expr)
  endfor
  execute 'language messages' lang
enddef
