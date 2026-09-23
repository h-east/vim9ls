vim9script

# vim9ls - what Vim reports when it reads the script
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# The script is read by the checker, a Vim of its own (checker.vim), started
# once and kept.  The server never waits for it: the answer comes back
# through a callback.  A script that hangs the checker goes unanswered, and
# the next check starts a new one.

import autoload './util.vim'
import autoload './parse.vim'
import autoload './diag.vim'

const CHECKER = expand('<sfile>:p:h') .. '/checker.vim'

var job: job
# The checks that were asked and not answered yet, by request id:
# {Done, timer, path}.
var pending: dict<dict<any>> = {}

def Running(): bool
  return job != null_job && job_status(job) == 'run'
enddef

# The checker runs the Vim the server runs in.
def Start()
  job = job_start([v:progpath, '--clean', '--stdio-channel', '-i', 'NONE',
    '-n', '-S', CHECKER], {
    in_mode: 'lsp',
    out_mode: 'lsp',
    err_mode: 'nl',
    err_cb: (_, line) => util.Log('checker: ' .. line),
  })
enddef

# Ends the checker; what it was asked is answered with null.
export def Stop()
  if job != null_job
    job_stop(job, 'kill')
    job = null_job
  endif
  var asked = pending
  pending = {}
  for p in values(asked)
    timer_stop(p.timer)
    p.Done(null)
  endfor
enddef

# Asks the checker what Vim reports for "lines" as the script at "path",
# with "wrapped" the script level as a function (see wrap.vim) or null.
# "Done" gets the {line, message} items, or null when the checker gave no
# answer.  Returns false when there is no checker to ask.
export def Check(path: string, lines: list<string>, wrapped: any,
    Done: func(any)): bool
  if !Running()
    Start()
    if !Running()
      return false
    endif
  endif
  var sent = ch_sendexpr(job, {method: 'check',
    params: {path: path, lines: lines, wrapped: wrapped}}, {callback: OnReply})
  if type(sent) != v:t_dict || !sent->has_key('id')
    return false
  endif
  pending[string(sent.id)] = {Done: Done, path: path,
    timer: timer_start(5000, (_) => Unanswered(sent.id))}
  return true
enddef

def OnReply(ch: channel, resp: dict<any>)
  var id = string(resp->get('id', -1))
  if !pending->has_key(id)
    return
  endif
  var p = remove(pending, id)
  timer_stop(p.timer)
  var result = resp->get('result', null_dict)
  p.Done(result == null_dict ? null : result.errors)
enddef

def Unanswered(nr: number)
  var id = string(nr)
  if pending->has_key(id)
    util.Log('the checker did not answer for ' .. pending[id].path)
    Stop()
  endif
enddef

# The errors as LSP Diagnostic items, each over the whole of its line.
export def Diagnostics(errors: list<dict<any>>, lines: list<string>,
    encoding: string): list<dict<any>>
  var out: list<dict<any>> = []
  for e in errors
    if e.line >= len(lines)
      continue
    endif
    var item: dict<any> = {
      range: util.Range(lines, e.line, 0, e.line, strlen(lines[e.line]),
        encoding),
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
