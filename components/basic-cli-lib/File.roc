import Host
import Fs
import IOErr exposing [IOErr]
import Path

## Open files for incremental, buffered reading.
##
## Whole-file operations and filesystem metadata are available on [`Path`](Path).
File :: [].{

	## Represents a buffered file reader.
	##
	## The file is automatically closed when the last reference to the reader is
	## dropped. It wraps an opaque host-side `BufReader<File>` handle.
	Reader :: { host : Host.FileReader }.{

		## The open file under the reader, for redirecting a child process's
		## stdin to it. Bytes the reader has already buffered are not seen by
		## anything reading the descriptor.
		descriptor : Reader -> Fs.Descriptor
		descriptor = |reader| reader.host.descriptor

		## Render the reader without exposing its host handle.
		to_inspect : Reader -> Str
		to_inspect = |_| "File.Reader(<opaque>)"

		## Read bytes up to and including the next newline from this buffered reader.
		##
		## Returns an empty list at EOF, and `Err(LineTooLong)` for a line past
		## the reader's cap — which used to come back as an ordinary-looking
		## chunk with no newline on the end.
		read_line! : Reader => Try(List(U8), _)
		read_line! = |reader|
			match Host.file_read_line!(reader.host) {
				Ok(bytes) => Ok(bytes)
				Err(FileErr(err)) => Err(FileErr(err))
				Err(LineTooLong) => Err(LineTooLong)
			}
	}

	## Represents an unbuffered file writer: every write reaches the file before
	## it returns, so its error is that write's error. Batch in Roc when the
	## number of writes matters.
	##
	## The file is closed when the last reference to the writer is dropped.
	Writer :: { host : Host.FileWriter }.{

		## Wrap a writer opened outside this module (trantor-files' `Temp`
		## opens one exclusively through `Fs`): the type is opaque, so only
		## this module can build one.
		from_host : Host.FileWriter -> Writer
		from_host = |host| Writer.{ host }

		## The open file under the writer, for redirecting a child process's
		## output to it. The writer is unbuffered, so nothing is held back.
		descriptor : Writer -> Fs.Descriptor
		descriptor = |writer| writer.host.descriptor

		## Render the writer without exposing its host handle.
		to_inspect : Writer -> Str
		to_inspect = |_| "File.Writer(<opaque>)"

		## Write bytes.
		write! : Writer, List(U8) => Try({}, [FileErr(IOErr), ..])
		write! = |writer, bytes| Host.file_write!(writer.host, bytes).map_err(|FileErr(err)| FileErr(err))

		## Write a string as UTF-8.
		write_utf8! : Writer, Str => Try({}, [FileErr(IOErr), ..])
		write_utf8! = |writer, str| Host.file_write!(writer.host, Str.to_utf8(str)).map_err(|FileErr(err)| FileErr(err))

		## Write a string followed by a newline, in one write.
		line! : Writer, Str => Try({}, [FileErr(IOErr), ..])
		line! = |writer, str| Host.file_write!(writer.host, Str.to_utf8(str).append('\n')).map_err(|FileErr(err)| FileErr(err))
	}

	## Open a file for writing from the start, creating it if missing and
	## truncating it if not.
	##
	## ```roc
	## writer = File.open_writer!("out.txt")?
	## writer.line!("first")?
	## ```
	open_writer! : Path.Path => Try(Writer, [FileErr(IOErr), ..])
	open_writer! = |path|
		Host.file_open_writer!(Path.to_raw(path))
			.map_ok(|writer| Writer.{ host: writer })
			.map_err(|FileErr(err)| FileErr(err))

	## Open a file for appending, creating it if missing. Every write lands at
	## the end of the file, including when other processes append to it too.
	open_append! : Path.Path => Try(Writer, [FileErr(IOErr), ..])
	open_append! = |path|
		Host.file_open_append!(Path.to_raw(path))
			.map_ok(|writer| Writer.{ host: writer })
			.map_err(|FileErr(err)| FileErr(err))

	## Open a file for buffered reading.
	##
	## ```roc
	## reader = File.open_reader!("LICENSE")?
	## line = reader.read_line!()?
	## ```
	##
	## basic-cli also has `open_reader_with_capacity!`. There is no capacity to
	## set here: the buffer belongs to the sync-io stream the host mints, and
	## sizing it would mean a `capacity` argument on the hosted
	## `Fs.read_via_stream!` for a knob with no observable effect. A parameter
	## the host discards is worse than an absent one, so it is absent.
	open_reader! : Path.Path => Try(Reader, [FileErr(IOErr), ..])
	open_reader! = |path|
		Host.file_open_reader!(Path.to_raw(path))
			.map_ok(|reader| Reader.{ host: reader })
			.map_err(|FileErr(err)| FileErr(err))
}
