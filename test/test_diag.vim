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

# A bar after ":autocmd" separates a command when no pattern comes before
# it; after the pattern it is part of the command.
def g:Test_diag_bar_after_autocmd()
  assert_equal([], Messages(['augroup X | autocmd! | augroup END']))
  assert_equal([], Messages(['augroup X | au! | augroup END']))
  assert_equal([], Messages(['augroup X | autocmd! X BufRead | augroup END']))
  assert_equal([],
    Messages(['augroup X | autocmd! BufRead,BufNewFile | augroup END']))
  assert_equal(['Missing :augroup END'],
    Messages(['augroup X', 'autocmd BufRead * echo 1 | augroup END']))
  assert_equal(['Missing :augroup END'],
    Messages(['augroup X', 'autocmd! X BufRead * echo 1 | augroup END']))
enddef

# A quote after a backslash starts no string, the bar after it separates a
# command.  A comment after ":augroup" opens no group: '"' in a legacy
# script, '#' in a Vim9 script, where '"' is part of the name.
def g:Test_diag_augroup_name_and_comment()
  assert_equal([], Messages(['augroup no\"echo | autocmd! | augroup END']))
  assert_equal([], Messages(['augroup \|\" | autocmd! | augroup END']))
  assert_equal([], Messages(['augroup " comment']))
  assert_equal([], Messages(['vim9script', 'augroup # comment']))
  assert_equal(['Missing :augroup END'],
    Messages(['vim9script', 'augroup " comment']))
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

# What Vim reports on the same line in code it compiles is left to the
# checker; the rest the parser reports there as well.
def g:Test_diag_left_to_vim()
  assert_equal([], Messages(['vim9script', 'endif', 'else', 'endfor',
    'endtry', 'catch', 'def F()', '  endwhile', 'enddef']))
  assert_equal(['E193: :enddef not inside a function',
    'E1057: Missing :enddef'], Messages(['vim9script', 'enddef', 'def F()']))
  assert_equal(['E580: :endif without :if'], Messages(['endif']))
  assert_equal(['E580: :endif without :if'],
    Messages(['vim9script', 'function F()', '  endif', 'endfunction']))
enddef

# The checker has Vim report ":let" in a Vim9 script and in a :def; the
# parser reports it where Vim does not compile, after "vim9cmd".
def g:Test_diag_let_in_vim9()
  var diags = parse.Parse(["echo 'x'", 'vim9cmd let x = 1']).diags
  assert_equal(['E1126: Cannot use :let in Vim9 script'],
    diags->mapnew((_, d) => d.message))
  assert_equal(1, diags[0].line)
  assert_equal([], Messages(['vim9script', 'let x = 1']))
  assert_equal([], Messages(['def Foo()', '  let x = 1', 'enddef']))
  # "legacy" reads the command the legacy way.
  assert_equal([], Messages(['vim9script', 'legacy let $X = 1',
    'def Foo()', '  legacy let x = 1', 'enddef']))
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
  # "legacy" and "vim9cmd" decide which way the command is read.
  assert_equal(['E492: Not an editor command: foobar'],
    Messages(['vim9script', 'legacy foobar']))
  assert_equal([], Messages(['vim9cmd foobar']))
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
      end: {line: 1},
      enddef: 2,
    }
    var for_buf = 0
    for_buf = 1
    if for_buf == 0|for_buf = 2|endif
    command! Rexplore if 1|echo 1|else|echo 2|endif
    augroup! Gone
    def Header(a: number,
        Cb: func(any),
        b = 1): number
      return a + b
    enddef
    py3 << EOF
    if True:
    EOF
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
