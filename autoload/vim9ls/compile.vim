vim9script

# vim9ls - what Vim reports when it reads the script
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# The script is read by the checker, a Vim of its own (checker.vim), started
# once and kept.  The server never waits for it: the answer comes back
# through a callback.  The checker is handed one script at a time and the
# others wait here, so that the time a check is given starts when the
# checker takes it.  A script that hangs the checker goes unanswered, and a
# new checker takes the ones that wait.

import autoload './util.vim'
import autoload './parse.vim'
import autoload './diag.vim'

# What the checker runs, and how long it is given for a check; the tests
# change them.
export var checker_script = expand('<sfile>:p:h') .. '/checker.vim'
export var check_msecs = 5000

var job: job
# The check the checker has, {id, Done, timer, path}, or null_dict.
var current: dict<any> = null_dict
# The paths of the checks that wait for it, oldest first, and the checks by
# path, {path, lines, wrapped, Done}.
var waiting: list<string> = []
var waiting_checks: dict<dict<any>> = {}
# The same for the checks made in the background, which wait until nothing
# else does.
var background: list<string> = []
var background_checks: dict<dict<any>> = {}
# Whether a file may have changed since the last check was sent: the next
# one has the checker read again the scripts it has that changed.
var changed = false

export def FilesChanged()
  changed = true
enddef

def Running(): bool
  return job != null_job && job_status(job) == 'run'
enddef

# The checker runs the Vim the server runs in.
def Start()
  job = job_start([v:progpath, '--clean', '--stdio-channel', '-i', 'NONE',
    '-n', '-S', checker_script], {
    in_mode: 'lsp',
    out_mode: 'lsp',
    err_mode: 'nl',
    err_cb: (_, line) => util.Log('checker: ' .. line),
  })
enddef

# Ends the checker; the check it has is answered with null.
def Kill()
  if job != null_job
    job_stop(job, 'kill')
    job = null_job
  endif
  if current != null_dict
    var p = current
    current = null_dict
    timer_stop(p.timer)
    p.Done(null)
  endif
enddef

# Ends the checker; what it was asked, and what waits, is answered with null.
export def Stop()
  Kill()
  var asked = waiting->mapnew((_, p) => waiting_checks[p])
    + background->mapnew((_, p) => background_checks[p])
  waiting = []
  waiting_checks = {}
  background = []
  background_checks = {}
  for w in asked
    w.Done(null)
  endfor
enddef

# Hands the checker the oldest check that waits, when it has none.
def Next()
  while current == null_dict && !(waiting->empty() && background->empty())
    if !Running()
      Start()
      if !Running()
        Stop()
        return
      endif
    endif
    var w = waiting->empty()
      ? remove(background_checks, remove(background, 0))
      : remove(waiting_checks, remove(waiting, 0))
    var sent = ch_sendexpr(job, {method: 'check',
      params: {path: w.path, lines: w.lines, wrapped: w.wrapped,
        refresh: changed, calls: w.calls}},
      {callback: OnReply})
    if type(sent) != v:t_dict || !sent->has_key('id')
      w.Done(null)
      continue
    endif
    changed = false
    current = {id: sent.id, Done: w.Done, path: w.path,
      timer: timer_start(check_msecs, (_) => Unanswered(sent.id))}
  endwhile
enddef

# Asks the checker what Vim reports for "lines" as the script at "path",
# with "wrapped" the script level as a function (see wrap.vim) or null.
# "Done" gets the {line, message} items, with "col" and "end_col" for one
# that is not about the whole line, or null when the checker gave no answer.
# A check of the same script that still waits gives way to this one.  A
# check made "in_background" waits until no other one does.  "calls" are the
# calls in keys to look up, see names.KeyCalls().  Returns false when there
# is no checker to ask.
export def Check(path: string, lines: list<string>, wrapped: any,
    Done: func(any), in_background = false,
    calls: list<dict<any>> = []): bool
  if !Running()
    Start()
    if !Running()
      return false
    endif
  endif
  var check = {path: path, lines: lines, wrapped: wrapped, Done: Done,
    calls: calls}
  if in_background
    if !background_checks->has_key(path)
      add(background, path)
    endif
    background_checks[path] = check
  else
    if !waiting_checks->has_key(path)
      add(waiting, path)
    endif
    waiting_checks[path] = check
  endif
  Next()
  return true
enddef

def OnReply(_: channel, resp: dict<any>)
  if current == null_dict || resp->get('id', -1) != current.id
    return
  endif
  var p = current
  current = null_dict
  timer_stop(p.timer)
  if resp->has_key('error')
    util.Log($'the checker failed for {p.path}: {resp.error.message}')
  endif
  var result = resp->get('result', null_dict)
  p.Done(result == null_dict ? null : result.errors)
  Next()
enddef

def Unanswered(id: number)
  if current != null_dict && current.id == id
    util.Log('the checker did not answer for ' .. current.path)
    Kill()
    Next()
  endif
enddef

# The errors as LSP Diagnostic items, each over the whole of its line or the
# columns it names.
export def Diagnostics(errors: list<dict<any>>, lines: list<string>,
    encoding: string): list<dict<any>>
  var out: list<dict<any>> = []
  for e in errors
    if e.line >= len(lines)
      continue
    endif
    var item: dict<any> = {
      range: util.Range(lines, e.line, e->get('col', 0), e.line,
        e->get('end_col', strlen(lines[e.line])), encoding),
      severity: parse.SEVERITY_ERROR,
      source: 'vim9ls',
      message: e.message,
    }
    var data = diag.FixData(e.message, lines[e.line], -1)
    if data != null_dict
      item.data = data
    endif
    add(out, item)
  endfor
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
