vim9script

import autoload '../autoload/vim9ls/parse.vim'
import autoload '../autoload/vim9ls/names.vim'

# What names.Undefined() reports for "lines", as [line, message].  An
# autoload function is defined when "autoload" says so; a file is there for
# every prefix in it.
def Undefined(lines: list<string>, autoload: dict<number> = {}): list<list<any>>
  return names.Undefined(parse.Parse(lines), lines,
    (name: string): number => autoload->get(name, -1))
    ->mapnew((_, d) => [d.line, d.message])
enddef

def g:Test_names_legacy()
  var lines =<< trim END
    function s:Present()
    endfunction
    call s:Present()
    call s:Missing()
    call <SID>Missing()
    call Global()
    call nosuch()
    call strlen('x')
    let F = {f -> f(1)}
    " call nosuch()
    execute "call nosuch()"
    syntax match Foo /nosuch(/
    nnoremap <F2> :call <SID>Missing()<CR>
    let t =<< trim EOT
      nosuch()
    EOT
    echo v:count v:nosuch
    call foo#bar#Present()
    call foo#bar#Missing()
    call other#Unknown()
  END
  assert_equal([
    [3, 'E117: Unknown function: s:Missing'],
    [4, 'E117: Unknown function: <SID>Missing'],
    [6, 'E117: Unknown function: nosuch'],
    [12, 'E117: Unknown function: <SID>Missing'],
    [16, 'E121: Undefined variable: v:nosuch'],
    [18, 'E117: Unknown function: foo#bar#Missing'],
  ], Undefined(lines, {'foo#bar#Present': 1, 'foo#bar#Missing': 0}))

  # Where the name is.
  var diags = names.Undefined(parse.Parse(['call s:Missing()']),
    ['call s:Missing()'], (_: string): number => -1)
  assert_equal([5, 14, parse.SEVERITY_ERROR],
    [diags[0].col, diags[0].end_col, diags[0].severity])
enddef

def g:Test_names_vim9()
  var lines =<< trim END
    vim9script
    import autoload './imp.vim'
    def Defined(Cb: func)
      Cb()
      Missing()
      strlen('x')
      nosuch()
      g:Anywhere()
      imp.Func()
      for F in [Defined]
        F(1)
      endfor
      var L = (Fn) => {
        return Fn(1)
      }
      var M = (Fn) => Fn(2)
      [1]->Defined()
      [1]->Missing()
      def Inner()
      enddef
      Inner()
    enddef
    function Old()
      call Global()
      call s:Missing()
    endfunction
    echo v:nosuch
    class C
      def M()
        this.M()
        Defined()
      enddef
    endclass
    var G: func(number): number = (n) => n
    def WithType(Cb: func(string)): func
      return Cb
    enddef
  END
  assert_equal([
    [4, 'E117: Unknown function: Missing'],
    [6, 'E117: Unknown function: nosuch'],
    [17, 'E117: Unknown function: Missing'],
    [24, 'E117: Unknown function: s:Missing'],
    [26, 'E1001: Variable not found: nosuch'],
  ], Undefined(lines))
enddef

# vim: ts=2 sw=0 et
