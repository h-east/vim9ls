vim9script

# vim9ls - the checker: a Vim of its own that reads a script with
# ":source ++dryrun" and reports what does not compile
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
#
# compile.vim starts this with --stdio-channel and sends it the text of a
# script.  Nothing in the script runs: the dry run defines what the script
# defines and compiles its functions.  What Vim reports comes back with the
# line it is about.  The work is done in legacy functions: an error must not
# stop it, and in a :def or under :try it would.

var conn: channel

# Whether this Vim has ":source ++dryrun".
var dryrun = false

const SELF = expand('<sfile>:p')

# The buffer for "path" with "lines" as its text.  The same buffer serves
# the same path again, so that Vim sees one script sourced once more and
# lets it redefine its functions.
function Load(path, lines)
  if bufexists(a:path)
    execute 'silent! keepalt buffer!' bufnr(a:path)
  else
    execute 'silent! keepalt edit!' fnameescape(a:path)
  endif
  silent! %delete _
  call setline(1, a:lines)
endfunction

# Vim names the source of an error only when it differs from the last one;
# an error of our own, thrown away, makes sure the next one is named.
function Reset()
  redir => discard
  eval NoSuchFunctionVim9ls()
  redir END
endfunction

# Reads the buffer with "cmd" and returns what Vim reported.
function Source(cmd)
  call s:Reset()
  redir => messages
  execute a:cmd
  redir END
  return messages
endfunction

# The line a function starts on in "path", 1-based, or 0 when it is not in
# that file or not found.  A lambda is gone once its compilation failed.
# Vim names the file with "~" for the home directory.
function StartLine(name, path)
  try
    let m = matchlist(execute('verbose function ' .. a:name),
      \ 'Last set from \(.*\) line \(\d\+\)')
  catch
    return 0
  endtry
  return empty(m) || fnamemodify(m[1], ':p') !=# a:path ? 0 : str2nr(m[2])
endfunction

# The 0-based line of an error, from the context Vim named for it and the
# line within that context.  The context is a chain like
#   script /path/file.vim[11]..function <SNR>6_Outer[1]..<lambda>3
# read from the end: a lambda adds the line it started on in the function
# around it, until a function that can be found or the script itself.
function Where(context, lnum, path)
  let offset = a:lnum
  let elements = split(a:context, '\.\.')
  for i in range(len(elements) - 1, 0, -1)
    let m = matchlist(elements[i],
      \ '^\%(function \|script \)\=\(.\{-}\)\%(\[\(\d\+\)\]\)\=$')
    if empty(m)
      return -1
    endif
    let [name, at] = [m[1], str2nr(m[2])]
    if fnamemodify(name, ':p') ==# a:path
      return at + offset - 1
    endif
    if name !~ '^<lambda>'
      let start = s:StartLine(name, a:path)
      if start > 0
        return start + at + offset - 1
      endif
    endif
    let offset += at
  endfor
  return -1
endfunction

# The errors in what Vim reported, as {line, message}, in the order of the
# lines.
function Errors(messages, path)
  let errors = []
  let context = ''
  let lnum = 0
  for line in split(a:messages, "\n")
    let m = matchlist(line,
      \ '^Error detected while \%(compiling\|processing\) \(.*\):$')
    if !empty(m)
      let [context, lnum] = [m[1], 0]
      continue
    endif
    let m = matchlist(line, '^line\s\+\(\d\+\):$')
    if !empty(m)
      let lnum = str2nr(m[1])
      continue
    endif
    if line !~ '^E\d\+:'
      continue
    endif
    let at = s:Where(context, lnum, a:path)
    let error = {'line': at, 'message': line}
    if at >= 0 && index(errors, error) < 0
      call add(errors, error)
    endif
  endfor
  return sort(errors, {a, b -> a.line - b.line})
endfunction

# What Vim reports for "lines" as the script at "path".  "wrapped" is the
# script level of a Vim9 script as a function, see wrap.vim; it is read
# after the script, in the same script context, so that it can use what the
# script defines.
function Check(path, lines, wrapped)
  let path = fnamemodify(a:path, ':p')
  " This script is running here, its functions cannot be defined again.
  if path ==# s:SELF
    let path ..= '.dryrun'
  endif
  call s:Load(path, a:lines)
  let messages = s:Source('%source ++dryrun')
  if type(a:wrapped) == v:t_list
    call s:Load(path, a:wrapped)
    let messages ..= s:Source('vim9cmd :%source ++dryrun')
  endif
  return s:Errors(messages, path)
endfunction

function OnMessage(ch, msg)
  if get(a:msg, 'method', '') == 'check'
    call ch_sendexpr(a:ch, {'id': a:msg.id, 'result': {
      \ 'dryrun': s:dryrun,
      \ 'errors': s:dryrun
      \   ? s:Check(a:msg.params.path, a:msg.params.lines, a:msg.params.wrapped)
      \   : [],
      \ }})
  endif
endfunction

# Whether ":source ++dryrun" is understood: a Vim without it takes the
# argument for a file name, which the range does not allow.
function HasDryrun()
  new
  on
  call setline(1, 'vim9script')
  redir => messages
  silent! %source ++dryrun
  redir END
  bwipe!
  return messages !~ 'E481:'
endfunction

def OnClose(ch: channel)
  qall!
enddef

export def Start()
  # Nothing the script defines must run here, and nothing it reads must be
  # kept.
  set eventignore=all undolevels=-1 nomodeline
  silent! language messages C
  dryrun = HasDryrun() != 0
  conn = ch_open('stdio', {mode: 'lsp', callback: OnMessage,
    close_cb: OnClose})
  if ch_status(conn) != 'open'
    cquit
  endif
enddef

if index(v:argv, '--stdio-channel') >= 0
  Start()
endif

# test/run sets this to have every :def compiled as the script is read.
if $VIM9LS_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
