## A validated HTTP or HTTPS URL implemented entirely in Roc.
##
## This is deliberately stricter than a browser parser. Hosts must be ASCII
## DNS names, dotted-decimal IPv4 addresses, or bracketed IPv6 addresses made
## from hexadecimal groups with optional :: elision. IPv4-in-IPv6 and Unicode
## domain names are intentionally unsupported.
##
## This is basic-cli 0.21's Url, and it diverges from it in three places, each
## a case where basic-cli's answer let a URL mean something other than what it
## says: `append_path_segments` refuses a `.` or `..` item, so it returns a
## `Try`, `resolve` rejects a reference with a scheme other than http/https,
## and a host that another parser would read as a number (octal, hex, a numeric
## last label) is refused.
Url :: {
	scheme : [Http, Https],
	host : Str,
	port : [None, Some(U16)],
	path : Str,
	query : [None, Some(Str)],
	fragment : [None, Some(Str)],
}.{

	## A reason a URL or relative reference could not be parsed.
	##
	## This error set describes this module's strict HTTP/HTTPS subset. Inputs
	## that browsers might repair, such as missing authority slashes or
	## backslashes, are rejected instead.
	ParseErr : [
		CredentialsNotAllowed,
		EmptyHost,
		InternationalHostUnsupported,
		InvalidCharacter(U8),
		InvalidHost(Str),
		InvalidIpv4(Str),
		InvalidIpv6(Str),
		InvalidPercentEncoding(U64),
		InvalidPort(Str),
		MissingAuthority,
		MissingScheme,
		PortOutOfRange(U64),
		UnsupportedScheme(Str),
	]

	## Parse a dynamic string as an absolute HTTP or HTTPS URL.
	##
	## The input must contain an explicit scheme and authority. Its host is
	## lowercased, default ports are removed, dot path segments are normalized,
	## and non-ASCII path, query, and fragment bytes are percent-encoded.
	parse : Str -> Try(Url, ParseErr)
	parse = |input| parse_absolute(input)

	## Convert a quoted literal to a URL using the same validation as parse.
	##
	## Roc calls this automatically when a quoted literal is expected to have
	## type Url. A rejected literal reports a descriptive BadQuotedBytes error.
	from_quote : Str -> Try(Url, [BadQuotedBytes(Str)])
	from_quote = |input|
		match parse_absolute(input) {
			Ok(url) => Ok(url)
			Err(err) => Err(BadQuotedBytes(parse_err_to_str(err)))
		}

	## Parse a URL from a string value supplied by a generic encoding.
	parser_for : encoding -> (state -> Try({ value : Url, rest : state }, err))
		where [
			encoding.parse_str : encoding, state -> Try({ value : Str, rest : state }, err),
			encoding.invalid_value : encoding, state -> err,
		]
	parser_for = |encoding| {
		Encoding : encoding

		|state| {
			parsed = Encoding.parse_str(encoding, state)?

			match parse(parsed.value) {
				Ok(url) => Ok({ value: url, rest: parsed.rest })
				Err(_) => Err(Encoding.invalid_value(encoding, state))
			}
		}
	}

	## Encode a URL as its canonical string through a generic encoding.
	encoder_for : encoding -> (Url, state -> Try(state, err))
		where [
			encoding.encode_str : Str, state -> Try(state, err),
		]
	encoder_for = |_encoding| {
		Encoding : encoding

		|url, state| Encoding.encode_str(to_str(url), state)
	}

	## Serialize the URL in a stable normalized ASCII form.
	##
	## Scheme and DNS host names are lowercase, default ports are omitted,
	## paths are absolute, and IPv6 addresses use eight unpadded groups.
	to_str : Url -> Str
	to_str = |url| serialize(url, True)

	## Render a URL for debugging and test failures.
	to_inspect : Url -> Str
	to_inspect = |url| "Url(${Json.to_str(to_str(url))})"

	## Compare URLs by their canonical serialized representation.
	is_eq : Url, Url -> Bool
	is_eq = |left, right| Str.is_eq(to_str(left), to_str(right))

	## Hash URLs consistently with canonical equality.
	to_hash : Url, Hasher -> Hasher
	to_hash = |url, hasher| Str.to_hash(to_str(url), hasher)

	## Return Http or Https.
	scheme : Url -> [Http, Https]
	scheme = |url| url.scheme

	## Return the canonical host.
	##
	## IPv6 brackets are omitted; to_str includes them where required.
	host : Url -> Str
	host = |url|
		if starts_with(url.host, "[") {
			trim_brackets(url.host)
		} else {
			url.host
		}

	## Return an explicit non-default port.
	##
	## Ports 80 for HTTP and 443 for HTTPS are canonicalized to None.
	port : Url -> [None, Some(U16)]
	port = |url| url.port

	## Return the absolute percent-encoded path, always beginning with slash.
	path : Url -> Str
	path = |url| url.path

	## Return the percent-encoded query without its leading question mark.
	##
	## None and Some("") distinguish no query from a present empty query.
	query : Url -> [None, Some(Str)]
	query = |url| url.query

	## Return the percent-encoded fragment without its leading hash.
	##
	## None and Some("") distinguish no fragment from a present empty fragment.
	fragment : Url -> [None, Some(Str)]
	fragment = |url| url.fragment

	## Return this URL without its fragment. HTTP never transmits fragments.
	without_fragment : Url -> Url
	without_fragment = |url|
		Url.{
			scheme: url.scheme,
			host: url.host,
			port: url.port,
			path: url.path,
			query: url.query,
			fragment: None,
		}

	## Resolve a strict relative reference or absolute web URL against this URL.
	##
	## Root-relative, path-relative, query-only, and fragment-only references
	## are supported. Scheme-relative references are rejected.
	##
	## A reference that starts with a scheme (`name:`, RFC 3986 §3.1) is
	## absolute (§4.2, §5.2.2). An http or https one is parsed as `parse` does,
	## so `http:g`, which has no authority, is rejected as `parse` rejects it;
	## any other (`mailto:`, `javascript:`, `ftp:`) is `UnsupportedScheme`.
	## basic-cli 0.21 read `mailto:a` or `javascript:x` as a path and resolved
	## it onto the base. A relative path whose first segment holds a colon is
	## written `./a:b`, as the RFC requires, and resolves as a path.
	resolve : Url, Str -> Try(Url, ParseErr)
	resolve = |base, reference| resolve_reference(base, reference)

	## Append unencoded path segments.
	##
	## Each list item is one segment, so slash characters inside an item are
	## percent-encoded rather than treated as separators, and an empty item is
	## an empty segment. An item that is `.` or `..` is `Err(DotSegment(item))`:
	## no spelling of it stays one literal segment. Left bare, normalization
	## read it as a dot segment and `["..", "..", "admin"]` on `/v1/users/`
	## gave `/admin`; encoded as `%2E%2E`, WHATWG and RFC 3986 still read it as
	## `..`, and so do servers that follow them. Other dot-only items, `...`
	## included, are ordinary names to WHATWG, and are kept.
	##
	## basic-cli 0.21's signature is `Url, List(Str) -> Url`, and it appended
	## `..` bare.
	append_path_segments : Url, List(Str) -> Try(Url, [DotSegment(Str)])
	append_path_segments = |url, segments|
		match List.find_first(segments, is_dot_segment) {
			Ok(dots) => Err(DotSegment(dots))
			Err(_) => Ok(with_segments(url, segments))
		}

	## Append one application/x-www-form-urlencoded query pair.
	##
	## Existing parameters, ordering, duplicate names, and the fragment are
	## preserved.
	append_query_param : Url, Str, Str -> Url
	append_query_param = |url, key, value| {
		pair = Str.concat(Str.concat(form_encode(key), "="), form_encode(value))
		next_query = 
			match url.query {
				None => pair
				Some("") => pair
				Some(existing) => Str.concat(Str.concat(existing, "&"), pair)
			}
		Url.{
			scheme: url.scheme,
			host: url.host,
			port: url.port,
			path: url.path,
			query: Some(next_query),
			fragment: url.fragment,
		}
	}

	## Decode the query into ordered name/value pairs.
	##
	## Plus signs decode as spaces, percent escapes decode as UTF-8 bytes,
	## parameters without equals receive an empty value, and duplicates remain.
	query_pairs : Url -> List((Str, Str))
	query_pairs = |url|
		match url.query {
			None => []
			Some("") => []
			Some(query_str) =>
				Str.split_on(query_str, "&").map(
					|pair|
						match split_first(pair, "=") {
							Found({ before, after }) => (form_decode(before), form_decode(after))
							NotFound => (form_decode(pair), "")
						},
				)
			}

	## Replace or remove the query.
	##
	## Some("") produces a present empty query. The supplied query may contain
	## Unicode but must otherwise already obey URL query syntax.
	with_query : Url, [None, Some(Str)] -> Try(Url, ParseErr)
	with_query = |url, option| {
		next_query_option = 
			match option {
				None => Ok(None)
				Some(raw) =>
					match validate_component(raw, Query) {
						Ok(value) => Ok(Some(value))
						Err(err) => Err(err)
					}
				}?
		Ok(
			Url.{
				scheme: url.scheme,
				host: url.host,
				port: url.port,
				path: url.path,
				query: next_query_option,
				fragment: url.fragment,
			},
		)
	}

	## Replace or remove the fragment.
	##
	## Some("") produces a present empty fragment. Unicode is percent-encoded.
	with_fragment : Url, [None, Some(Str)] -> Try(Url, ParseErr)
	with_fragment = |url, option| {
		next_fragment_option = 
			match option {
				None => Ok(None)
				Some(raw) =>
					match validate_component(raw, Fragment) {
						Ok(value) => Ok(Some(value))
						Err(err) => Err(err)
					}
				}?
		Ok(
			Url.{
				scheme: url.scheme,
				host: url.host,
				port: url.port,
				path: url.path,
				query: url.query,
				fragment: next_fragment_option,
			},
		)
	}
}

## `url` with `segments` appended, none of them a dot segment. An empty list
## leaves the path as it was; an empty item is an empty segment.
with_segments : Url, List(Str) -> Url
with_segments = |url, segments| {
	suffix = Str.join_with(segments.map(percent_encode), "/")
	next_path =
		if List.is_empty(segments) {
			url.path
		} else if url.path == "/" {
			Str.concat("/", suffix)
		} else if ends_with(url.path, "/") {
			Str.concat(url.path, suffix)
		} else {
			Str.concat(Str.concat(url.path, "/"), suffix)
		}
	Url.{
		scheme: url.scheme,
		host: url.host,
		port: url.port,
		path: normalize_path(next_path),
		query: url.query,
		fragment: url.fragment,
	}
}

## A path segment every normalizer removes or climbs with. WHATWG also reads
## `%2e` for a dot, but an item is encoded before it is a segment, so its `%`
## is `%25` and only the bare dots matter here.
is_dot_segment : Str -> Bool
is_dot_segment = |segment| segment == "." or segment == ".."

# Absolute URL and authority parsing.

parse_absolute : Str -> Try(Url, Url.ParseErr)
parse_absolute = |input| {
	{ scheme, after } = split_scheme(input)?
	{ authority, suffix } = split_authority(after)
	if Str.is_empty(authority) {
		Err(EmptyHost)
	} else if Str.contains(authority, "@") {
		Err(CredentialsNotAllowed)
	} else {
		parsed_authority = parse_authority(authority, scheme)?
		components = parse_suffix(suffix)?
		Ok(
			Url.{
				scheme,
				host: parsed_authority.host,
				port: parsed_authority.port,
				path: normalize_path(components.path),
				query: components.query,
				fragment: components.fragment,
			},
		)
	}
}

## The scheme and what follows its `://`. The scheme is read by RFC 3986
## §3.1, not by splitting at the first `://`: `http:/x://y` is an http
## reference without an authority, which is `MissingAuthority` as `http:g` is,
## where the split answered `UnsupportedScheme("http:/x")`.
split_scheme : Str -> Try({ scheme : [Http, Https], after : Str }, Url.ParseErr)
split_scheme = |input| {
	web = match reference_scheme(input) {
		Ok(name) =>
			match ascii_lower(name) {
				"http" => Ok((Http, name))
				"https" => Ok((Https, name))
				_ => Err(NotWeb)
			}
		Err(NoScheme) => Err(NotWeb)
	}
	match web {
		Ok((scheme, name)) => {
			rest = drop_prefix(input, Str.concat(name, ":"))
			if starts_with(rest, "//") {
				Ok({ scheme, after: drop_prefix(rest, "//") })
			} else {
				Err(MissingAuthority)
			}
		}
		Err(NotWeb) =>
			match split_first(input, "://") {
				Found(parts) => Err(UnsupportedScheme(ascii_lower(parts.before)))
				NotFound =>
					if Str.contains(input, ":") {
						Err(MissingAuthority)
					} else {
						Err(MissingScheme)
					}
				}
	}
}

parse_authority : Str, [Http, Https] -> Try({ host : Str, port : [None, Some(U16)] }, Url.ParseErr)
parse_authority = |authority, scheme| {
	if starts_with(authority, "[") {
		match split_first(authority, "]") {
			NotFound => Err(InvalidIpv6(authority))
			Found({ before, after }) => {
				raw_ipv6 = drop_prefix(before, "[")
				host = validate_ipv6(raw_ipv6)?
				port = 
					if Str.is_empty(after) {
						Ok(None)
					} else if starts_with(after, ":") {
						parse_port(drop_prefix(after, ":"), scheme)
					} else {
						Err(InvalidIpv6(authority))
					}
				Ok({ host: Str.concat(Str.concat("[", host), "]"), port: port? })
			}
		}
	} else {
		{ raw_host, raw_port } = 
			match split_last(authority, ":") {
				Found({ before, after }) => { raw_host: before, raw_port: Some(after) }
				NotFound => { raw_host: authority, raw_port: None }
			}
		host = validate_host(raw_host)?
		port = 
			match raw_port {
				None => Ok(None)
				Some(raw) => parse_port(raw, scheme)
			}
		Ok({ host, port: port? })
	}
}

## A host that is not dotted-decimal but ends in a numeric label is refused
## with `InvalidIpv4`: WHATWG parses any host whose last label is a number as
## IPv4 (and fails if it is not one), and getaddrinfo reads `0x7f.0.0.1` as
## 127.0.0.1, so accepting it as a DNS name let one URL name two hosts.
## basic-cli 0.21 accepted it.
validate_host : Str -> Try(Str, Url.ParseErr)
validate_host = |raw_host| {
	if Str.is_empty(raw_host) {
		Err(EmptyHost)
	} else if List.any(Str.to_utf8(raw_host), |byte| byte > 127) {
		Err(InternationalHostUnsupported)
	} else if List.all(Str.to_utf8(raw_host), |byte| is_digit(byte) or byte == 46) {
		validate_ipv4(raw_host)
	} else if ends_in_number(raw_host) {
		Err(InvalidIpv4(raw_host))
	} else {
		validate_dns_name(raw_host)
	}
}

## Whether the last label is all digits, or `0x`/`0X` then hex digits: what
## WHATWG's "ends in a number" test reads as an IPv4 number.
ends_in_number : Str -> Bool
ends_in_number = |host| {
	last = match List.last(Str.split_on(host, ".")) {
		Ok(label) => Str.to_utf8(label)
		Err(_) => []
	}
	match last {
		[] => False
		['0', x, .. as hex] if x == 'x' or x == 'X' => List.all(hex, is_hex)
		digits => List.all(digits, is_digit)
	}
}

validate_dns_name : Str -> Try(Str, [InvalidHost(Str), ..])
validate_dns_name = |raw_host| {
	host = ascii_lower(raw_host)
	labels = Str.split_on(host, ".")
	valid = 
		List.len(Str.to_utf8(host)) <= 253 and
			List.all(
				labels,
				|label| {
					bytes = Str.to_utf8(label)
					len = List.len(bytes)
					len > 0 and len <= 63 and
						is_alphanumeric(first_or_zero(bytes)) and
							is_alphanumeric(last_or_zero(bytes)) and
								List.all(bytes, |byte| is_alphanumeric(byte) or byte == 45)
				},
			)
	if valid {
		Ok(host)
	} else {
		Err(InvalidHost(raw_host))
	}
}

validate_ipv4 : Str -> Try(Str, [InvalidIpv4(Str), ..])
validate_ipv4 = |raw_host| {
	parts = Str.split_on(raw_host, ".")
	if List.len(parts) != 4 {
		Err(InvalidIpv4(raw_host))
	} else {
		match parse_ipv4_parts(parts, []) {
			Err(_) => Err(InvalidIpv4(raw_host))
			Ok(values) => Ok(Str.join_with(values.map(U64.to_str), "."))
		}
	}
}

## An octet with a leading zero is refused (RFC 3986's dec-octet has none).
## It used to be read as decimal with the zero dropped, while WHATWG and
## `inet_aton` read `010` as octal 8, so `010.0.0.1` named 10.0.0.1 here and
## 8.0.0.1 there. basic-cli 0.21 accepted it.
parse_ipv4_parts : List(Str), List(U64) -> Try(List(U64), [BadIpv4Part])
parse_ipv4_parts = |parts, out|
	match parts {
		[] => Ok(out)
		[first, ..] if List.len(Str.to_utf8(first)) > 1 and starts_with(first, "0") => Err(BadIpv4Part)
		[first, .. as rest] =>
			match parse_decimal(first) {
				Ok(value) =>
					if value <= 255 {
						parse_ipv4_parts(rest, out.append(value))
					} else {
						Err(BadIpv4Part)
					}
				Err(_) => Err(BadIpv4Part)
			}
		}

parse_port : Str, [Http, Https] -> Try([None, Some(U16)], [InvalidPort(Str), PortOutOfRange(U64), ..])
parse_port = |raw, scheme|
	match parse_decimal(raw) {
		Err(_) => Err(InvalidPort(raw))
		Ok(value) =>
			if value > 65535 {
				Err(PortOutOfRange(value))
			} else {
				port = U64.to_u16_wrap(value)
				is_default = 
					match scheme {
						Http => port == 80
						Https => port == 443
					}
				Ok(
					if is_default {
						None
					} else {
						Some(port)
					},
				)
			}
		}

## Above any value a URL can legitimately carry, and low enough that
## `acc * 10 + 9` cannot overflow a U64 from it.
decimal_cap : U64
decimal_cap = 4_294_967_295

## Saturates instead of overflowing. `acc * 10` on an unbounded U64 aborted the
## process for a long enough digit run — "Integer multiplication overflowed",
## reachable from `Url.parse` on any untrusted string, in the one module whose
## whole job is surviving hostile input:
##
##     Url.parse("http://example.com:99999999999999999999999/")
##     Url.parse("http://99999999999999999999.1.1.1/")
##
## Every caller rejects anything above 65535, so a saturated value produces the
## same rejection a merely-large one does — and `parse_port` can now reach the
## `PortOutOfRange` variant it already had, instead of dying.
parse_decimal : Str -> Try(U64, [NotDecimal])
parse_decimal = |raw| {
	bytes = Str.to_utf8(raw)
	if List.is_empty(bytes) or Bool.not(List.all(bytes, is_digit)) {
		Err(NotDecimal)
	} else {
		Ok(List.fold(bytes, 0, |acc, byte| if acc >= decimal_cap { decimal_cap } else { acc * 10 + U8.to_u64(byte - 48) }))
	}
}

expect parse_decimal("0") == Ok(0)
expect parse_decimal("80") == Ok(80)
expect parse_decimal("65535") == Ok(65535)
expect parse_decimal("") == Err(NotDecimal)
expect parse_decimal("12a") == Err(NotDecimal)
## The run that used to abort.
expect parse_decimal("99999999999999999999999") == Ok(decimal_cap)
expect parse_decimal(Str.repeat("9", 400)) == Ok(decimal_cap)

is_err_parse : Try(Url, _) -> Bool
is_err_parse = |r|
	match r {
		Ok(_) => Bool.False
		Err(_) => Bool.True
	}

## End to end: both crashing inputs are now ordinary rejections.
expect is_err_parse(Url.parse("http://example.com:99999999999999999999999/"))
expect is_err_parse(Url.parse("http://99999999999999999999.1.1.1/"))
expect Url.parse("http://example.com:8080/").map_ok(Url.port) == Ok(Some(8080))

# IPv6 parsing.
#
# Addresses are validated as eight hexadecimal groups, with at most one ::
# elision. IPv4-in-IPv6 syntax is outside this module's deliberately small
# subset. Serialization expands elided groups and removes leading zeroes.
validate_ipv6 : Str -> Try(Str, [InvalidIpv6(Str), ..])
validate_ipv6 = |raw| {
	pieces = Str.split_on(raw, "::")
	if List.len(pieces) > 2 {
		Err(InvalidIpv6(raw))
	} else if List.len(pieces) == 1 {
		groups = parse_ipv6_side(raw)?
		if List.len(groups) == 8 {
			Ok(serialize_ipv6(groups))
		} else {
			Err(InvalidIpv6(raw))
		}
	} else {
		left = parse_ipv6_side(get_or_empty(pieces, 0))?
		right = parse_ipv6_side(get_or_empty(pieces, 1))?
		count = List.len(left) + List.len(right)
		if count >= 8 {
			Err(InvalidIpv6(raw))
		} else {
			groups = List.concat(List.concat(left, List.repeat(0, 8 - count)), right)
			Ok(serialize_ipv6(groups))
		}
	}
}

parse_ipv6_side : Str -> Try(List(U16), [InvalidIpv6(Str), ..])
parse_ipv6_side = |raw|
	if Str.is_empty(raw) {
		Ok([])
	} else {
		parse_hex_groups(Str.split_on(raw, ":"), [])
	}

parse_hex_groups : List(Str), List(U16) -> Try(List(U16), [InvalidIpv6(Str), ..])
parse_hex_groups = |parts, out|
	match parts {
		[] => Ok(out)
		[first, .. as rest] => {
			bytes = Str.to_utf8(first)
			if List.is_empty(bytes) or List.len(bytes) > 4 or Bool.not(List.all(bytes, is_hex)) {
				Err(InvalidIpv6(first))
			} else {
				value = List.fold(bytes, 0, |acc, byte| acc * 16 + U8.to_u16(hex_value(byte)))
				parse_hex_groups(rest, out.append(value))
			}
		}
	}

serialize_ipv6 : List(U16) -> Str
serialize_ipv6 = |groups| Str.join_with(groups.map(u16_to_hex), ":")

u16_to_hex : U16 -> Str
u16_to_hex = |value|
	if value == 0 {
		"0"
	} else {
		u16_to_hex_help(value, [])
	}

u16_to_hex_help : U16, List(U8) -> Str
u16_to_hex_help = |value, digits| {
	next_digits = [lower_hex_digit_byte(U16.to_u8_wrap(value % 16))].concat(digits)
	next = value // 16
	if next == 0 {
		Str.from_utf8_lossy(next_digits)
	} else {
		u16_to_hex_help(next, next_digits)
	}
}

parse_suffix : Str -> Try({ fragment : [None, Some(Str)], path : Str, query : [None, Some(Str)] }, Url.ParseErr)
parse_suffix = |suffix| {
	{ before_fragment, fragment } = 
		match split_first(suffix, "#") {
			Found({ before, after }) => { before_fragment: before, fragment: Some(after) }
			NotFound => { before_fragment: suffix, fragment: None }
		}
	{ raw_path, query } = 
		match split_first(before_fragment, "?") {
			Found({ before, after }) => { raw_path: before, query: Some(after) }
			NotFound => { raw_path: before_fragment, query: None }
		}
	path_input = if Str.is_empty(raw_path) {
		"/"
	} else {
		raw_path
	}
	if Bool.not(starts_with(path_input, "/")) {
		Err(InvalidCharacter(first_or_zero(Str.to_utf8(path_input))))
	} else {
		path = validate_component(path_input, Path)?
		encoded_query = validate_optional(query, Query)?
		encoded_fragment = validate_optional(fragment, Fragment)?
		Ok({ path, query: encoded_query, fragment: encoded_fragment })
	}
}

validate_optional : [None, Some(Str)], [Fragment, Path, Query] -> Try([None, Some(Str)], Url.ParseErr)
validate_optional = |option, kind|
	match option {
		None => Ok(None)
		Some(raw) =>
			match validate_component(raw, kind) {
				Ok(value) => Ok(Some(value))
				Err(err) => Err(err)
			}
		}

validate_component : Str, [Fragment, Path, Query] -> Try(Str, Url.ParseErr)
validate_component = |raw, kind|
	match validate_component_help(Str.to_utf8(raw), kind, 0, []) {
		Ok(bytes) => Ok(Str.from_utf8_lossy(bytes))
		Err(err) => Err(err)
	}

validate_component_help : List(U8), [Fragment, Path, Query], U64, List(U8) -> Try(List(U8), Url.ParseErr)
validate_component_help = |bytes, kind, index, out| {
	if index >= List.len(bytes) {
		Ok(out)
	} else {
		byte = get_or_zero(bytes, index)
		if byte == 37 {
			if index + 2 >= List.len(bytes) or Bool.not(is_hex(get_or_zero(bytes, index + 1))) or Bool.not(is_hex(get_or_zero(bytes, index + 2))) {
				Err(InvalidPercentEncoding(index))
			} else {
				next = out.append(37)
					.append(ascii_upper_hex(get_or_zero(bytes, index + 1)))
					.append(ascii_upper_hex(get_or_zero(bytes, index + 2)))
				validate_component_help(bytes, kind, index + 3, next)
			}
		} else if byte > 127 {
			validate_component_help(bytes, kind, index + 1, append_percent_byte(out, byte))
		} else if is_forbidden(byte, kind) {
			Err(InvalidCharacter(byte))
		} else {
			validate_component_help(bytes, kind, index + 1, out.append(byte))
		}
	}
}

is_forbidden : U8, [Fragment, Path, Query] -> Bool
is_forbidden = |byte, kind| {
	common = byte <= 32 or byte == 127 or byte == 34 or byte == 60 or byte == 62 or byte == 92
	if common {
		True
	} else {
		match kind {
			Path => byte == 35 or byte == 63
			Query => byte == 35
			Fragment => False
		}
	}
}

# Relative-reference resolution and path normalization.

resolve_reference : Url, Str -> Try(Url, Url.ParseErr)
resolve_reference = |base, reference| {
	match reference_scheme(reference) {
		Ok(scheme) =>
			match ascii_lower(scheme) {
				"http" => parse_absolute(reference)
				"https" => parse_absolute(reference)
				other => Err(UnsupportedScheme(other))
			}
		Err(NoScheme) => resolve_relative(base, reference)
	}
}

## The scheme a reference starts with: ALPHA *( ALPHA / DIGIT / "+" / "-" /
## "." ) then ":" (RFC 3986 §3.1).
reference_scheme : Str -> Try(Str, [NoScheme])
reference_scheme = |reference| {
	bytes = Str.to_utf8(reference)
	name = List.take_first(bytes, scheme_length(bytes, 0))
	match (List.first(name), List.get(bytes, List.len(name))) {
		(Ok(first), Ok(':')) if is_alpha(first) => Ok(Str.from_utf8_lossy(name))
		_ => Err(NoScheme)
	}
}

scheme_length : List(U8), U64 -> U64
scheme_length = |bytes, index|
	match List.get(bytes, index) {
		Ok(byte) if is_alphanumeric(byte) or byte == '+' or byte == '-' or byte == '.' => scheme_length(bytes, index + 1)
		_ => index
	}

resolve_relative : Url, Str -> Try(Url, Url.ParseErr)
resolve_relative = |base, reference| {
	# A network-path reference (`//host/x`) is refused. A `://` anywhere else
	# is not a scheme, since `resolve_reference` has already found any scheme
	# there is: it is a path, query or fragment (`?next=https://x.com/`), and
	# refusing it made a login redirect unresolvable.
	if starts_with(reference, "//") {
		Err(MissingScheme)
	} else {
		relative = parse_relative(reference)?
		next_path = 
			if Str.is_empty(relative.path) {
				base.path
			} else if starts_with(relative.path, "/") {
				normalize_path(relative.path)
			} else {
				normalize_path(Str.concat(path_directory(base.path), relative.path))
			}
		next_query = 
			match relative.query {
				Some(value) => Some(value)
				None => if Str.is_empty(relative.path) {
					base.query
				} else {
					None
				}
			}
		Ok(
			Url.{
				scheme: base.scheme,
				host: base.host,
				port: base.port,
				path: next_path,
				query: next_query,
				fragment: relative.fragment,
			},
		)
	}
}

parse_relative : Str -> Try({ fragment : [None, Some(Str)], path : Str, query : [None, Some(Str)] }, Url.ParseErr)
parse_relative = |reference| {
	{ before_fragment, fragment } = 
		match split_first(reference, "#") {
			Found({ before, after }) => { before_fragment: before, fragment: Some(after) }
			NotFound => { before_fragment: reference, fragment: None }
		}
	{ raw_path, query } = 
		match split_first(before_fragment, "?") {
			Found({ before, after }) => { raw_path: before, query: Some(after) }
			NotFound => { raw_path: before_fragment, query: None }
		}
	path = validate_component(raw_path, Path)?
	encoded_query = validate_optional(query, Query)?
	encoded_fragment = validate_optional(fragment, Fragment)?
	Ok({ path, query: encoded_query, fragment: encoded_fragment })
}

## RFC 3986 §5.2.4's remove_dot_segments, as WHATWG does it: a `.` segment
## is dropped and a `..` drops the segment before it, and either one last
## leaves the path ending in `/`. Every other segment is kept, an empty one
## included. Empty segments used to be dropped too, so `/v1//x/../y` became
## `/v1/y` where both references give `/v1//y`.
normalize_path : Str -> Str
normalize_path = |path_str| {
	rooted = if starts_with(path_str, "/") {
		path_str
	} else {
		Str.concat("/", path_str)
	}
	# The first item is the empty string before the leading `/`.
	segments = List.drop_first(Str.split_on(rooted, "/"), 1)
	Str.concat("/", Str.join_with(normalize_segments(segments, []), "/"))
}

normalize_segments : List(Str), List(Str) -> List(Str)
normalize_segments = |segments, out|
	match segments {
		[] => out
		["."] => out.append("")
		[".."] => List.drop_last(out, 1).append("")
		[".", .. as rest] => normalize_segments(rest, out)
		["..", .. as rest] => normalize_segments(rest, List.drop_last(out, 1))
		[first, .. as rest] => normalize_segments(rest, out.append(first))
	}

path_directory : Str -> Str
path_directory = |path_str| {
	parts = Str.split_on(path_str, "/")
	if List.len(parts) <= 2 {
		"/"
	} else {
		Str.concat(Str.join_with(List.drop_last(parts, 1), "/"), "/")
	}
}

serialize : Url, Bool -> Str
serialize = |url, include_fragment| {
	scheme_str = 
		match url.scheme {
			Http => "http"
			Https => "https"
		}
	port_str = 
		match url.port {
			None => ""
			Some(value) => Str.concat(":", U16.to_str(value))
		}
	query_str = 
		match url.query {
			None => ""
			Some(value) => Str.concat("?", value)
		}
	fragment_str = 
		if include_fragment {
			match url.fragment {
				None => ""
				Some(value) => Str.concat("#", value)
			}
		} else {
			""
		}
	Str.concat(
		Str.concat(
			Str.concat(
				Str.concat(
					Str.concat(Str.concat(scheme_str, "://"), url.host),
					port_str,
				),
				url.path,
			),
			query_str,
		),
		fragment_str,
	)
}

# Percent encoding and application/x-www-form-urlencoded query handling.

percent_encode : Str -> Str
percent_encode = |input|
	Str.from_utf8_lossy(
		List.fold(
			Str.to_utf8(input),
			[],
			|out, byte|
				if is_unreserved(byte) {
					out.append(byte)
				} else {
					append_percent_byte(out, byte)
				},
		),
	)

form_encode : Str -> Str
form_encode = |input|
	Str.from_utf8_lossy(
		List.fold(
			Str.to_utf8(input),
			[],
			|out, byte|
				if byte == 32 {
					out.append(43)
				} else if is_form_unescaped(byte) {
					out.append(byte)
				} else {
					append_percent_byte(out, byte)
				},
		),
	)

form_decode : Str -> Str
form_decode = |input| Str.from_utf8_lossy(form_decode_help(Str.to_utf8(input), 0, []))

form_decode_help : List(U8), U64, List(U8) -> List(U8)
form_decode_help = |bytes, index, out| {
	if index >= List.len(bytes) {
		out
	} else {
		byte = get_or_zero(bytes, index)
		if byte == 43 {
			form_decode_help(bytes, index + 1, out.append(32))
		} else if byte == 37 and index + 2 < List.len(bytes) and is_hex(get_or_zero(bytes, index + 1)) and is_hex(get_or_zero(bytes, index + 2)) {
			decoded = hex_value(get_or_zero(bytes, index + 1)) * 16 + hex_value(get_or_zero(bytes, index + 2))
			form_decode_help(bytes, index + 3, out.append(decoded))
		} else {
			form_decode_help(bytes, index + 1, out.append(byte))
		}
	}
}

# Small string and byte helpers. Keeping these local avoids depending on host
# code or exposing parser implementation details through the public API.

split_authority : Str -> { authority : Str, suffix : Str }
split_authority = |after_scheme| {
	bytes = Str.to_utf8(after_scheme)
	index = first_delimiter(bytes, 0)
	authority = Str.from_utf8_lossy(List.sublist(bytes, { start: 0, len: index }))
	suffix = Str.from_utf8_lossy(List.sublist(bytes, { start: index, len: List.len(bytes) - index }))
	{ authority, suffix }
}

first_delimiter : List(U8), U64 -> U64
first_delimiter = |bytes, index| {
	if index >= List.len(bytes) {
		index
	} else {
		byte = get_or_zero(bytes, index)
		if byte == 47 or byte == 63 or byte == 35 {
			index
		} else {
			first_delimiter(bytes, index + 1)
		}
	}
}

parse_err_to_str : Url.ParseErr -> Str
parse_err_to_str = |err|
	match err {
		CredentialsNotAllowed => "URL credentials are not supported"
		EmptyHost => "URL host is empty"
		InternationalHostUnsupported => "URL host must be ASCII; use its Punycode form"
		InvalidCharacter(byte) => Str.concat("URL contains invalid byte ", U8.to_str(byte))
		InvalidHost(host) => Str.concat("Invalid URL host: ", host)
		InvalidIpv4(host) => Str.concat("Invalid IPv4 address: ", host)
		InvalidIpv6(host) => Str.concat("Invalid IPv6 address: ", host)
		InvalidPercentEncoding(index) => Str.concat("Invalid percent escape at byte ", U64.to_str(index))
		InvalidPort(port) => Str.concat("Invalid URL port: ", port)
		MissingAuthority => "URL must contain :// after its scheme"
		MissingScheme => "URL must start with http:// or https://"
		PortOutOfRange(port) => Str.concat("URL port is out of range: ", U64.to_str(port))
		UnsupportedScheme(scheme) => Str.concat("Unsupported URL scheme: ", scheme)
	}

ascii_lower : Str -> Str
ascii_lower = |input|
	Str.from_utf8_lossy(
		Str.to_utf8(input).map(
			|byte|
				if byte >= 65 and byte <= 90 {
					byte + 32
				} else {
					byte
				},
		),
	)

ascii_upper_hex : U8 -> U8
ascii_upper_hex = |byte|
	if byte >= 97 and byte <= 102 {
		byte - 32
	} else {
		byte
	}

is_unreserved : U8 -> Bool
is_unreserved = |byte| is_alphanumeric(byte) or byte == 45 or byte == 46 or byte == 95 or byte == 126

is_form_unescaped : U8 -> Bool
is_form_unescaped = |byte| is_alphanumeric(byte) or byte == 42 or byte == 45 or byte == 46 or byte == 95

is_alphanumeric : U8 -> Bool
is_alphanumeric = |byte| is_digit(byte) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)

is_alpha : U8 -> Bool
is_alpha = |byte| (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)

is_digit : U8 -> Bool
is_digit = |byte| byte >= 48 and byte <= 57

is_hex : U8 -> Bool
is_hex = |byte| is_digit(byte) or (byte >= 65 and byte <= 70) or (byte >= 97 and byte <= 102)

hex_value : U8 -> U8
hex_value = |byte|
	if byte <= 57 {
		byte - 48
	} else if byte <= 70 {
		byte - 55
	} else {
		byte - 87
	}

append_percent_byte : List(U8), U8 -> List(U8)
append_percent_byte = |out, byte|
	out.append(37).append(hex_digit_byte(byte // 16)).append(hex_digit_byte(byte % 16))

hex_digit_byte : U8 -> U8
hex_digit_byte = |value|
	if value < 10 {
		value + 48
	} else {
		value + 55
	}

lower_hex_digit_byte : U8 -> U8
lower_hex_digit_byte = |value|
	if value < 10 {
		value + 48
	} else {
		value + 87
	}

get_or_zero : List(U8), U64 -> U8
get_or_zero = |list, index|
	match list.get(index) {
		Ok(value) => value
		Err(_) => 0
	}

get_or_empty : List(Str), U64 -> Str
get_or_empty = |list, index|
	match list.get(index) {
		Ok(value) => value
		Err(_) => ""
	}

first_or_zero : List(U8) -> U8
first_or_zero = |list| get_or_zero(list, 0)

last_or_zero : List(U8) -> U8
last_or_zero = |list|
	if List.is_empty(list) {
		0
	} else {
		get_or_zero(list, List.len(list) - 1)
	}

trim_brackets : Str -> Str
trim_brackets = |str| {
	bytes = Str.to_utf8(str)
	if List.len(bytes) < 2 {
		""
	} else {
		Str.from_utf8_lossy(List.sublist(bytes, { start: 1, len: List.len(bytes) - 2 }))
	}
}

starts_with : Str, Str -> Bool
starts_with = |str, prefix|
	if Str.is_empty(prefix) {
		True
	} else {
		match split_first(str, prefix) {
			Found({ before, after: _ }) => Str.is_empty(before)
			NotFound => False
		}
	}

ends_with : Str, Str -> Bool
ends_with = |str, suffix| {
	if Str.is_empty(suffix) {
		True
	} else {
		parts = Str.split_on(str, suffix)
		match parts.get(List.len(parts) - 1) {
			Ok(last) => Str.is_empty(last)
			Err(_) => False
		}
	}
}

drop_prefix : Str, Str -> Str
drop_prefix = |str, prefix| {
	parts = Str.split_on(str, prefix)
	Str.join_with(List.drop_first(parts, 1), prefix)
}

split_first : Str, Str -> [Found({ after : Str, before : Str }), NotFound]
split_first = |str, separator| {
	parts = Str.split_on(str, separator)
	if List.len(parts) > 1 {
		match parts.get(0) {
			Ok(before) => Found({ before, after: Str.join_with(List.drop_first(parts, 1), separator) })
			Err(_) => NotFound
		}
	} else {
		NotFound
	}
}

split_last : Str, Str -> [Found({ after : Str, before : Str }), NotFound]
split_last = |str, separator| {
	parts = Str.split_on(str, separator)
	if List.len(parts) > 1 {
		match parts.get(List.len(parts) - 1) {
			Ok(after) => Found({ before: Str.join_with(List.drop_last(parts, 1), separator), after })
			Err(_) => NotFound
		}
	} else {
		NotFound
	}
}

# The parsing cases below are a curated strict HTTP/HTTPS subset informed by
# web-platform-tests/url/resources/urltestdata.json at WPT commit
# dc97e7bed3096ac9e0e591ab5fa22e7fb8844ead (BSD-3-Clause).

expect
	match Url.parse("HTTP://Example.COM:80/a/../b") {
		Ok(url) => Url.to_str(url) == "http://example.com/b"
		Err(_) => False
	}

expect
	match Url.parse("https://example.com:443") {
		Ok(url) => Url.scheme(url) == Https and Url.host(url) == "example.com" and Url.port(url) == None and Url.path(url) == "/"
		Err(_) => False
	}

expect
	match Url.parse("https://127.0.0.1:8443/") {
		Ok(url) => Url.to_str(url) == "https://127.0.0.1:8443/"
		Err(_) => False
	}

## A leading zero is octal to WHATWG and inet_aton, so it is refused rather
## than read as decimal.
expect Url.parse("https://127.000.000.001:8443/") == Err(InvalidIpv4("127.000.000.001"))
expect Url.parse("http://0177.0.0.01/") == Err(InvalidIpv4("0177.0.0.01"))
expect Url.parse("http://010.0.0.1/") == Err(InvalidIpv4("010.0.0.1"))
expect Url.parse("http://0.0.0.0/").map_ok(Url.host) == Ok("0.0.0.0")
expect Url.parse("http://10.0.100.1/").map_ok(Url.host) == Ok("10.0.100.1")

## A host ending in a numeric label is an IPv4 address or nothing.
expect Url.parse("http://0x7f.0.0.1/") == Err(InvalidIpv4("0x7f.0.0.1"))
expect Url.parse("http://0X7F.1/") == Err(InvalidIpv4("0X7F.1"))
expect Url.parse("http://example.0x1f/") == Err(InvalidIpv4("example.0x1f"))
expect Url.parse("http://example.0x/") == Err(InvalidIpv4("example.0x"))
expect Url.parse("http://example.123/") == Err(InvalidIpv4("example.123"))
expect Url.parse("http://0x7f.example.com/").map_ok(Url.host) == Ok("0x7f.example.com")
expect Url.parse("http://example.0xg/").map_ok(Url.host) == Ok("example.0xg")
expect Url.parse("http://123abc.com/").map_ok(Url.host) == Ok("123abc.com")

expect
	match Url.parse("http://[::1]:8080/") {
		Ok(url) => Url.host(url) == "0:0:0:0:0:0:0:1" and Url.to_str(url) == "http://[0:0:0:0:0:0:0:1]:8080/"
		Err(_) => False
	}

expect
	match Url.parse("https://example.com/café?q=naïve#résumé") {
		Ok(url) => Url.to_str(url) == "https://example.com/caf%C3%A9?q=na%C3%AFve#r%C3%A9sum%C3%A9"
		Err(_) => False
	}

expect
	match Url.parse("https://example.com/%7euser") {
		Ok(url) => Url.to_str(url) == "https://example.com/%7Euser"
		Err(_) => False
	}

expect Url.parse("example.com") == Err(MissingScheme)

expect Url.parse("mailto:user@example.com") == Err(MissingAuthority)

expect Url.parse("ftp://example.com") == Err(UnsupportedScheme("ftp"))

expect Url.parse("https://user:secret@example.com") == Err(CredentialsNotAllowed)

expect Url.parse("https://münich.example") == Err(InternationalHostUnsupported)

expect Url.parse("https://") == Err(EmptyHost)

expect Url.parse("https://-example.com") == Err(InvalidHost("-example.com"))

expect Url.parse("https://example..com") == Err(InvalidHost("example..com"))

expect Url.parse("https://127.0.0.256") == Err(InvalidIpv4("127.0.0.256"))

expect Url.parse("https://127.0.0") == Err(InvalidIpv4("127.0.0"))

expect
	match Url.parse("https://[:::1]") {
		Err(InvalidIpv6(_)) => True
		_ => False
	}

expect Url.parse("https://example.com:wat") == Err(InvalidPort("wat"))

expect Url.parse("https://example.com:70000") == Err(PortOutOfRange(70000))

expect Url.parse("https://example.com/%zz") == Err(InvalidPercentEncoding(1))

expect Url.parse("https://example.com/a b") == Err(InvalidCharacter(32))

expect Url.parse("https://example.com/a\\b") == Err(InvalidCharacter(92))

expect
	match Url.parse("https://example.com/?#") {
		Ok(url) => Url.query(url) == Some("") and Url.fragment(url) == Some("")
		Err(_) => False
	}

expect
	match Url.parse("https://example.com/") {
		Err(_) => False
		Ok(url) => {
			match Url.append_path_segments(url, ["a/b", "café"]) {
				Err(_) => False
				Ok(with_path) => {
					with_first = Url.append_query_param(with_path, "tag", "one")
					built = Url.append_query_param(with_first, "tag", "two words")
					Url.to_str(built) == "https://example.com/a%2Fb/caf%C3%A9?tag=one&tag=two+words" and
						Url.query_pairs(built) == [("tag", "one"), ("tag", "two words")]
				}
			}
		}
	}

expect
	match Url.parse("https://example.com/a/b?old=1#old") {
		Err(_) => False
		Ok(base) =>
			match Url.resolve(base, "../c?new=2#fresh") {
				Ok(resolved) => Url.to_str(resolved) == "https://example.com/c?new=2#fresh"
				Err(_) => False
			}
		}

expect
	match Url.parse("https://example.com/a/b?old=1#old") {
		Err(_) => False
		Ok(base) =>
			match Url.resolve(base, "?new=2") {
				Ok(resolved) => Url.to_str(resolved) == "https://example.com/a/b?new=2"
				Err(_) => False
			}
		}

expect
	match Url.parse("https://example.com/a/b?old=1") {
		Err(_) => False
		Ok(base) =>
			match Url.resolve(base, "#fresh") {
				Ok(resolved) => Url.to_str(resolved) == "https://example.com/a/b?old=1#fresh"
				Err(_) => False
			}
		}

expect
	match Url.parse("https://example.com/a/b") {
		Err(_) => False
		Ok(base) =>
			match Url.resolve(base, "/root/./x/../y") {
				Ok(resolved) => Url.to_str(resolved) == "https://example.com/root/y"
				Err(_) => False
			}
		}

expect
	match Url.parse("https://example.com/a?x=1#frag") {
		Err(_) => False
		Ok(url) => Url.to_str(Url.without_fragment(url)) == "https://example.com/a?x=1"
	}

expect
	match Url.from_quote("https://example.com") {
		Ok(url) => Url.to_str(url) == "https://example.com/"
		Err(_) => False
	}

expect
	match Url.parse("http://localhost:0/a/./b/../../c/") {
		Ok(url) => Url.port(url) == Some(0) and Url.to_str(url) == "http://localhost:0/c/"
		Err(_) => False
	}

expect
	match Url.parse("https://example.com:65535") {
		Ok(url) => Url.port(url) == Some(65535) and Url.to_str(url) == "https://example.com:65535/"
		Err(_) => False
	}

expect Url.parse("https://example.com:") == Err(InvalidPort(""))

expect Url.parse("https://example.com:65536") == Err(PortOutOfRange(65536))

expect Url.parse("https://example_com") == Err(InvalidHost("example_com"))

expect Url.parse("https://example.com.") == Err(InvalidHost("example.com."))

expect
	match Url.parse("http://[2001:0DB8:0000:0000:0000:ff00:0042:8329]/") {
		Ok(url) => Url.host(url) == "2001:db8:0:0:0:ff00:42:8329" and Url.to_str(url) == "http://[2001:db8:0:0:0:ff00:42:8329]/"
		Err(_) => False
	}

expect
	match Url.parse("http://[::]/") {
		Ok(url) => Url.host(url) == "0:0:0:0:0:0:0:0"
		Err(_) => False
	}

expect
	match Url.parse("http://[1:2:3:4:5:6:7]/") {
		Err(InvalidIpv6(_)) => True
		_ => False
	}

expect
	match Url.parse("http://[1:2:3:4:5:6:7:8:9]/") {
		Err(InvalidIpv6(_)) => True
		_ => False
	}

expect
	match Url.parse("http://[::ffff:192.0.2.1]/") {
		Err(InvalidIpv6(_)) => True
		_ => False
	}

expect
	match Url.parse("https://example.com/a/%2f/%aa") {
		Ok(url) => Url.path(url) == "/a/%2F/%AA"
		Err(_) => False
	}

expect Url.parse("https://example.com/%") == Err(InvalidPercentEncoding(1))

expect Url.parse("https://example.com/%0") == Err(InvalidPercentEncoding(1))

expect Url.parse("https://example.com/<unsafe>") == Err(InvalidCharacter(60))

expect
	match Url.parse("https://example.com/path?reserved=%23%26/?#fragment/?") {
		Ok(url) =>
			Url.path(url) == "/path" and
				Url.query(url) == Some("reserved=%23%26/?") and
					Url.fragment(url) == Some("fragment/?")
		Err(_) => False
	}

expect
	match Url.parse("https://example.com/?name=Roc+Lang&letter=%C3%A9&flag&name=again") {
		Ok(url) => Url.query_pairs(url) == [("name", "Roc Lang"), ("letter", "é"), ("flag", ""), ("name", "again")]
		Err(_) => False
	}

expect
	match Url.parse("https://example.com/?") {
		Ok(url) => Url.query_pairs(url) == []
		Err(_) => False
	}

expect
	match Url.parse("https://example.com/base?old=1#frag") {
		Err(_) => False
		Ok(url) => Url.append_path_segments(url, ["space here", "?and#"]).map_ok(Url.to_str) == Ok("https://example.com/base/space%20here/%3Fand%23?old=1#frag")
	}

expect
	match Url.parse("https://example.com/base") {
		Err(_) => False
		Ok(url) => Url.append_path_segments(url, []) == Ok(url)
	}

## A `.` or `..` item is refused: `%2E%2E` is still `..` to WHATWG and RFC
## 3986, so no spelling keeps it one literal segment.
expect
	match Url.parse("https://example.com/v1/users/") {
		Err(_) => False
		Ok(url) =>
			Url.append_path_segments(url, ["..", "..", "admin"]) == Err(DotSegment("..")) and
				Url.append_path_segments(url, ["a", "."]) == Err(DotSegment("."))
	}

## Other dot-only items are names to WHATWG (`/v1/...` stays `/v1/...`).
expect
	match Url.parse("https://example.com/v1") {
		Err(_) => False
		Ok(url) => Url.append_path_segments(url, ["...", "a.b", ".x"]).map_ok(Url.path) == Ok("/v1/.../a.b/.x")
	}

## The appended form parses back to itself: normalization leaves it alone.
expect
	match Url.parse("https://example.com/v1/users/") {
		Err(_) => False
		Ok(url) =>
			match Url.append_path_segments(url, ["...", "", "admin"]) {
				Err(_) => False
				Ok(appended) => Url.parse(Url.to_str(appended)) == Ok(appended)
			}
		}

## An empty item is an empty segment, as `new URL` keeps one.
expect
	match Url.parse("https://example.com/v1") {
		Err(_) => False
		Ok(url) =>
			Url.append_path_segments(url, ["", "x"]).map_ok(Url.path) == Ok("/v1//x") and
				Url.append_path_segments(url, [""]).map_ok(Url.path) == Ok("/v1/")
	}

## Dot segments are removed and empty ones kept, as WHATWG does
## (`new URL(...).pathname`).
expect Url.parse("https://e.com/v1//x/../y").map_ok(Url.path) == Ok("/v1//y")
expect Url.parse("https://e.com//a").map_ok(Url.path) == Ok("//a")
expect Url.parse("https://e.com/a//..").map_ok(Url.path) == Ok("/a/")
expect Url.parse("https://e.com/a/b/.").map_ok(Url.path) == Ok("/a/b/")
expect Url.parse("https://e.com/a/b/..").map_ok(Url.path) == Ok("/a/")
expect Url.parse("https://e.com/..").map_ok(Url.path) == Ok("/")
expect Url.parse("https://e.com/a/./../b//").map_ok(Url.path) == Ok("/b//")

expect
	match Url.parse("https://example.com/path?old=1#frag") {
		Err(_) => False
		Ok(url) =>
			match Url.with_query(url, None) {
				Ok(changed) => Url.to_str(changed) == "https://example.com/path#frag"
				Err(_) => False
			}
		}

expect
	match Url.parse("https://example.com/path") {
		Err(_) => False
		Ok(url) =>
			match Url.with_query(url, Some("term=café&empty=")) {
				Ok(changed) => Url.to_str(changed) == "https://example.com/path?term=caf%C3%A9&empty="
				Err(_) => False
			}
		}

expect
	match Url.parse("https://example.com/path") {
		Err(_) => False
		Ok(url) => Url.with_query(url, Some("bad#query")) == Err(InvalidCharacter(35))
	}

expect
	match Url.parse("https://example.com/path#old") {
		Err(_) => False
		Ok(url) =>
			match Url.with_fragment(url, None) {
				Ok(changed) => Url.to_str(changed) == "https://example.com/path"
				Err(_) => False
			}
		}

expect
	match Url.parse("https://example.com/path") {
		Err(_) => False
		Ok(url) =>
			match Url.with_fragment(url, Some("résumé/?")) {
				Ok(changed) => Url.to_str(changed) == "https://example.com/path#r%C3%A9sum%C3%A9/?"
				Err(_) => False
			}
		}

expect
	match Url.parse("https://example.com/path") {
		Err(_) => False
		Ok(url) => Url.with_fragment(url, Some("bad\\fragment")) == Err(InvalidCharacter(92))
	}

expect
	match Url.parse("https://example.com/a/b?old=1#old") {
		Err(_) => False
		Ok(base) =>
			match Url.resolve(base, "") {
				Ok(resolved) => Url.to_str(resolved) == "https://example.com/a/b?old=1"
				Err(_) => False
			}
		}

expect
	match Url.parse("https://example.com/a/b") {
		Err(_) => False
		Ok(base) =>
			match Url.resolve(base, "../../../root") {
				Ok(resolved) => Url.to_str(resolved) == "https://example.com/root"
				Err(_) => False
			}
		}

expect
	match Url.parse("https://example.com/a/b") {
		Err(_) => False
		Ok(base) =>
			match Url.resolve(base, "HTTP://Other.EXAMPLE:80/x") {
				Ok(resolved) => Url.to_str(resolved) == "http://other.example/x"
				Err(_) => False
			}
		}

expect
	match Url.parse("https://example.com/a/b") {
		Err(_) => False
		Ok(base) => Url.resolve(base, "//other.example/x") == Err(MissingScheme)
	}

expect
	match Url.parse("https://example.com/a/b") {
		Err(_) => False
		Ok(base) => Url.resolve(base, "ftp://other.example/x") == Err(UnsupportedScheme("ftp"))
	}

## A reference with a scheme is absolute: not http(s) is refused, as parse
## refuses it, and `http:g` has no authority.
expect
	match Url.parse("https://example.com/a/b") {
		Err(_) => False
		Ok(base) =>
			Url.resolve(base, "mailto:a") == Err(UnsupportedScheme("mailto")) and
				Url.resolve(base, "JavaScript:alert(1)") == Err(UnsupportedScheme("javascript")) and
					Url.resolve(base, "view-source+x.1:y") == Err(UnsupportedScheme("view-source+x.1")) and
						Url.resolve(base, "http:g") == Err(MissingAuthority) and
							Url.resolve(base, "https:/g") == Err(MissingAuthority) and
								Url.resolve(base, "ftp://x") == Url.parse("ftp://x")
	}

## A colon after the first segment's start is not a scheme.
expect
	match Url.parse("https://example.com/a/b") {
		Err(_) => False
		Ok(base) =>
			Url.resolve(base, "./a:b").map_ok(Url.to_str) == Ok("https://example.com/a/a:b") and
				Url.resolve(base, "1a:b").map_ok(Url.to_str) == Ok("https://example.com/a/1a:b") and
					Url.resolve(base, "c/d:e").map_ok(Url.to_str) == Ok("https://example.com/a/c/d:e")
	}

## A `://` after the start is not a scheme: in a query, fragment or later
## path segment it is data. Each answer is WHATWG's for the same base.
expect
	match Url.parse("https://example.com/a/b") {
		Err(_) => False
		Ok(base) =>
			Url.resolve(base, "?next=https://x.com/").map_ok(Url.to_str) == Ok("https://example.com/a/b?next=https://x.com/") and
				Url.resolve(base, "/login?next=https://x.com/").map_ok(Url.to_str) == Ok("https://example.com/login?next=https://x.com/") and
					Url.resolve(base, "#https://x").map_ok(Url.to_str) == Ok("https://example.com/a/b#https://x") and
						Url.resolve(base, "./a://b").map_ok(Url.to_str) == Ok("https://example.com/a/a://b")
	}

## Resolving keeps empty segments, as WHATWG does.
expect
	match Url.parse("https://example.com/a/b") {
		Err(_) => False
		Ok(base) =>
			Url.resolve(base, "c//d/../e").map_ok(Url.to_str) == Ok("https://example.com/a/c//e")
	}

## An http(s) scheme without `//` has no authority, however much follows.
expect
	match Url.parse("https://example.com/a/b") {
		Err(_) => False
		Ok(base) =>
			Url.resolve(base, "http:/x://y") == Err(MissingAuthority) and
				Url.resolve(base, "HTTPS:x://y") == Err(MissingAuthority)
	}
expect Url.parse("http:/x://y") == Err(MissingAuthority)
expect Url.parse("https:x://y") == Err(MissingAuthority)

expect
	match Url.from_quote("not a url") {
		Err(BadQuotedBytes(message)) => Str.contains(message, "http:// or https://")
		Ok(_) => False
	}

## Inspection uses the canonical URL and identifies the nominal type.
expect
	match Url.parse("HTTPS://EXAMPLE.COM:443/a") {
		Ok(url) => Str.inspect(url) == "Url(\"https://example.com/a\")"
		Err(_) => False
	}

## Canonically equivalent URLs compare and hash identically.
expect
	match (Url.parse("HTTPS://EXAMPLE.COM:443/a"), Url.parse("https://example.com/a")) {
		(Ok(stored), Ok(lookup)) => stored == lookup and Dict.single(stored, "found").get(lookup) == Ok("found")
		_ => False
	}

## Generic encoders represent URLs as canonical strings.
expect {
	url : Url
	url = "https://example.com/a?q=roc"
	Json.to_str(url) == "\"https://example.com/a?q=roc\""
}

## Generic parsers validate and canonicalize encoded URL strings.
expect {
	decoded : Try(Url, [InvalidJson(Str)])
	decoded = Json.parse("\"HTTPS://EXAMPLE.COM:443/a\"")

	match decoded {
		Ok(url) => Url.to_str(url) == "https://example.com/a"
		Err(_) => False
	}
}

expect {
	decoded : Try(Url, [InvalidJson(Str)])
	decoded = Json.parse("\"not a url\"")
	decoded == Err(Json.invalid_json)
}
