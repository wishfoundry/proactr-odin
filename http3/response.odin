package http3
import "../qpack"

Response :: struct {
	status:  int,
	headers: []qpack.Header, // response headers (excludes :status)
	body:    []u8,
}

Request :: struct {
	method:  string,
	path:    string,
	headers: []qpack.Header,
	body:    []u8,
}
