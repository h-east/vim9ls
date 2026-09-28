vim9script
# What the tests use to drive the server: this Vim is the client.

export const HERE = expand('<sfile>:p:h')
export const SERVER = fnamemodify(HERE, ':h') .. '/autoload/vim9ls.vim'
# The temporary directory of the servers, where they log, a file each;
# emptied for every run.
export const LOG = HERE .. '/Xlog'
delete(LOG, 'rf')
mkdir(LOG, 'p')
# Where the servers keep what they found in the workspace, instead of the
# cache of the user.
export const CACHE = HERE .. '/Xcache'
# The document the tests open; the server never reads it from disk.
export const URI = 'file:///tmp/Xvim9ls_test.vim'

var job: job
# What the server sent on its own, publishDiagnostics mostly.
export var notifications: list<dict<any>> = []
export var stderr: list<string> = []

# Waits for something to become true, checking often enough that a test does
# not spend its time asleep.
export def WaitFor(Cond: func(): bool, msecs = 2000): bool
  for _ in range(msecs / 10)
    if Cond()
      return true
    endif
    sleep 10m
  endfor
  return Cond()
enddef

export def Job(): job
  return job
enddef

# Starts the server as this Vim would as a client; the channel is in "lsp"
# mode on both ends.  "cmd" is what to start instead of this Vim, the
# launcher; it is told to use this Vim.  "tmp" is the temporary directory
# of the server.
export def StartServer(cmd: list<string> = null_list, tmp = LOG): job
  notifications = []
  stderr = []
  job = job_start(cmd == null_list
      ? [v:progpath, '--clean', '--stdio-channel', '-S', SERVER] : cmd, {
    in_mode: 'lsp',
    out_mode: 'lsp',
    err_mode: 'nl',
    out_cb: (_, msg) => add(notifications, msg),
    err_cb: (_, msg) => add(stderr, msg),
    env: {VIM9LS_LOG: '1', TMPDIR: tmp, TEMP: tmp, VIM9LS_VIM: v:progpath,
      XDG_CACHE_HOME: CACHE, LOCALAPPDATA: CACHE},
  })
  if job_status(job) != 'run'
    add(v:errors, 'the server did not start')
  endif
  return job
enddef

# Sends a request and returns the whole response, {} when none came.
export def Request(method: string, params: any = null): dict<any>
  var req: dict<any> = {method: method}
  if params != null
    req.params = params
  endif
  return ch_evalexpr(job, req, {timeout: 5000})
enddef

# Sends a request without waiting: "Answered" gets the response.  Returns
# the id of the request.
export def Send(method: string, params: any, Answered: func(dict<any>)): any
  return ch_sendexpr(job, {method: method, params: params},
    {callback: (_, resp) => Answered(resp)}).id
enddef

export def Notify(method: string, params: any = null)
  var msg: dict<any> = {method: method}
  if params != null
    msg.params = params
  endif
  ch_sendexpr(job, msg)
enddef

# What a client does first; "encodings" is what it offers to count in.
export def Initialize(encodings: list<string> = ['utf-8', 'utf-16']): dict<any>
  var resp = Request('initialize', {
    processId: getpid(),
    rootUri: null,
    capabilities: {general: {positionEncodings: encodings}},
  })
  Notify('initialized', {})
  return resp
enddef

export def OpenDoc(lines: list<string>, uri = URI, version = 1)
  Notify('textDocument/didOpen', {textDocument: {
    uri: uri, languageId: 'vim', version: version,
    text: join(lines, "\n") .. "\n",
  }})
enddef

export def ChangeDoc(lines: list<string>, uri = URI, version = 2)
  Notify('textDocument/didChange', {
    textDocument: {uri: uri, version: version},
    contentChanges: [{text: join(lines, "\n") .. "\n"}],
  })
enddef

# One incremental change: "range" is [start line, start character, end line,
# end character].
export def ChangeRange(range: list<number>, text: string, version: number,
    uri = URI)
  Notify('textDocument/didChange', {
    textDocument: {uri: uri, version: version},
    contentChanges: [{
      range: {start: {line: range[0], character: range[1]},
        end: {line: range[2], character: range[3]}},
      text: text,
    }],
  })
enddef

export def SaveDoc(uri = URI)
  Notify('textDocument/didSave', {textDocument: {uri: uri}})
enddef

export def Params(line: number, character: number, uri = URI): dict<any>
  return {textDocument: {uri: uri},
    position: {line: line, character: character}}
enddef

# The next notification "method" the server sends, taken out of the list.
export def WaitNotification(method: string): dict<any>
  for _ in range(300)
    var i = notifications->indexof((_, n) => n->get('method', '') == method)
    if i >= 0
      return remove(notifications, i)
    endif
    sleep 10m
  endfor
  add(v:errors, 'no ' .. method .. ' notification arrived; stderr: '
    .. string(stderr))
  return {}
enddef

# Ends the server the way the protocol has it, and by force when that does
# not do it.
# What the server kept on disk goes with it, unless "keep_cache" is true.
export def StopServer(keep_cache = false)
  if job == null_job
    return
  endif
  if job_status(job) == 'run'
    Request('shutdown')
    Notify('exit', null)
    WaitFor(() => job_status(job) != 'run')
    job_stop(job)
  endif
  job = null_job
  if !keep_cache
    delete(CACHE, 'rf')
  endif
enddef

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
