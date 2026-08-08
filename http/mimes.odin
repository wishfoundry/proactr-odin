package http

/*
MIME types for Content-Type headers (static files, respond_* helpers).

Design:
  - Unknown extension → Octet_Stream (application/octet-stream), never text/plain.
  - Extension match is case-insensitive (.PNG == .png).
  - mime_content_type_for_path adds "; charset=utf-8" for text types used by static.
  - Mime_Type remains a typed enum for call sites that want .Html / .Json, etc.
*/

import "core:path/filepath"
import "core:strings"

Mime_Type :: enum {
	// Fallback for unknown extensions (static/binary-safe).
	Octet_Stream,

	// Text / documents
	Plain,
	Html,
	Css,
	Js,
	Json,
	Xml,
	Csv,
	Markdown,
	Pdf,
	Rtf,
	// Images
	Gif,
	Ico,
	Jpeg,
	Png,
	Svg,
	Webp,
	Avif,
	Bmp,
	Tiff,
	Apng,
	Heic,
	// Fonts
	Woff,
	Woff2,
	Ttf,
	Otf,
	Eot,
	// Audio
	Mp3,
	Wav,
	Ogg,
	M4a,
	Aac,
	Flac,
	// Video
	Mp4,
	Webm,
	Mov,
	Mpeg,
	Ogv,
	// App / web
	Wasm,
	Zip,
	Gzip,
	Brotli,
	Manifest,
	Url_Encoded,
	Atom,
	Rss,
	// Source maps etc. (JSON-shaped)
	Source_Map,
}

// Map path or filename to Mime_Type. Case-insensitive extension. Unknown → .Octet_Stream.
mime_from_extension :: proc(s: string) -> Mime_Type {
	ext := filepath.ext(s)
	if len(ext) == 0 {
		return .Octet_Stream
	}
	// Case-fold extension without allocating when already lower.
	buf: [16]u8
	n := len(ext)
	if n > len(buf) {
		// Unusual long "extension"; lower via temp.
		low := strings.to_lower(ext, context.temp_allocator)
		return _mime_from_ext_lower(low)
	}
	for i in 0 ..< n {
		c := ext[i]
		if c >= 'A' && c <= 'Z' {
			buf[i] = c + 32
		} else {
			buf[i] = c
		}
	}
	return _mime_from_ext_lower(string(buf[:n]))
}

@(private)
_mime_from_ext_lower :: proc(ext: string) -> Mime_Type {
	//odinfmt:disable
	switch ext {
	// HTML / text
	case ".html", ".htm":           return .Html
	case ".css":                    return .Css
	case ".js", ".mjs", ".cjs":     return .Js
	case ".txt", ".text", ".log":   return .Plain
	case ".md", ".markdown":        return .Markdown
	case ".csv":                    return .Csv
	case ".xml", ".xsl":            return .Xml
	case ".json", ".jsonld":        return .Json
	case ".map":                    return .Source_Map
	case ".webmanifest":            return .Manifest
	case ".pdf":                    return .Pdf
	case ".rtf":                    return .Rtf
	// Images
	case ".png":                    return .Png
	case ".jpg", ".jpeg", ".jpe":   return .Jpeg
	case ".gif":                    return .Gif
	case ".svg", ".svgz":           return .Svg
	case ".webp":                   return .Webp
	case ".avif":                   return .Avif
	case ".ico":                    return .Ico
	case ".bmp", ".dib":            return .Bmp
	case ".tif", ".tiff":           return .Tiff
	case ".apng":                   return .Apng
	case ".heic":                   return .Heic
	case ".heif":                   return .Heic
	// Fonts
	case ".woff":                   return .Woff
	case ".woff2":                  return .Woff2
	case ".ttf":                    return .Ttf
	case ".otf":                    return .Otf
	case ".eot":                    return .Eot
	// Audio
	case ".mp3":                    return .Mp3
	case ".wav", ".wave":           return .Wav
	case ".ogg", ".oga", ".opus":   return .Ogg
	case ".m4a":                    return .M4a
	case ".aac":                    return .Aac
	case ".flac":                   return .Flac
	// Video
	case ".mp4", ".m4v":            return .Mp4
	case ".webm":                   return .Webm
	case ".mov", ".qt":             return .Mov
	case ".mpeg", ".mpg", ".mpe":   return .Mpeg
	case ".ogv":                    return .Ogv
	// App / archives
	case ".wasm":                   return .Wasm
	case ".zip":                    return .Zip
	case ".gz", ".gzip":            return .Gzip
	case ".br":                     return .Brotli
	case ".atom":                   return .Atom
	case ".rss":                    return .Rss
	case:
		return .Octet_Stream
	}
	//odinfmt:enable
}

// Base Content-Type without charset (for typed APIs / JSON helpers).
mime_to_content_type :: proc(m: Mime_Type) -> string {
	return _mime_to_content_type[m]
}

// True when static responses should append "; charset=utf-8".
mime_uses_charset_utf8 :: proc(m: Mime_Type) -> bool {
	#partial switch m {
	case .Html, .Css, .Js, .Plain, .Csv, .Xml, .Markdown, .Atom, .Rss:
		return true
	case:
		return false
	}
}

// Content-Type for a filesystem path / URL path (static file serving).
// Case-insensitive ext; unknown → application/octet-stream; text types get charset=utf-8.
// override: if non-empty after caller's lookup, use that instead of builtin.
mime_content_type_for_path :: proc(path: string) -> string {
	m := mime_from_extension(path)
	base := mime_to_content_type(m)
	if mime_uses_charset_utf8(m) {
		// Static strings — no allocation.
		#partial switch m {
		case .Html:
			return "text/html; charset=utf-8"
		case .Css:
			return "text/css; charset=utf-8"
		case .Js:
			return "text/javascript; charset=utf-8"
		case .Plain:
			return "text/plain; charset=utf-8"
		case .Csv:
			return "text/csv; charset=utf-8"
		case .Xml:
			return "text/xml; charset=utf-8"
		case .Markdown:
			return "text/markdown; charset=utf-8"
		case .Atom:
			return "application/atom+xml; charset=utf-8"
		case .Rss:
			return "application/rss+xml; charset=utf-8"
		}
	}
	return base
}

// Resolve Content-Type for static serving: optional override map then builtin.
// extra: optional list of (ext_with_dot_lower, content_type) pairs; first match wins.
// ext in extra should be lowercase including leading '.' (e.g. ".custom").
mime_content_type_for_path_extra :: proc(path: string, extra: []Mime_Extra) -> string {
	if len(extra) > 0 {
		ext := filepath.ext(path)
		if len(ext) > 0 {
			buf: [32]u8
			n := len(ext)
			low: string
			if n <= len(buf) {
				for i in 0 ..< n {
					c := ext[i]
					if c >= 'A' && c <= 'Z' {
						buf[i] = c + 32
					} else {
						buf[i] = c
					}
				}
				low = string(buf[:n])
			} else {
				low = strings.to_lower(ext, context.temp_allocator)
			}
			for e in extra {
				if e.ext == low && e.content_type != "" {
					return e.content_type
				}
			}
		}
	}
	return mime_content_type_for_path(path)
}

// App-supplied extension override for static middleware (ext lowercase with '.').
Mime_Extra :: struct {
	ext:          string, // ".foo"
	content_type: string, // full header value, may include charset
}

@(private = "file")
_mime_to_content_type := [Mime_Type]string {
	.Octet_Stream = "application/octet-stream",
	.Plain        = "text/plain",
	.Html         = "text/html",
	.Css          = "text/css",
	// WHATWG prefers text/javascript; widely accepted.
	.Js           = "text/javascript",
	.Json         = "application/json",
	.Xml          = "text/xml",
	.Csv          = "text/csv",
	.Markdown     = "text/markdown",
	.Pdf          = "application/pdf",
	.Rtf          = "application/rtf",
	.Gif          = "image/gif",
	.Ico          = "image/vnd.microsoft.icon",
	.Jpeg         = "image/jpeg",
	.Png          = "image/png",
	.Svg          = "image/svg+xml",
	.Webp         = "image/webp",
	.Avif         = "image/avif",
	.Bmp          = "image/bmp",
	.Tiff         = "image/tiff",
	.Apng         = "image/apng",
	.Heic         = "image/heic",
	.Woff         = "font/woff",
	.Woff2        = "font/woff2",
	.Ttf          = "font/ttf",
	.Otf          = "font/otf",
	.Eot          = "application/vnd.ms-fontobject",
	.Mp3          = "audio/mpeg",
	.Wav          = "audio/wav",
	.Ogg          = "audio/ogg",
	.M4a          = "audio/mp4",
	.Aac          = "audio/aac",
	.Flac         = "audio/flac",
	.Mp4          = "video/mp4",
	.Webm         = "video/webm",
	.Mov          = "video/quicktime",
	.Mpeg         = "video/mpeg",
	.Ogv          = "video/ogg",
	.Wasm         = "application/wasm",
	.Zip          = "application/zip",
	.Gzip         = "application/gzip",
	.Brotli       = "application/x-br",
	.Manifest     = "application/manifest+json",
	.Url_Encoded  = "application/x-www-form-urlencoded",
	.Atom         = "application/atom+xml",
	.Rss          = "application/rss+xml",
	.Source_Map   = "application/json",
}
