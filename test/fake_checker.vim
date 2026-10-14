vim9script
# A checker for test_compile.vim: every check is answered with its path and
# its text as the one error.  A path with "hang" in it has it stop answering,
# the way the real one does when a script hangs it.

var stuck = false

def OnMessage(ch: channel, msg: any)
  stuck = stuck || msg.params.path =~ 'hang'
  if !stuck
    ch_sendexpr(ch, {id: msg.id, result: {
      errors: [{line: 0, message: join([msg.params.path] + msg.params.lines)}]}})
  endif
enddef

var conn = ch_open('stdio', {mode: 'lsp', callback: OnMessage,
  close_cb: (_) => execute('qall!')})
