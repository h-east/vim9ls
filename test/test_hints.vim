vim9script

import autoload '../autoload/vim9ls/parse.vim'
import autoload '../autoload/vim9ls/hints.vim'

# The type hints for "lines" as [line, col, label].
def Hints(lines: list<string>): list<list<any>>
  return hints.TypeHints(parse.Parse(lines), lines, 0, len(lines))
    ->mapnew((_, h) => [h.line, h.col, h.label])
enddef

def g:Test_hints_script_level()
  var lines =<< trim END
    vim9script
    var n = 1
    var s: string = 'x'
    var l = [n, 2]
    const D = {a: s}
    var [a, b] = [1, 2]
    var no_init: number
    var f = (x: number) => x .. s
    var m = n ? l : [3]
    var t = (1, 'a')
  END
  assert_equal([
    [1, 5, ': number'],
    [3, 5, ': list<number>'],
    [4, 7, ': dict<string>'],
    [7, 5, ': func(number): string'],
    [8, 5, ': list<number>'],
    [9, 5, ': tuple<number, string>'],
  ], Hints(lines))
enddef

def g:Test_hints_in_function()
  var lines =<< trim END
    vim9script
    var count = 0
    def Add(a: number, b: number = 1): number
      return a + b
    enddef
    def Outer(items: list<string>, F: func(string): bool)
      var first = items[0]
      var n = Add(count)
      var Fn = Add
      if n > 0
        var inner = first .. 'x'
      endif
      var again = inner
      def Nested(x: float)
        var y = x * 2
      enddef
    enddef
    function Legacy()
      let old = 1
    endfunction
  END
  assert_equal([
    [1, 9, ': number'],
    [6, 11, ': string'],
    [7, 7, ': number'],
    [8, 8, ': func(number, number): number'],
    [10, 13, ': string'],
    [14, 9, ': float'],
  ], Hints(lines))
enddef

def g:Test_hints_over_lines()
  var lines =<< trim END
    vim9script
    var d = {
      a: 1,
      b: 2,
    }  # a comment
    var s = 'x'
      .. 'y'
    var n = d.a
      ->string()
      ->len()
    var last = 1
  END
  assert_equal([
    [1, 5, ': dict<number>'],
    [5, 5, ': string'],
    [7, 5, ': number'],
    [10, 8, ': number'],
  ], Hints(lines))

  # Only the lines asked about.
  var parsed = parse.Parse(lines)
  assert_equal([5, 7], hints.TypeHints(parsed, lines, 5, 8)
    ->mapnew((_, h) => h.line))
enddef

# What the server knows about the functions the calls below name.
const PARAMS = {
  strpart: {names: ['src', 'start', 'len', 'chars'], method: 1},
  append: {names: ['lnum', 'text'], method: 2},
  get: {names: ['{arg1}', 'idx', 'default'], method: 1},
  Add: {names: ['a', 'b'], method: 1},
}

def Params(name: string): dict<any>
  return PARAMS->get(name, {})
enddef

def ParamHints(lines: list<string>, first = 0, last = 100): list<list<any>>
  return hints.ParamHints(parse.Parse(lines), lines, first, last, Params)
    ->mapnew((_, h) => [h.line, h.col, h.label])
enddef

def g:Test_hints_parameters()
  var lines =<< trim END
    vim9script
    var s = strpart('abc', 1, Add(1, 2))
    echo s->strpart(1)
    append(1, 'x')
    'x'->append(1)
    echo get(l, 0)
    echo strpart(src, start)
    Unknown(1)
    echo "strpart(1, 2)"  # strpart(1, 2)
    def Add(a: number, b: number): number
    var l = [Add(
      1,
      2)]
  END
  assert_equal([
    [1, 16, 'src:'], [1, 23, 'start:'], [1, 26, 'len:'], [1, 30, 'a:'],
    [1, 33, 'b:'],
    [2, 16, 'start:'],
    [3, 7, 'lnum:'], [3, 10, 'text:'],
    [4, 12, 'lnum:'],
    [5, 12, 'idx:'],
    [11, 2, 'a:'], [12, 2, 'b:'],
  ], ParamHints(lines))
  assert_equal([[2, 16, 'start:']], ParamHints(lines, 2, 2))
  assert_equal(hints.KIND_PARAMETER,
    hints.ParamHints(parse.Parse(lines), lines, 3, 3, Params)[0].kind)
enddef
