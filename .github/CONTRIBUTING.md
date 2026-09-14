# Contributing

Issue reports are welcome.  Patches are read too, but a report that shows what
the server answered is usually worth more than a diff: the fix is written
here, in the style the rest of it is written in.

## What it is written against

The LSP specification and what Vim does.  The server answers from the Vim it
runs in, so where a question is about Vim script, Vim's help and what that Vim
actually does are what settle it.

Other language servers for Vim script are deliberately left out of it, their
source as much as their documentation, and a patch carrying code from one
cannot be taken.  Please point at the specification, or at Vim, rather than at
another server.

## Reporting

A report is easiest to act on with a file small enough to paste, the position
in it, what was asked for and what came back.  The Vim the server runs in
matters, since that is where the answers come from: a function or option that
this Vim does not have is not known to the server either.  `:version` names
it.

With `$VIM9LS_LOG` set, the server appends its channel log to that file: the
requests, the responses, and the errors the server ran into.  That log is the
most useful thing a report can carry.

## Patches

A change in behavior belongs with a test that fails without it, and with the
lines in `doc/vim9ls.txt` that describe it.  The server is Vim9 script
throughout, two spaces of indent.

The tests are in `test/`:

```
cd test && ./run
```

```
VIMPROG=/path/to/vim ./run       # which Vim to test, "vim" by default
TEST_FILTER=hover ./run          # only the tests whose name matches
```

The results are printed and also left in `test/messages`, and the exit status
reports whether anything failed.  The Vim the tests run in is also the server
they start, so it needs `--stdio-channel`; a Vim without it is reported as
such rather than failing every test.  Without `:source ++dryrun` the test of
the checker is skipped.

The unit tests read the parser and the conversions directly.  The server
tests start the server the way a client would and talk LSP to it, checking
what it answers and what it sends on its own.

CI runs the tests on Linux with a Vim built from the current sources of
vim/vim, and on MS-Windows with the newest build from vim-win32-installer.
One of the server tests starts the launcher, `bin/vim9ls` or
`bin/vim9ls.cmd`, the way a client does.
