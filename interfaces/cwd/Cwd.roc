## The process's userland working directory.
##
## Not the OS cwd: nothing here calls chdir. This is a slot the filesystem
## layer resolves relative paths against and the subprocess layer starts
## children in, so a Roc program can have a working directory without the
## process having one — which is what lets two of them coexist and what keeps
## `set_cwd!` from being a global side effect on the host.
##
## It was called `Cell` and spelled `put!`/`get!`, a generic one-slot cell that
## only ever held this. The generic name described the mechanism; this one
## describes the thing.
Cwd :: [].{
	## Empty until something sets it, which means "inherit the process cwd".
	get! : {} => Str
	set! : Str => {}
}
