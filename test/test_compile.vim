vim9script

import './helper.vim'
import autoload '../autoload/vim9ls/compile.vim'

# What each check was answered with, in the order the answers came: the path
# and text the fake checker put in the error, or "null" and the path.
var answers: list<string> = []

def Ask(path: string, lines: list<string> = [])
  compile.Check(path, lines, null, (errors: any) => {
    add(answers, errors == null ? 'null ' .. path : errors[0].message)
  })
enddef

def Setup(msecs: number)
  answers = []
  compile.checker_script = helper.HERE .. '/fake_checker.vim'
  compile.check_msecs = msecs
enddef

def Teardown()
  compile.Stop()
  compile.checker_script = fnamemodify(helper.SERVER, ':h')
    .. '/vim9ls/checker.vim'
  compile.check_msecs = 5000
enddef

# The checks are handed over one at a time, in the order asked; a check of a
# script that still waits gives way to a newer one of the same script, in
# its place.
def g:Test_compile_queue()
  Setup(5000)
  try
    Ask('/x/one.vim')
    Ask('/x/two.vim', ['old'])
    Ask('/x/three.vim')
    Ask('/x/two.vim', ['new'])
    helper.WaitFor(() => len(answers) >= 3)
    sleep 100m
    assert_equal(['/x/one.vim', '/x/two.vim new', '/x/three.vim'], answers)
  finally
    Teardown()
  endtry
enddef

# A check that gets no answer in time is answered with null and the checker
# is started again; the checks that waited behind it are answered, since
# their time starts when the checker takes them.
def g:Test_compile_unanswered()
  Setup(300)
  try
    Ask('/x/hang.vim')
    Ask('/x/after.vim')
    helper.WaitFor(() => len(answers) >= 2, 3000)
    assert_equal(['null /x/hang.vim', '/x/after.vim'], answers)
  finally
    Teardown()
  endtry
enddef

# Stopping answers what the checker has and what waits with null.
def g:Test_compile_stop()
  Setup(5000)
  try
    Ask('/x/hang.vim')
    Ask('/x/waits.vim')
    compile.Stop()
    assert_equal(['null /x/hang.vim', 'null /x/waits.vim'], answers)
  finally
    Teardown()
  endtry
enddef
