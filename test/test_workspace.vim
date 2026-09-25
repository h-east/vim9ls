vim9script

import './helper.vim'
import autoload '../autoload/vim9ls/util.vim'

const ROOT = helper.HERE .. '/Xworkspace'

# The server started with "folders" as the workspace folders; returns its
# capabilities.
def Start(folders: list<string>): dict<any>
  helper.StartServer()
  var resp = helper.Request('initialize', {processId: getpid(), rootUri: null,
    capabilities: {general: {positionEncodings: ['utf-8']}},
    workspaceFolders: folders->mapnew((_, f) => ({uri: util.PathToUri(f),
      name: fnamemodify(f, ':t')}))})
  helper.Notify('initialized', {})
  return resp.result.capabilities
enddef

# What the partial results sent for "token" hold by now, the latest for each
# script: the file name and the messages.
var reports: dict<list<string>> = {}

def Take(token: string)
  var i = 0
  while i < len(helper.notifications)
    var n = helper.notifications[i]
    if n->get('method', '') == '$/progress' && n.params.token == token
      for r in n.params.value.items
        reports[fnamemodify(util.UriToPath(r.uri), ':t')] =
          r.items->mapnew((_, d) => d.message)
      endfor
      remove(helper.notifications, i)
    else
      i += 1
    endif
  endwhile
enddef

# Waits until the report of "name" matches "pattern", then returns it.
def WaitReport(token: string, name: string, pattern: string): list<string>
  helper.WaitFor(() => {
    Take(token)
    return reports->has_key(name) && join(reports[name], "\n") =~ pattern
  }, 5000)
  return reports->get(name, ['(none)'])
enddef

def g:Test_workspace_diagnostic()
  mkdir(ROOT .. '/one', 'p')
  mkdir(ROOT .. '/two', 'p')
  writefile(['vim9script', 'export const N: number = 1'],
    ROOT .. '/one/xlib.vim')
  writefile(['vim9script', "import './xlib.vim'", 'def F(): number',
    '  return xlib.N', 'enddef'], ROOT .. '/one/user.vim')
  writefile(['vim9script', 'def G(): number', '  var left = 1',
    '  return "x"', 'enddef'], ROOT .. '/one/bad.vim')
  writefile(['vim9script', 'def H(): number', '  return "y"', 'enddef'],
    ROOT .. '/two/other.vim')
  reports = {}
  var answers: list<dict<any>> = []
  try
    assert_equal({interFileDependencies: true, workspaceDiagnostics: true},
      Start([ROOT .. '/one']).diagnosticProvider)
    var xlib_uri = util.PathToUri(ROOT .. '/one/xlib.vim')
    helper.OpenDoc(readfile(ROOT .. '/one/xlib.vim'), xlib_uri)
    var id = helper.Send('workspace/diagnostic',
      {previousResultIds: [], partialResultToken: 'tok'},
      (resp) => {
        add(answers, resp)
      })

    # What the parser finds comes first, then that with what Vim reports;
    # an open document is not reported, it has its own diagnostics.
    assert_equal(['Unused variable: left',
      'E1012: Type mismatch; expected number but got string'],
      WaitReport('tok', 'bad.vim', 'E1012'))
    assert_equal([], WaitReport('tok', 'user.vim', ''))
    assert_false(reports->has_key('xlib.vim'))
    assert_false(reports->has_key('other.vim'))
    assert_equal([], answers)

    # Saving a script has those that name it read again.
    writefile(['vim9script', 'export const N: string = "s"'],
      ROOT .. '/one/xlib.vim')
    helper.Notify('textDocument/didSave', {textDocument: {uri: xlib_uri}})
    assert_equal(['E1012: Type mismatch; expected number but got string'],
      WaitReport('tok', 'user.vim', 'E1012'))

    # A folder that is added is read.
    helper.Notify('workspace/didChangeWorkspaceFolders', {event: {
      added: [{uri: util.PathToUri(ROOT .. '/two'), name: 'two'}],
      removed: []}})
    assert_equal(['E1012: Type mismatch; expected number but got string'],
      WaitReport('tok', 'other.vim', 'E1012'))

    # Cancelled, the request is answered as such.
    helper.Notify('$/cancelRequest', {id: id})
    helper.WaitFor(() => !answers->empty())
    assert_equal(-32800, answers[0]->get('error', {})->get('code', 0))

    # Without a token the reports are the answer, once there is something
    # new: here a document that is closed and so is the workspace's again.
    answers = []
    helper.Send('workspace/diagnostic', {previousResultIds: []},
      (resp) => {
        add(answers, resp)
      })
    sleep 200m
    assert_equal([], answers)
    helper.Notify('textDocument/didClose', {textDocument: {uri: xlib_uri}})
    helper.WaitFor(() => !answers->empty(), 5000)
    assert_equal(['xlib.vim'], answers[0]->get('result', {})
      ->get('items', [])->mapnew((_, r) => fnamemodify(
        util.UriToPath(r.uri), ':t')))
  finally
    helper.StopServer()
    delete(ROOT, 'rf')
  endtry
enddef

# A folder with too many scripts has the first of them read, and the client
# is told.
def g:Test_workspace_diagnostic_limit()
  mkdir(ROOT, 'p')
  for i in range(257)
    writefile(['vim9script'], printf('%s/s%03d.vim', ROOT, i))
  endfor
  reports = {}
  try
    Start([ROOT])
    helper.Send('workspace/diagnostic',
      {previousResultIds: [], partialResultToken: 'many'}, (_) => {
      })
    # The first message is where the log is.
    helper.WaitNotification('window/logMessage')
    assert_equal('vim9ls: the workspace has 257 scripts, the first 256 are read',
      helper.WaitNotification('window/logMessage').params.message)
    helper.WaitFor(() => {
      Take('many')
      return len(reports) >= 256
    }, 10000)
    sleep 100m
    Take('many')
    assert_equal(256, len(reports))
    assert_false(reports->has_key('s256.vim'))
  finally
    helper.StopServer()
    delete(ROOT, 'rf')
  endtry
enddef
