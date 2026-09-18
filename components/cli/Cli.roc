import IOErr exposing [IOErr]
import Streams
import OsStr exposing [OsStr]
import CliEnv
import CliExit
import CliIn
import CliOut

## One door onto the process itself: its arguments and environment, its three
## standard streams, and its exit.
##
## Behind it are four interfaces — roc:cli/environment, /exit, /stdin, /stdout
## — and they stay four, because wiring is per-interface and ending the
## process is not the same authority as reading argv: a world can still decline
## `cli-exit` alone, or put its own component behind `cli-stdin`. What was
## worth collapsing was the app's view, where five module names bought nothing.
##
## `read_line!` and `read_to_end!` are spelled `stdin_*` here. Inside `CliIn`
## the bare names said which stream they meant; next to `args!` and `exit!`
## they no longer do.
Cli :: [].{

	# --- roc:cli/environment ---------------------------------------------

	## The process arguments, argv[0] first.
	##
	## An app is passed its arguments as `main!`'s parameter and should use
	## that. This is here for the driver, which has no argv of its own.
	args! : {} => List(OsStr)
	args! = |{}| CliEnv.args!({})

	## One environment variable.
	var! : OsStr => Try(OsStr, [VarNotFound(OsStr), Io(IOErr)])
	var! = |name| CliEnv.var!(name)

	## Every environment variable, as name/value pairs.
	env! : {} => List({ name : OsStr, value : OsStr })
	env! = |{}| CliEnv.env!({})

	## The process working directory, with its bytes as the OS has them.
	## `Err(Io(_))` when it cannot be read, as when it has been deleted.
	cwd! : {} => Try(OsStr, [Io(IOErr)])
	cwd! = |{}| CliEnv.cwd!({})

	## The path to the running executable, with its bytes as the OS has them.
	exe_path! : {} => Try(OsStr, [Io(IOErr)])
	exe_path! = |{}| CliEnv.exe_path!({})

	## The system directory for temporary files: `TMPDIR`, or the platform's
	## default when it is unset.
	temp_dir! : {} => OsStr
	temp_dir! = |{}| CliEnv.temp_dir!({})

	## The architecture and OS the host was built for.
	platform! : {} => { arch : [X86, X64, ARM, AARCH64, OTHER(Str)], os : [LINUX, MACOS, WINDOWS, OTHER(Str)] }
	platform! = |{}| CliEnv.platform!({})

	# --- roc:cli/exit ----------------------------------------------------

	## End the process with this status. Does not return.
	exit! : I32 => {}
	exit! = |code| CliExit.exit!(code)

	# --- roc:cli/stdout, roc:cli/stdin -----------------------------------

	get_stdout! : {} => Streams.OutputStream
	get_stdout! = |{}| CliOut.get_stdout!({})

	get_stderr! : {} => Streams.OutputStream
	get_stderr! = |{}| CliOut.get_stderr!({})

	get_stdin! : {} => Streams.InputStream
	get_stdin! = |{}| CliIn.get_stdin!({})

	## One line of stdin without its newline; `EndOfFile` at EOF.
	stdin_line! : {} => Try(Str, [EndOfFile, Io(IOErr)])
	stdin_line! = |{}| CliIn.read_line!({})

	## The rest of stdin.
	stdin_read_to_end! : {} => Try(List(U8), [Io(IOErr)])
	stdin_read_to_end! = |{}| CliIn.read_to_end!({})

}
