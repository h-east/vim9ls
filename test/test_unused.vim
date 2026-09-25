vim9script

import autoload '../autoload/vim9ls/parse.vim'
import autoload '../autoload/vim9ls/unused.vim'
import autoload '../autoload/vim9ls/diag.vim'

# What unused.Unused() reports for "lines", as [line, message].
def Unused(lines: list<string>): list<list<any>>
  return unused.Unused(parse.Parse(lines), lines)
    ->mapnew((_, d) => [d.line, d.message])
enddef

def g:Test_unused_variables()
  var lines =<< trim END
    vim9script
    var script_level = 1
    def F()
      var used = 1
      echo used
      var assigned = 1
      assigned = 2
      var unused = 1
      const also_unused = 2
      var [a, b] = [1, 2]
      echo a
      var _ = 3
      for i in range(3)
      endfor
      for [k, _] in items({})
      endfor
      var F2 = () => used
      var captured = 1
      var Lambda = () => captured
      Lambda()
      var nested_use = 1
      def Inner()
        echo nested_use
      enddef
      Inner()
      var dot = 1
      echo g:obj.dot
      var in_string = 1
      echo 'in_string'
    enddef
  END
  assert_equal([
    [7, 'Unused variable: unused'],
    [8, 'Unused variable: also_unused'],
    [9, 'Unused variable: b'],
    [12, 'Unused variable: i'],
    [14, 'Unused variable: k'],
    [16, 'Unused variable: F2'],
    [25, 'Unused variable: dot'],
    [27, 'Unused variable: in_string'],
  ], Unused(lines))

  # Where it is and what it is, also as an LSP Diagnostic.
  var diags = unused.Unused(parse.Parse(lines), lines)
  assert_equal([7, 6, 12, parse.SEVERITY_HINT, [parse.TAG_UNNECESSARY]],
    [diags[0].line, diags[0].col, diags[0].end_col, diags[0].severity,
      diags[0].tags])
  var item = diag.Diagnostics(diags, lines, 'utf-8')[0]
  assert_equal([parse.SEVERITY_HINT, [parse.TAG_UNNECESSARY]],
    [item.severity, item.tags])

  # A variable ":legacy" declares is not one of the function.
  assert_equal([], Unused(['vim9script', 'def F()', '  legacy let x = 1',
    'enddef']))
enddef

def g:Test_unused_parameters()
  var lines =<< trim END
    vim9script
    def F(used: number, unused: string, _: number, _: number)
      echo used
    enddef
    def G(Cb: func(number, string): bool, t: tuple<number, string>,
        d: string = 'a, b', e: list<number> = [1, 2], f = 1 > 0)
      Cb(1, 'x')
    enddef
    interface I
      def Method(x: number)
    endinterface
    abstract class A
      abstract def Method(x: number)
    endclass
    class C
      var x: number
      def new(this.x)
      enddef
      def Other(y: number)
      enddef
    endclass
    function Legacy(z)
    endfunction
  END
  assert_equal([
    [1, 'Unused parameter: unused'],
    [4, 'Unused parameter: t'],
    [5, 'Unused parameter: d'],
    [5, 'Unused parameter: e'],
    [5, 'Unused parameter: f'],
    [18, 'Unused parameter: y'],
  ], Unused(lines))
enddef

def g:Test_unused_block_scope()
  var lines =<< trim END
    vim9script
    def F(flag: bool)
      if flag
        var x = 1
        echo x
      else
        var x = 2
      endif
    enddef
  END
  assert_equal([[6, 'Unused variable: x']], Unused(lines))
enddef

def g:Test_unused_interpolation()
  var lines =<< trim END
    vim9script
    def F()
      var a = 1
      var b = 2
      var c = 3
      var d = 4
      var e = 5
      echo $"a is {a}"
      echo $'b is {b + 1}'
      echo $"not {{c}}"
      var text =<< trim eval EOT
        d is {d}
      EOT
      var plain =<< trim EOT
        e is {e}
      EOT
      echo text plain
      var dir = '/tmp'
      echo $'{substitute(dir, '[/\\]$', '', '')}/log'
      var quoted = 1
      echo $"say \"{quoted}\""
      var later = 1
      echo $'it''s {"}"}' later
      var assigned = 1
      text =<< trim eval EOT
        var in_text = {assigned}
      EOT
    enddef
  END
  assert_equal([
    [4, 'Unused variable: c'],
    [6, 'Unused variable: e'],
  ], Unused(lines))
enddef
