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

# In the keys of a mapping, an abbreviation or a menu only a name that can
# only be a call is looked at: one with <SID> or "#", or one after "call".
def g:Test_names_keys()
  var lines =<< trim END
    nnoremap <buffer> <Plug>LUncomOn gI(* <End> *)<ESC>
    iabbrev <buffer> set() x
    inoremap <expr> <F2> nosuch()
    nnoremap <F3> :call nosuch()<CR>
    nnoremap <F4> :call foo#bar#Missing()<CR>
    anoremenu Foo.Bar :call <SID>Missing()<CR>
  END
  assert_equal([
    [3, 'E117: Unknown function: nosuch'],
    [4, 'E117: Unknown function: foo#bar#Missing'],
    [5, 'E117: Unknown function: <SID>Missing'],
  ], Undefined(lines, {'foo#bar#Missing': 0}))
enddef

# A mapping in a heredoc is text; its keys have no call to look up.
def g:Test_names_key_calls_in_heredoc()
  var lines =<< trim END
    vim9script
    var text =<< trim EOT
      nnoremap <F2> :call <SID>Missing()<CR>
    EOT
    nnoremap <F3> :call <SID>Present()<CR>
  END
  assert_equal([[4, '<SID>Present']], names.KeyCalls(parse.Parse(lines), lines)
    ->mapnew((_, c) => [c.line, c.name]))
enddef

# The arguments of a user command and of the commands whose arguments are
# not code are left alone, their continuation lines with them.
def g:Test_names_skipped_commands()
  var lines =<< trim END
    CompilerSet errorformat+=%f(%l\\,%v):\ %m,
          \%g(%l):\ %m
    set errorformat+=%f(%l)
          \,%h(%l)
    menutrans Co&pying	v(&P)
    silent Cmd nosuch()
    call nosuch()
          \ + other()
  END
  assert_equal([
    [6, 'E117: Unknown function: nosuch'],
    [7, 'E117: Unknown function: other'],
  ], Undefined(lines))
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
      static def S(): number
        return 1
      enddef
      def M()
        this.M()
        Defined()
        S()
        M()
        Other()
      enddef
    endclass
    var G: func(number): number = (n) => n
    def WithType(Cb: func(string)): func
      return Cb
    enddef
    def Last()
      foo#bar#Present()
      foo#bar#Missing()
    enddef
  END
  # Under Vim9 rules Vim reports what is not defined when it compiles the
  # code; left here are an autoload function, which it looks up only when
  # called, and the body of a legacy function.
  assert_equal([
    [24, 'E117: Unknown function: s:Missing'],
    [45, 'E117: Unknown function: foo#bar#Missing'],
  ], Undefined(lines, {'foo#bar#Present': 1, 'foo#bar#Missing': 0}))
enddef

# vim: ts=2 sw=0 et
