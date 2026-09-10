vim9script
# Runs every Test_ function in test/test_*.vim and reports what failed.
# Started by test/run, which is what to use.

const HERE = expand('<sfile>:p:h')

set nocompatible
set noswapfile
set nomore
set belloff=all
set cmdheight=10
if exists('+shellslash')
  set shellslash
endif

# The server is this Vim started again with --stdio-channel, so that has to
# be there; a Vim without it rejects the argument.
silent system([v:progpath, '--stdio-channel', '--version'])
if !has('job') || !has('channel') || v:shell_error != 0
  writefile(['This Vim cannot run the server, so nothing was tested.',
    'It needs +job, +channel and the --stdio-channel argument; this one is '
    .. v:versionlong .. (has('job') ? '' : ' without +job')
    .. (has('channel') ? '' : ' without +channel')
    .. (v:shell_error != 0 ? ' without --stdio-channel' : '') .. '.',
    'Name another with $VIMPROG:',
    '    VIMPROG=/path/to/vim ./run'], HERE .. '/messages')
  cquit 1
endif

import './helper.vim'

var failed: list<string> = []
var skipped = 0
var ran = 0
var report: list<string> = []

def Report(line: string)
  add(report, line)
enddef

def RunOne(name: string)
  ran += 1
  v:errors = []
  v:errmsg = ''
  try
    execute 'call g:' .. name .. '()'
  catch /^Skipped: /
    # A test that this Vim cannot run says so and is not counted as failed.
    skipped += 1
    Report('skip   ' .. name .. ': ' .. v:exception[9 :])
    helper.StopServer()
    silent! :%bwipe!
    return
  catch
    add(v:errors, v:throwpoint .. ': ' .. v:exception)
  endtry
  # An error Vim reported without stopping the test, a compile check among
  # them, would otherwise be lost.
  if v:errmsg != ''
    add(v:errors, 'an error went unreported: ' .. v:errmsg)
  endif
  helper.StopServer()
  silent! :%bwipe!

  if v:errors->empty()
    Report('ok     ' .. name)
  else
    add(failed, name)
    Report('FAILED ' .. name)
    for err in v:errors
      Report('       ' .. err)
    endfor
  endif
enddef

def Main()
  for file in glob(HERE .. '/test_*.vim', false, true)->sort()
    execute 'source ' .. fnameescape(file)
    var names = getcompletion('Test_', 'function')
      ->mapnew((_, n) => n->substitute('()\=$', '', ''))
      ->sort()
    # $TEST_FILTER narrows a run down to what is being looked at.
    for name in names
      if $TEST_FILTER ==# '' || name =~ $TEST_FILTER
        RunOne(name)
      endif
    endfor
    # The next file brings its own; these would otherwise run again.
    for name in names
      execute 'delfunction g:' .. name
    endfor
  endfor

  Report(printf('%d run, %d failed', ran, len(failed))
    .. (skipped > 0 ? printf(', %d skipped', skipped) : ''))
  writefile(report, HERE .. '/messages')
  for line in report
    echomsg line
  endfor
  execute 'cquit' .. (failed->empty() ? ' 0' : ' 1')
enddef

try
  Main()
catch
  writefile(['the runner itself failed:', v:throwpoint, v:exception],
    HERE .. '/messages')
  cquit 1
endtry

# vim: ts=2 sw=0 et
