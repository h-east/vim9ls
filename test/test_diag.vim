vim9script

import autoload '../autoload/vim9ls/parse.vim'

def Messages(lines: list<string>): list<string>
  return parse.Parse(lines).diags->mapnew((_, d) => d.message)
enddef

def g:Test_diag_missing_end()
  var diags = parse.Parse(['if 1', "echo 'x'"]).diags
  assert_equal(1, len(diags))
  assert_equal('E171: Missing :endif', diags[0].message)
  assert_equal(0, diags[0].line)
  assert_equal(0, diags[0].col)
  assert_equal(parse.SEVERITY_ERROR, diags[0].severity)

  assert_equal(['E1057: Missing :enddef'], Messages(['def Foo()', 'echo 1']))
  assert_equal(['E126: Missing :endfunction'], Messages(['function Foo()']))
  assert_equal(['E170: Missing :endwhile'], Messages(['while 1']))
  assert_equal(['E170: Missing :endfor'], Messages(['for x in []']))
  assert_equal(['E600: Missing :endtry'], Messages(['try']))
  assert_equal(['Missing :endclass'], Messages(['vim9script', 'class A']))
  assert_equal(['Missing :augroup END'], Messages(['augroup X']))
enddef

def g:Test_diag_end_without_start()
  var diags = parse.Parse(["echo 'x'", '  endif']).diags
  assert_equal(1, len(diags))
  assert_equal('E580: :endif without :if', diags[0].message)
  assert_equal(1, diags[0].line)
  assert_equal(2, diags[0].col)
  assert_equal(7, diags[0].end_col)

  assert_equal(['E193: :enddef not inside a function'], Messages(['enddef']))
  assert_equal(['E588: :endwhile without :while'], Messages(['endwhile']))
  assert_equal(['E602: :endtry without :try'], Messages(['endtry']))
  assert_equal(['E581: :else without :if'], Messages(['else']))
  assert_equal(['E603: :catch without :try'], Messages(['catch']))
  # A mismatch is reported once, for the end that does not fit.
  assert_equal(['E588: :endwhile without :while', 'E171: Missing :endif'],
    Messages(['if 1', 'endwhile']))
enddef

def g:Test_diag_let_in_vim9()
  var diags = parse.Parse(['vim9script', 'let x = 1']).diags
  assert_equal(['E1126: Cannot use :let in Vim9 script'],
    diags->mapnew((_, d) => d.message))
  assert_equal(1, diags[0].line)
  # Inside a :def in a legacy script as well.
  assert_equal(['E1126: Cannot use :let in Vim9 script'],
    Messages(['def Foo()', '  let x = 1', 'enddef']))
  # A legacy function in a Vim9 script is legacy.
  assert_equal([], Messages(['vim9script', 'function Foo()', '  let x = 1',
    'endfunction']))
enddef

def g:Test_diag_unknown_command()
  var diags = parse.Parse(["echo 'x'", 'foobar 1']).diags
  assert_equal(['E492: Not an editor command: foobar'],
    diags->mapnew((_, d) => d.message))
  assert_equal(parse.SEVERITY_WARNING, diags[0].severity)
  assert_equal(1, diags[0].line)
  # After a modifier, and abbreviated commands are fine.
  assert_equal(['E492: Not an editor command: foobar'],
    Messages(['silent! foobar']))
  assert_equal([], Messages(['sil! ec 1', 'norm! dd', 'exe "q"']))
enddef

# What looks like a command but is not one must not be reported.
def g:Test_diag_no_false_positives()
  var lines =<< trim END
    vim9script
    var x = 1
    x = 2
    x += 1
    x ..= 'a'
    x->Filter()
    Func(x)
    foo#bar#Func()
    s:legacy = 1
    &textwidth = 80
    $ENV = 'x'
    @a = 'x'
    var d = {
      name: 'x',
      other: 2,
    }
    var t =<< trim EOT
      garbage here
      more garbage
    EOT
    var list = [
      1,
      2]
    Call(
      arg)
    :%s/a/b/
    'a,'bdelete
    /pat/d
    if x | echo 1 | endif
    MyCommand arg
  END
  assert_equal([], Messages(lines))
enddef

# vim: ts=2 sw=0 et
