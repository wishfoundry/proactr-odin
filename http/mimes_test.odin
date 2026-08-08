package http

import "core:testing"

@(test)
test_mime_unknown_is_octet_stream :: proc(t: ^testing.T) {
	testing.expect_value(t, mime_from_extension("file.unknownext"), Mime_Type.Octet_Stream)
	testing.expect_value(t, mime_from_extension("noext"), Mime_Type.Octet_Stream)
	testing.expect_value(t, mime_to_content_type(.Octet_Stream), "application/octet-stream")
	testing.expect_value(t, mime_content_type_for_path("blob.bin"), "application/octet-stream")
	testing.expect_value(t, mime_content_type_for_path("x.notarealtype"), "application/octet-stream")
}

@(test)
test_mime_case_insensitive_ext :: proc(t: ^testing.T) {
	testing.expect_value(t, mime_from_extension("Photo.JPG"), Mime_Type.Jpeg)
	testing.expect_value(t, mime_from_extension("Photo.JPEG"), Mime_Type.Jpeg)
	testing.expect_value(t, mime_from_extension("a.PnG"), Mime_Type.Png)
	testing.expect_value(t, mime_from_extension("App.WASM"), Mime_Type.Wasm)
	testing.expect_value(t, mime_content_type_for_path("X.HTML"), "text/html; charset=utf-8")
}

@(test)
test_mime_text_gets_charset :: proc(t: ^testing.T) {
	testing.expect_value(t, mime_content_type_for_path("index.html"), "text/html; charset=utf-8")
	testing.expect_value(t, mime_content_type_for_path("app.css"), "text/css; charset=utf-8")
	testing.expect_value(t, mime_content_type_for_path("app.js"), "text/javascript; charset=utf-8")
	testing.expect_value(t, mime_content_type_for_path("app.mjs"), "text/javascript; charset=utf-8")
	testing.expect_value(t, mime_content_type_for_path("readme.txt"), "text/plain; charset=utf-8")
	testing.expect_value(t, mime_content_type_for_path("doc.md"), "text/markdown; charset=utf-8")
	// application/json: no charset parameter (common practice)
	testing.expect_value(t, mime_content_type_for_path("data.json"), "application/json")
}

@(test)
test_mime_common_static_assets :: proc(t: ^testing.T) {
	testing.expect_value(t, mime_content_type_for_path("f.pdf"), "application/pdf")
	testing.expect_value(t, mime_content_type_for_path("f.woff"), "font/woff")
	testing.expect_value(t, mime_content_type_for_path("f.woff2"), "font/woff2")
	testing.expect_value(t, mime_content_type_for_path("f.ttf"), "font/ttf")
	testing.expect_value(t, mime_content_type_for_path("f.otf"), "font/otf")
	testing.expect_value(t, mime_content_type_for_path("f.webp"), "image/webp")
	testing.expect_value(t, mime_content_type_for_path("f.avif"), "image/avif")
	testing.expect_value(t, mime_content_type_for_path("f.svg"), "image/svg+xml")
	testing.expect_value(t, mime_content_type_for_path("f.mp4"), "video/mp4")
	testing.expect_value(t, mime_content_type_for_path("f.webm"), "video/webm")
	testing.expect_value(t, mime_content_type_for_path("f.mp3"), "audio/mpeg")
	testing.expect_value(t, mime_content_type_for_path("f.wav"), "audio/wav")
	testing.expect_value(t, mime_content_type_for_path("f.wasm"), "application/wasm")
	testing.expect_value(t, mime_content_type_for_path("f.zip"), "application/zip")
	testing.expect_value(t, mime_content_type_for_path("f.webmanifest"), "application/manifest+json")
	testing.expect_value(t, mime_content_type_for_path("f.js.map"), "application/json")
	testing.expect_value(t, mime_content_type_for_path("f.ogv"), "video/ogg")
}

@(test)
test_mime_extra_overrides :: proc(t: ^testing.T) {
	extra := []Mime_Extra {
		{ext = ".gltf", content_type = "model/gltf+json"},
		{ext = ".custom", content_type = "application/x-custom"},
	}
	testing.expect_value(t, mime_content_type_for_path_extra("m.GLTF", extra), "model/gltf+json")
	testing.expect_value(t, mime_content_type_for_path_extra("a.custom", extra), "application/x-custom")
	// Builtin still used when not in extra.
	testing.expect_value(t, mime_content_type_for_path_extra("a.png", extra), "image/png")
}

@(test)
test_mime_js_aliases :: proc(t: ^testing.T) {
	testing.expect_value(t, mime_from_extension("x.mjs"), Mime_Type.Js)
	testing.expect_value(t, mime_from_extension("x.cjs"), Mime_Type.Js)
	testing.expect_value(t, mime_from_extension("x.htm"), Mime_Type.Html)
}
