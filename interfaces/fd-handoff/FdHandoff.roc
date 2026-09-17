import Fs
import IOErr exposing [IOErr]
import Streams
## The OS file descriptor behind a stream or an open file, for another
## package's host to hand to the OS — a child process's stdio, today.
##
## Not an app export: an fd number is ambient authority in a form Roc cannot
## type, and a leaked one outlives the resource it came from. Component hosts
## cannot read each other's resource payloads, so the numbers cross here, where
## the wiring can see the dependency (D-S2-14, D-S2-21).
##
## Every fd returned is a NEW descriptor (a close-on-exec `dup`) that the
## caller owns: the resource it came from may be released as soon as this call
## returns, and its descriptor closed with it. Hand it to a host call that
## takes ownership, or release it with `close_fd!`.
FdHandoff :: [].{
	## `NotAFile` for a stream with no descriptor under it (a test backing, a
	## socket's buffered reader, an HTTP body), or whose writes a child given
	## the descriptor would not reproduce (an append stream on a descriptor not
	## opened with `append`). `Io` when there is one but it could not be
	## duplicated (no descriptors left), or the stream itself could not be made.
	output_fd! : Streams.OutputStream => Try(I32, [NotAFile, Io(IOErr)])
	## The descriptor under an input stream. Bytes the stream has already
	## buffered stay in the stream: whoever reads the fd does not see them.
	input_fd! : Streams.InputStream => Try(I32, [NotAFile, Io(IOErr)])
	## Release an fd from this module that was not handed on.
	close_fd! : I32 => {}
	## The descriptor under an open file. `NotAFile` for a directory
	## descriptor, which names its directory by path, and `Io` when no stream
	## could be made over it.
	descriptor_fd! : Fs.Descriptor => Try(I32, [NotAFile, Io(IOErr)])
	descriptor_fd! = |d| match Fs.read_via_stream!(d) {
		Ok(stream) => FdHandoff.input_fd!(stream)
		Err(Io(IsADirectory)) => Err(NotAFile)
		Err(Io(e)) => Err(Io(e))
	}
}
