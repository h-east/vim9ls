@echo off
rem Starts vim9ls: a Vim that serves the Language Server Protocol on its stdin
rem and stdout.  %VIM9LS_VIM% names the Vim to use, "vim" from %PATH% otherwise.
setlocal
if "%VIM9LS_VIM%"=="" set VIM9LS_VIM=vim
"%VIM9LS_VIM%" --clean --stdio-channel -S "%~dp0..\autoload\vim9ls.vim"
