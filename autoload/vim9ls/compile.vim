vim9script

# vim9ls - what Vim reports when it reads the script
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# The script is read by the checker, a Vim of its own (checker.vim), started
# once and kept.  A script that hangs it or ends it goes unanswered, and the
# next check starts a new one.

import autoload './util.vim'
import autoload './parse.vim'

const CHECKER = expand('<sfile>:p:h') .. '/checker.vim'

var job: job

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

export def Stop()
  if job != null_job
    job_stop(job)
    job = null_job
  endif
enddef

# What Vim reports for "lines" as the script at "path": {line, message}
# items, or null when the checker gave no answer.
export def Check(path: string, lines: list<string>): any
  if !Running()
    Start()
    if !Running()
      return null
    endif
  endif
  var resp = ch_evalexpr(job, {method: 'check',
    params: {path: path, lines: lines}}, {timeout: 5000})
  if type(resp) != v:t_dict || !resp->has_key('result')
    util.Log('the checker did not answer for ' .. path)
    job_stop(job, 'kill')
    job = null_job
    return null
  endif
  return resp.result
enddef

# The errors as LSP Diagnostic items, each over the whole of its line.
export def Diagnostics(errors: list<dict<any>>, lines: list<string>,
    encoding: string): list<dict<any>>
  var out: list<dict<any>> = []
  for e in errors
    if e.line >= len(lines)
      continue
    endif
    add(out, {
      range: util.Range(lines, e.line, 0, e.line, strlen(lines[e.line]),
        encoding),
      severity: parse.SEVERITY_ERROR,
      source: 'vim9ls',
      message: e.message,
    })
  endfor
  return out
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
