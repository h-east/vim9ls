vim9script

import './helper.vim'
import autoload '../autoload/vim9ls/util.vim'

const ROOT = helper.HERE .. '/Xworkspace'

# The server started with "folders" as the workspace folders, by a client
# that takes a registration for the files to watch when "watch" is true and
# gives "options" as the initialization options; returns its capabilities.
def Start(folders: list<string>, watch = false,
    options: any = null): dict<any>
  helper.StartServer()
  var resp = helper.Request('initialize', {processId: getpid(), rootUri: null,
    capabilities: {general: {positionEncodings: ['utf-8']},
      workspace: {didChangeWatchedFiles: {dynamicRegistration: watch}}},
    initializationOptions: options,
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

# A folder with more scripts than "workspace.maxFiles" of the initialization
# options has the first of them read, and the client is told.  A value that
# is not a positive number is told about, and the default is used.
def g:Test_workspace_diagnostic_limit()
  mkdir(ROOT, 'p')
  for i in range(4)
    writefile(['vim9script'], printf('%s/s%d.vim', ROOT, i))
  endfor
  reports = {}
  try
    Start([ROOT], false, {workspace: {maxFiles: 3}})
    helper.Send('workspace/diagnostic',
      {previousResultIds: [], partialResultToken: 'many'}, (_) => {
      })
    # The first message is where the log is.
    helper.WaitNotification('window/logMessage')
    assert_equal('vim9ls: the workspace has 4 scripts, the first 3 are read',
      helper.WaitNotification('window/logMessage').params.message)
    helper.WaitFor(() => {
      Take('many')
      return len(reports) >= 3
    })
    sleep 100m
    Take('many')
    assert_equal(['s0.vim', 's1.vim', 's2.vim'], keys(reports)->sort())
    helper.StopServer()

    for bad in [0, 'many']
      reports = {}
      Start([ROOT], false, {workspace: {maxFiles: bad}})
      helper.WaitNotification('window/logMessage')
      assert_equal('vim9ls: workspace.maxFiles is not a positive number, '
        .. '4096 is used',
        helper.WaitNotification('window/logMessage').params.message)
      helper.Send('workspace/diagnostic',
        {previousResultIds: [], partialResultToken: 'all'}, (_) => {
        })
      helper.WaitFor(() => {
        Take('all')
        return len(reports) >= 4
      })
      assert_equal(4, len(reports))
      helper.StopServer()
    endfor
  finally
    helper.StopServer()
    delete(ROOT, 'rf')
  endtry
enddef

# With a token for the work done, the first reading goes out as begin, a
# report for every tenth and end, which comes once what the checker reports
# is in.
def g:Test_workspace_diagnostic_progress()
  mkdir(ROOT, 'p')
  for i in range(12)
    writefile(['vim9script'], printf('%s/s%02d.vim', ROOT, i))
  endfor
  writefile(['vim9script', 'def G(): number', '  return "x"', 'enddef'],
    ROOT .. '/zbad.vim')
  reports = {}
  try
    Start([ROOT])
    helper.Send('workspace/diagnostic', {previousResultIds: [],
      partialResultToken: 'tok', workDoneToken: 'work'}, (_) => {
      })
    # The notifications in the order they came, up to the end.
    var values: list<dict<any>> = []
    helper.WaitFor(() => {
      while !helper.notifications->empty()
          && (values->empty() || values[-1].kind != 'end')
        var n = remove(helper.notifications, 0)
        if n->get('method', '') != '$/progress'
          continue
        elseif n.params.token == 'work'
          add(values, n.params.value)
        else
          for r in n.params.value.items
            reports[fnamemodify(util.UriToPath(r.uri), ':t')] =
              r.items->mapnew((_, d) => d.message)
          endfor
        endif
      endwhile
      return !values->empty() && values[-1].kind == 'end'
    }, 10000)
    assert_equal({kind: 'begin', title: 'Reading the workspace',
      percentage: 0}, values[0])
    assert_equal({kind: 'end'}, values[-1])
    var percentages = values[1 : -2]->mapnew((_, v) => v.percentage)
    assert_equal(['report'], values[1 : -2]->mapnew((_, v) => v.kind)
      ->sort()->uniq())
    assert_equal(sort(copy(percentages), 'n'), percentages)
    assert_true(len(percentages) >= 5 && percentages[-1] < 100,
      string(percentages))
    assert_equal(['E1012: Type mismatch; expected number but got string'],
      reports->get('zbad.vim', []))
    assert_equal(13, len(reports))
  finally
    helper.StopServer()
    delete(ROOT, 'rf')
  endtry
enddef

# Whether the request with a token for the work done has the server read a
# script: only then does it tell of the work beginning.
def ReadsAny(): bool
  helper.Send('workspace/diagnostic', {previousResultIds: [],
    partialResultToken: 'tok', workDoneToken: 'work'}, (_) => {
    })
  sleep 300m
  return helper.notifications->indexof((_, n) =>
    n->get('method', '') == '$/progress' && n.params.token == 'work') >= 0
enddef

# What a server found is kept on disk; a server started again reports it
# without reading the scripts that did not change since.
def g:Test_workspace_diagnostic_cache()
  mkdir(ROOT, 'p')
  writefile(['vim9script'], ROOT .. '/good.vim')
  writefile(['vim9script', 'def G(): number', '  return "x"', 'enddef'],
    ROOT .. '/bad.vim')
  const E1012 = 'E1012: Type mismatch; expected number but got string'
  try
    reports = {}
    Start([ROOT])
    assert_true(ReadsAny())
    assert_equal([E1012], WaitReport('tok', 'bad.vim', 'E1012'))
    helper.StopServer(true)
    assert_equal(1, len(glob(helper.CACHE .. '/vim9ls/*.json', true, true)))

    reports = {}
    Start([ROOT])
    assert_false(ReadsAny(), 'nothing should be read')
    assert_equal([E1012], WaitReport('tok', 'bad.vim', 'E1012'))
    assert_equal([], WaitReport('tok', 'good.vim', ''))
    helper.StopServer(true)

    # A script that changed is read again.
    writefile(['vim9script', 'def F(): number', '  return "y"', 'enddef'],
      ROOT .. '/good.vim')
    reports = {}
    Start([ROOT])
    assert_true(ReadsAny())
    assert_equal([E1012], WaitReport('tok', 'good.vim', 'E1012'))
    helper.StopServer(true)

    # Saved by another version of the server, all is read again.
    var file = glob(helper.CACHE .. '/vim9ls/*.json', true, true)[0]
    var data = json_decode(readfile(file)->join("\n"))
    data.key.vim9ls = 'other'
    writefile([json_encode(data)], file)
    reports = {}
    Start([ROOT])
    assert_true(ReadsAny())
    assert_equal([E1012], WaitReport('tok', 'bad.vim', 'E1012'))
  finally
    helper.StopServer()
    delete(ROOT, 'rf')
  endtry
enddef

# The command that has the workspace read again: every script is read and
# reported again, the work goes out under the token of the command, which
# is answered at its end.
def g:Test_workspace_reload()
  mkdir(ROOT, 'p')
  writefile(['vim9script', 'def G(): number', '  return "x"', 'enddef'],
    ROOT .. '/bad.vim')
  reports = {}
  try
    assert_equal({commands: ['vim9ls.reloadWorkspace']},
      Start([ROOT]).executeCommandProvider)
    helper.Send('workspace/diagnostic', {previousResultIds: [],
      partialResultToken: 'tok'}, (_) => {
      })
    assert_match('E1012', join(WaitReport('tok', 'bad.vim', 'E1012')))

    reports = {}
    var answers: list<dict<any>> = []
    helper.Send('workspace/executeCommand', {command: 'vim9ls.reloadWorkspace',
      workDoneToken: 'again'}, (resp) => {
        add(answers, resp)
      })
    assert_match('E1012', join(WaitReport('tok', 'bad.vim', 'E1012')))
    helper.WaitFor(() => !answers->empty(), 5000)
    assert_equal(v:null, answers[0]->get('result', 0))
    var kinds = helper.notifications->copy()->filter((_, n) =>
      n->get('method', '') == '$/progress' && n.params.token == 'again')
      ->mapnew((_, n) => n.params.value.kind)
    assert_equal('begin', kinds[0])
    assert_equal('end', kinds[-1])

    answers = []
    helper.Send('workspace/executeCommand', {command: 'vim9ls.nothing'},
      (resp) => {
        add(answers, resp)
      })
    helper.WaitFor(() => !answers->empty())
    assert_equal(-32602, answers[0]->get('error', {})->get('code', 0))
  finally
    helper.StopServer()
    delete(ROOT, 'rf')
  endtry
enddef

# A client that takes it is asked to watch the "*.vim" files; what it reports
# changed is read again, and what it reports gone has its report emptied.
def g:Test_workspace_watched_files()
  mkdir(ROOT, 'p')
  writefile(['vim9script'], ROOT .. '/a.vim')
  writefile(['vim9script', 'def G(): number', '  return "x"', 'enddef'],
    ROOT .. '/b.vim')
  reports = {}
  try
    Start([ROOT], true)
    var registered: list<any> = []
    helper.WaitFor(() => {
      var i = helper.notifications->indexof((_, n) =>
        n->get('method', '') == 'client/registerCapability')
      if i >= 0
        registered = helper.notifications[i].params.registrations
      endif
      return i >= 0
    })
    assert_equal([{id: 'vim9ls-watched-files',
      method: 'workspace/didChangeWatchedFiles',
      registerOptions: {watchers: [{globPattern: '**/*.vim'}]}}], registered)

    helper.Send('workspace/diagnostic', {previousResultIds: [],
      partialResultToken: 'tok'}, (_) => {
      })
    assert_equal([], WaitReport('tok', 'a.vim', ''))
    assert_match('E1012', join(WaitReport('tok', 'b.vim', 'E1012')))

    writefile(['vim9script', 'def F(): number', '  return "y"', 'enddef'],
      ROOT .. '/a.vim')
    delete(ROOT .. '/b.vim')
    helper.Notify('workspace/didChangeWatchedFiles', {changes: [
      {uri: util.PathToUri(ROOT .. '/a.vim'), type: 2},
      {uri: util.PathToUri(ROOT .. '/b.vim'), type: 3}]})
    assert_match('E1012', join(WaitReport('tok', 'a.vim', 'E1012')))
    assert_equal([], WaitReport('tok', 'b.vim', '^$'))
    helper.StopServer()

    # A client that does not take it is not asked.
    Start([ROOT])
    sleep 300m
    assert_equal(-1, helper.notifications->indexof((_, n) =>
      n->get('method', '') == 'client/registerCapability'))
  finally
    helper.StopServer()
    delete(ROOT, 'rf')
  endtry
enddef
